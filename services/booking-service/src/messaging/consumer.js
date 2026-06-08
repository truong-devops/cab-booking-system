const crypto = require('crypto');
const { Kafka } = require('kafkajs');
const config = require('../config');
const topics = require('./topics');
const { validateEnvelope } = require('./schemaRegistry');
const { withTransaction } = require('../db/pool');
const bookingRepo = require('../repositories/bookingRepo');
const outboxRepo = require('../repositories/outboxRepo');
const { insertInboxEvent, markInboxProcessed } = require('../repositories/inboxRepo');
const logger = require('../utils/logger');

const kafka = new Kafka({
  clientId: config.kafka.clientId,
  brokers: config.kafka.brokers,
  ssl: config.kafka.ssl,
  sasl: config.kafka.sasl,
  retry: config.kafka.consumerRetry,
  requestTimeout: config.kafka.requestTimeoutMs,
  connectionTimeout: config.kafka.connectionTimeoutMs
});

function headerValueToString(value) {
  if (value == null) {
    return '';
  }
  if (Buffer.isBuffer(value)) {
    return value.toString();
  }
  return String(value);
}

function buildEnvelope({ eventId, type, traceId, payload }) {
  return {
    eventId,
    traceId: traceId || null,
    occurredAt: new Date().toISOString(),
    type,
    version: 1,
    payload
  };
}

function buildOutboxRecord({ eventId, topic, eventType, aggregateId, partitionKey, envelope }) {
  return {
    eventId,
    aggregateType: 'booking',
    aggregateId,
    eventType,
    topic,
    partitionKey,
    payload: envelope,
    occurredAt: envelope.occurredAt,
    maxAttempts: config.outbox.maxAttempts
  };
}

async function applyPaymentCompleted(client, payload) {
  const booking = await bookingRepo.getByRideIdForUpdate(client, payload.rideId);
  if (!booking) {
    throw new Error(`booking_not_found:${payload.rideId}`);
  }

  const status = String(booking.status || '').toUpperCase();
  if (status === 'CANCELLED' || status === 'FAILED' || status === 'CONFIRMED' || status === 'ACCEPTED') {
    return {
      skipped: true,
      reason: 'terminal_or_already_confirmed',
      bookingId: booking.bookingId,
      status
    };
  }

  const updated = await bookingRepo.updateStatus(client, booking.bookingId, 'CONFIRMED');
  return {
    skipped: false,
    bookingId: updated.bookingId,
    status: updated.status
  };
}

async function applyPaymentFailed(client, payload, traceId) {
  const booking = await bookingRepo.getByRideIdForUpdate(client, payload.rideId);
  if (!booking) {
    throw new Error(`booking_not_found:${payload.rideId}`);
  }

  const status = String(booking.status || '').toUpperCase();
  if (status === 'CANCELLED') {
    return {
      skipped: true,
      reason: 'already_cancelled',
      bookingId: booking.bookingId
    };
  }

  const cancelled = await bookingRepo.cancel(client, booking.bookingId);
  const eventId = crypto.randomUUID();
  const envelope = buildEnvelope({
    eventId,
    traceId,
    type: 'RideCancelled',
    payload: {
      rideId: cancelled.rideId,
      reason: payload.failureReason || 'PAYMENT_FAILED',
      timestamp: new Date().toISOString()
    }
  });

  await outboxRepo.insertOutboxEvent(
    client,
    buildOutboxRecord({
      eventId,
      topic: topics.RideCancelled,
      eventType: 'RideCancelled',
      aggregateId: cancelled.bookingId,
      partitionKey: cancelled.rideId,
      envelope
    })
  );

  return {
    skipped: false,
    bookingId: cancelled.bookingId,
    status: cancelled.status,
    compensationEventId: eventId
  };
}

