const { Kafka } = require('kafkajs');
const { buildKafkaClientOptions } = require('../config/kafka');
const topics = require('./topics');
const { validateEnvelope } = require('./schemaRegistry');
const { publishToDlq } = require('./producer');
const redis = require('../cache/redis');
const { insertInboxEvent, markProcessedByEventId, markFailedByEventId } = require('../repository/inboxEventsRepository');
const { processRow } = require('./inboxProcessor');
const logger = require('../utils/logger');
const monitoring = require('../monitoring');

function headerValueToString(value) {
  if (value == null) {
    return '';
  }
  if (Buffer.isBuffer(value)) {
    return value.toString();
  }
  return String(value);
}

const kafka = new Kafka(buildKafkaClientOptions({
  clientId: 'ride-service',
  retry: {
    retries: Number(process.env.KAFKA_CONSUMER_RETRY_RETRIES || 8),
    initialRetryTime: Number(process.env.KAFKA_CONSUMER_RETRY_INITIAL_MS || 300),
    maxRetryTime: Number(process.env.KAFKA_CONSUMER_RETRY_MAX_MS || 30000)
  }
}));

const CONSUMER_GROUP_ID = process.env.KAFKA_CONSUMER_GROUP_ID || 'ride-service-group';
const CONSUMER_NAME = 'ride-service';
const CACHE_TTL_SECONDS = Number(process.env.KAFKA_CONSUMER_DEDUPE_CACHE_TTL_SECONDS || 24 * 60 * 60);
const CONSUMER_PARTITIONS_CONCURRENCY = Number(process.env.KAFKA_CONSUMER_PARTITIONS_CONCURRENCY || 1);
const CONSUMER_MAX_MESSAGES_PER_BATCH = Number(process.env.KAFKA_CONSUMER_MAX_MESSAGES_PER_BATCH || 100);
const CONSUMER_AUTO_COMMIT_INTERVAL_MS = Number(process.env.KAFKA_CONSUMER_AUTO_COMMIT_INTERVAL_MS || 1000);
const CONSUMER_AUTO_COMMIT_THRESHOLD = Number(process.env.KAFKA_CONSUMER_AUTO_COMMIT_THRESHOLD || 1);

const consumer = kafka.consumer({
  groupId: CONSUMER_GROUP_ID,
  sessionTimeout: Number(process.env.KAFKA_CONSUMER_SESSION_TIMEOUT_MS || 30000),
  rebalanceTimeout: Number(process.env.KAFKA_CONSUMER_REBALANCE_TIMEOUT_MS || 60000),
  heartbeatInterval: Number(process.env.KAFKA_CONSUMER_HEARTBEAT_INTERVAL_MS || 3000),
  maxBytesPerPartition: Number(process.env.KAFKA_CONSUMER_MAX_BYTES_PER_PARTITION || 1048576),
  minBytes: Number(process.env.KAFKA_CONSUMER_MIN_BYTES || 1),
  maxBytes: Number(process.env.KAFKA_CONSUMER_MAX_BYTES || 10485760),
  maxWaitTimeInMs: Number(process.env.KAFKA_CONSUMER_MAX_WAIT_MS || 5000)
});

async function processInboxEventInline({ topic, envelope, traceId, startedAt }) {
  const row = {
    topic,
    event_id: envelope.eventId,
    event_type: envelope.type,
    trace_id: traceId,
    payload: envelope.payload || null
  };

  const result = await processRow(row);
  await markProcessedByEventId({
    eventId: envelope.eventId,
    consumer: CONSUMER_NAME
  });

  monitoring.recordDependencyRequest({
    dependencyType: 'kafka',
    dependencyName: topic,
    operation: 'consume',
    outcome: 'success',
    durationMs: Date.now() - startedAt,
    attributes: { result: 'processed_inline' }
  });

  return {
    handled: true,
    reason: 'processed_inline',
    result
  };
}

async function handleInlineProcessingError({ topic, envelope, traceId, startedAt, error }) {
  const retry = await markFailedByEventId({
    eventId: envelope.eventId,
    consumer: CONSUMER_NAME,
    errorMessage: error?.message || 'inline_process_failed'
  });

  monitoring.recordKafkaRetry({
    scope: 'inbox',
    topic,
    status: String(retry?.status || 'unknown').toLowerCase(),
    reason: error?.message || 'inline_process_failed'
  });

  monitoring.recordDependencyRequest({
    dependencyType: 'kafka',
    dependencyName: topic,
    operation: 'consume',
    outcome: 'error',
    durationMs: Date.now() - startedAt,
    attributes: {
      error_type: String(error?.name || 'inline_process_error'),
      result: retry?.status === 'dead' ? 'inline_failed_dead' : 'inline_failed_retry'
    }
  });

  logger.withTrace(traceId).warn(
    {
      topic,
      eventId: envelope.eventId,
      status: retry?.status || 'unknown',
      err: {
        message: error?.message || 'inline_process_failed',
        code: error?.code || 'INLINE_PROCESS_ERROR'
      }
    },
    '[ride-service] inline inbox processing failed, queued for retry/dead-letter'
  );

  if (retry?.status === 'dead') {
    await publishToDlq({
      topic,
      envelope: {
        eventId: envelope.eventId,
        traceId: traceId || null,
        occurredAt: envelope.occurredAt || new Date().toISOString(),
        type: envelope.type || 'UnknownEvent',
        version: envelope.version || 1,
        payload: envelope.payload || null
      },
      errorMessage: error?.message || 'inline_process_failed',
      metadata: {
        source: 'ride-service.consumer',
        attemptCount: retry.attemptCount,
        maxAttempts: retry.maxAttempts
      }
    });
    return {
      handled: true,
      reason: 'inline_failed_dead',
      retry
    };
  }

  return {
    handled: true,
    reason: 'inline_failed_retry',
    retry
  };
}

