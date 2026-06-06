const crypto = require('crypto');
const { Kafka } = require('kafkajs');
const { validateEnvelope } = require('./schemaRegistry');
const logger = require('../utils/logger');
const monitoring = require('../monitoring');

const kafka = new Kafka({
  clientId: 'ride-service',
  brokers: [process.env.KAFKA_BROKERS || 'kafka:9092'],
  retry: {
    retries: Number(process.env.KAFKA_PRODUCER_RETRY_RETRIES || 8),
    initialRetryTime: Number(process.env.KAFKA_PRODUCER_RETRY_INITIAL_MS || 300),
    maxRetryTime: Number(process.env.KAFKA_PRODUCER_RETRY_MAX_MS || 30000)
  }
});

const PRODUCER_ACKS = Number(process.env.KAFKA_PRODUCER_ACKS || -1);
const PRODUCER_TIMEOUT_MS = Number(process.env.KAFKA_PRODUCER_REQUEST_TIMEOUT_MS || 30000);
const PRODUCER_MAX_IN_FLIGHT = Number(process.env.KAFKA_PRODUCER_MAX_IN_FLIGHT_REQUESTS || 5);

let producerPromise;

async function getProducer() {
  if (!producerPromise) {
    const producer = kafka.producer({
      idempotent: true,
      maxInFlightRequests: PRODUCER_MAX_IN_FLIGHT,
      retry: {
        retries: Number(process.env.KAFKA_PRODUCER_RETRY_RETRIES || 8),
        initialRetryTime: Number(process.env.KAFKA_PRODUCER_RETRY_INITIAL_MS || 300),
        maxRetryTime: Number(process.env.KAFKA_PRODUCER_RETRY_MAX_MS || 30000)
      }
    });
    producerPromise = producer.connect().then(() => producer);
  }
  return producerPromise;
}

async function publishToDlq({ topic, envelope, validationErrors, errorMessage = null, metadata = null, throwOnError = false }) {
  const producer = await getProducer();
  const dlqTopic = `${topic}.dlq`;
  const dlqEnvelope = {
    ...envelope,
    payload: {
      originalPayload: envelope.payload,
      validationErrors: validationErrors || null,
      errorMessage,
      metadata: metadata || null
    }
  };
  const startedAt = Date.now();
  const dlqKey = envelope?.payload?.rideId || envelope?.payload?.paymentId || envelope?.payload?.bookingId || envelope?.eventId;

  try {
    await producer.send({
      topic: dlqTopic,
      acks: PRODUCER_ACKS,
      timeout: PRODUCER_TIMEOUT_MS,
      messages: [
        {
          key: dlqKey,
          value: JSON.stringify(dlqEnvelope),
          headers: {
            'x-source-topic': topic,
            'x-trace-id': envelope?.traceId || '',
            'x-source-event-id': envelope?.eventId || ''
          }
        }
      ]
    });
    monitoring.recordKafkaPublish({
      topic: dlqTopic,
      outcome: 'success',
      operation: 'publish_dlq'
    });
    monitoring.recordKafkaDlq({
      sourceTopic: topic,
      dlqTopic,
      errorType: errorMessage || 'validation_failed'
    });
    monitoring.recordKafkaProcessingLatency({
      pipeline: 'publish_dlq',
      topic: dlqTopic,
      outcome: 'success',
      durationMs: Date.now() - startedAt
    });
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: dlqTopic,
      operation: 'publish',
      outcome: 'success',
      durationMs: Date.now() - startedAt
    });
  } catch (error) {
    monitoring.recordKafkaPublish({
      topic: dlqTopic,
      outcome: 'error',
      operation: 'publish_dlq'
    });
    monitoring.recordKafkaProcessingLatency({
      pipeline: 'publish_dlq',
      topic: dlqTopic,
      outcome: 'error',
      durationMs: Date.now() - startedAt
    });
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: dlqTopic,
      operation: 'publish',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: {
        error_type: String(error && error.name ? error.name : 'publish_error')
      }
    });
    logger.error({ err: error, topic: dlqTopic }, '[ride-service] dlq publish failed');
    logger.warn({ topic: dlqTopic }, '[ride-service] TODO ensure DLQ topic exists');
    if (throwOnError) {
      throw error;
    }
  }
}

async function publish({
  topic,
  type,
  payload,
  traceId,
  version = 1,
  eventId = crypto.randomUUID(),
  occurredAt = new Date().toISOString(),
  key = eventId
}) {
  const envelope = {
    eventId,
    traceId,
    occurredAt,
    type,
    version,
    payload
  };
  const validation = validateEnvelope(topic, envelope);

  if (!validation.ok) {
    await publishToDlq({
      topic,
      envelope,
      validationErrors: validation.errors
    });
    return { published: false, reason: 'validation_failed' };
  }

  const producer = await getProducer();
  const startedAt = Date.now();
  try {
    await producer.send({
      topic,
      acks: PRODUCER_ACKS,
      timeout: PRODUCER_TIMEOUT_MS,
      messages: [
        {
          key,
          value: JSON.stringify(envelope),
          headers: {
            'x-trace-id': traceId || '',
            'x-event-id': eventId
          }
        }
      ]
    });
    monitoring.recordKafkaPublish({
      topic,
      outcome: 'success'
    });
    monitoring.recordKafkaProcessingLatency({
      pipeline: 'publish_event',
      topic,
      outcome: 'success',
      durationMs: Date.now() - startedAt
    });
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'publish',
      outcome: 'success',
      durationMs: Date.now() - startedAt
    });
  } catch (error) {
    monitoring.recordKafkaPublish({
      topic,
      outcome: 'error'
    });
    monitoring.recordKafkaProcessingLatency({
      pipeline: 'publish_event',
      topic,
      outcome: 'error',
      durationMs: Date.now() - startedAt
    });
    monitoring.recordDependencyRequest({
      dependencyType: 'kafka',
      dependencyName: topic,
      operation: 'publish',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: {
        error_type: String(error && error.name ? error.name : 'publish_error')
      }
    });
    throw error;
  }

  return { published: true, envelope };
}

module.exports = { publish, publishToDlq };