async function processEnvelope(topic, envelope) {
  const payload = envelope.payload || {};
  const traceId = envelope.traceId || null;
  const eventType = envelope.type || 'UnknownEvent';

  return withTransaction(async (client) => {
    const inserted = await insertInboxEvent(client, {
      eventId: envelope.eventId,
      traceId,
      topic,
      eventType,
      payload
    });
    if (!inserted) {
      return { handled: true, reason: 'duplicate' };
    }

    let result;
    if (topic === topics.PaymentCompleted) {
      result = await applyPaymentCompleted(client, payload);
    } else if (topic === topics.PaymentFailed) {
      result = await applyPaymentFailed(client, payload, traceId);
    } else {
      result = { skipped: true, reason: 'unsupported_topic' };
    }

    await markInboxProcessed(client, envelope.eventId);
    return { handled: true, reason: 'processed', result };
  });
}

async function processConsumedMessage({ topic, message }) {
  const rawValue = message.value ? message.value.toString() : '';
  let envelope;
  try {
    envelope = JSON.parse(rawValue);
  } catch (_error) {
    return { handled: true, reason: 'invalid_json' };
  }

  const validation = validateEnvelope(topic, envelope);
  if (!validation.valid) {
    logger.warn(
      {
        topic,
        eventId: envelope?.eventId || null,
        errors: validation.errors
      },
      '[booking-service] invalid envelope in consumer'
    );
    return { handled: true, reason: 'invalid_envelope' };
  }

  if (!envelope?.eventId) {
    return { handled: true, reason: 'missing_event_id' };
  }

  if (topic !== topics.PaymentCompleted && topic !== topics.PaymentFailed) {
    return { handled: true, reason: 'unsupported_topic' };
  }

  return processEnvelope(topic, envelope);
}

async function startConsumer() {
  if (!config.kafka.consumeTopics.length) {
    return null;
  }

  const consumer = kafka.consumer({
    groupId: config.kafka.consumerGroupId,
    sessionTimeout: config.kafka.sessionTimeout,
    rebalanceTimeout: config.kafka.rebalanceTimeout,
    heartbeatInterval: config.kafka.heartbeatInterval,
    maxBytesPerPartition: config.kafka.maxBytesPerPartition,
    minBytes: config.kafka.minBytes,
    maxBytes: config.kafka.maxBytes,
    maxWaitTimeInMs: config.kafka.maxWaitTimeInMs,
    retry: config.kafka.consumerRetry
  });

  await consumer.connect();
  for (const topic of config.kafka.consumeTopics) {
    await consumer.subscribe({
      topic,
      fromBeginning: false
    });
  }

  await consumer.run({
    partitionsConsumedConcurrently: config.kafka.partitionsConsumedConcurrently,
    eachBatchAutoResolve: false,
    autoCommit: true,
    autoCommitInterval: config.kafka.autoCommitInterval,
    autoCommitThreshold: config.kafka.autoCommitThreshold,
    eachBatch: async ({ batch, resolveOffset, heartbeat, commitOffsetsIfNecessary, isRunning, isStale }) => {
      for (let index = 0; index < batch.messages.length && index < config.kafka.maxMessagesPerBatch; index += 1) {
        const message = batch.messages[index];
        if (!isRunning() || isStale()) {
          break;
        }

        try {
          const result = await processConsumedMessage({
            topic: batch.topic,
            message
          });
          if (result?.handled) {
            resolveOffset(message.offset);
            await commitOffsetsIfNecessary();
            await heartbeat();
          }
        } catch (error) {
          logger.error(
            {
              err: {
                message: error.message,
                code: error.code || 'UNKNOWN'
              },
              topic: batch.topic,
              eventId: headerValueToString(message.headers?.['x-event-id']) || null,
              offset: message.offset
            },
            '[booking-service] consumer failed before offset commit'
          );
          throw error;
        }
      }
    }
  });

  return async () => {
    await consumer.disconnect();
  };
}

module.exports = {
  startConsumer,
  processConsumedMessage
};