async function processConsumedMessage({ topic, message }) {
  const startedAt = Date.now();
  const rawValue = message.value?.toString() || '';
  let envelope;

  try {
    envelope = JSON.parse(rawValue);
  } catch (_error) {
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'consume',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: { error_type: 'invalid_json' }
    });
    await publishToDlq({
      topic,
      envelope: {
        eventId: headerValueToString(message.headers?.['x-event-id']) || message.key?.toString() || 'unknown',
        traceId: headerValueToString(message.headers?.['x-trace-id']) || null,
        occurredAt: new Date().toISOString(),
        type: 'InvalidJson',
        version: 1,
        payload: { rawValue }
      },
      validationErrors: [{ message: 'invalid_json' }],
      throwOnError: true
    });
    return { handled: true, reason: 'invalid_json' };
  }

  const envelopeValidation = validateEnvelope(topic, envelope);
  if (!envelopeValidation.ok) {
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'consume',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: { error_type: 'invalid_envelope' }
    });
    await publishToDlq({
      topic,
      envelope: {
        eventId: envelope?.eventId || message.key?.toString() || 'unknown',
        traceId: envelope?.traceId || null,
        occurredAt: new Date().toISOString(),
        type: envelope.type || 'UnknownEvent',
        version: 1,
        payload: envelope.payload || null
      },
      validationErrors: envelopeValidation.errors,
      errorMessage: 'invalid_envelope',
      throwOnError: true
    });
    return { handled: true, reason: 'invalid_envelope' };
  }

  const eventId = envelope.eventId;
  const traceId = envelope.traceId || headerValueToString(message.headers?.['x-trace-id']) || null;

  const cacheKey = `inbox:${CONSUMER_NAME}:${eventId}`;
  const cached = await redis.get(cacheKey);
  if (cached) {
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'consume',
      outcome: 'success',
      durationMs: Date.now() - startedAt,
      attributes: { result: 'duplicate_cache' }
    });
    logger.withTrace(traceId).info({ topic, eventId }, '[ride-service] duplicate event (cache), skipping');
    return { handled: true, reason: 'duplicate_cache' };
  }

  const inserted = await insertInboxEvent({
    eventId,
    consumer: CONSUMER_NAME,
    topic,
    eventType: envelope.type || 'unknown',
    payload: envelope.payload,
    traceId
  });

  if (!inserted) {
    await redis.set(cacheKey, '1', 'EX', CACHE_TTL_SECONDS);
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'consume',
      outcome: 'success',
      durationMs: Date.now() - startedAt,
      attributes: { result: 'duplicate_db' }
    });
    logger.withTrace(traceId).info({ topic, eventId }, '[ride-service] duplicate event (db), skipping');
    return { handled: true, reason: 'duplicate_db' };
  }

  await redis.set(cacheKey, '1', 'EX', CACHE_TTL_SECONDS);

  try {
    const inlineResult = await processInboxEventInline({
      topic,
      envelope,
      traceId,
      startedAt
    });
    logger.withTrace(traceId).info({ topic, eventId, result: inlineResult.result }, '[ride-service] consumed + processed event inline');
    return inlineResult;
  } catch (error) {
    return handleInlineProcessingError({
      topic,
      envelope,
      traceId,
      startedAt,
      error
    });
  }
}

async function start() {
  await consumer.connect();
  const topicList = Object.values(topics);
  for (const topic of topicList) {
    await consumer.subscribe({
      topic,
      fromBeginning: false
    });
  }

  await consumer.run({
    partitionsConsumedConcurrently: CONSUMER_PARTITIONS_CONCURRENCY,
    eachBatchAutoResolve: false,
    autoCommit: true,
    autoCommitInterval: CONSUMER_AUTO_COMMIT_INTERVAL_MS,
    autoCommitThreshold: CONSUMER_AUTO_COMMIT_THRESHOLD,
    eachBatch: async ({ batch, resolveOffset, heartbeat, commitOffsetsIfNecessary, isRunning, isStale }) => {
      for (let index = 0; index < batch.messages.length && index < CONSUMER_MAX_MESSAGES_PER_BATCH; index += 1) {
        const message = batch.messages[index];
        if (!isRunning() || isStale()) {
          break;
        }

        const startedAt = Date.now();
        try {
          const result = await processConsumedMessage({
            topic: batch.topic,
            message
          });
          const highWatermark = Number(batch.highWatermark);
          const offset = Number(message.offset);
          if (Number.isFinite(highWatermark) && Number.isFinite(offset)) {
            monitoring.setKafkaConsumerLag({
              consumerGroup: CONSUMER_GROUP_ID,
              topic: batch.topic,
              partition: batch.partition,
              lag: Math.max(0, highWatermark - offset - 1)
            });
          }
          monitoring.recordKafkaProcessingLatency({
            pipeline: 'consume_event',
            topic: batch.topic,
            outcome: /invalid|error/i.test(result?.reason || '') ? 'error' : 'success',
            durationMs: Date.now() - startedAt
          });
          resolveOffset(message.offset);
          await commitOffsetsIfNecessary();
          await heartbeat();
        } catch (error) {
          monitoring.recordKafkaProcessingLatency({
            pipeline: 'consume_event',
            topic: batch.topic,
            outcome: 'error',
            durationMs: Date.now() - startedAt
          });
          logger.error(
            {
              err: error,
              topic: batch.topic,
              offset: message.offset,
              partition: batch.partition
            },
            '[ride-service] consume failed before offset commit'
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

module.exports = { start, processConsumedMessage };
