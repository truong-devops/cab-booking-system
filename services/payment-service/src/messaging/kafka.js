const { Kafka, logLevel } = require('kafkajs');
const config = require('../config');
const monitoring = require('../monitoring');
const { logger } = require('../utils/logger');

function sanitizeKafkaText(value) {
  if (typeof value !== 'string') {
    return value;
  }
  return value
    .replace(/ECONNREFUSED/gi, 'CONNECTION_REFUSED')
    .replace(/\s+/g, ' ')
    .trim();
}

function toKafkaLogLevel(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (normalized === 'nothing' || normalized === 'silent') {
    return logLevel.NOTHING;
  }
  if (normalized === 'error') {
    return logLevel.ERROR;
  }
  if (normalized === 'warn' || normalized === 'warning') {
    return logLevel.WARN;
  }
  if (normalized === 'info') {
    return logLevel.INFO;
  }
  if (normalized === 'debug') {
    return logLevel.DEBUG;
  }
  return logLevel.ERROR;
}

function kafkaLogCreator() {
  return ({ namespace, level, log }) => {
    const payload = { namespace };
    const safeLog = log && typeof log === 'object' ? { ...log } : {};
    const rawMessage = sanitizeKafkaText(String(safeLog.message || `[kafkajs] ${namespace}`));
    delete safeLog.message;
    delete safeLog.stack;

    for (const [key, value] of Object.entries(safeLog)) {
      payload[key] = typeof value === 'string' ? sanitizeKafkaText(value) : value;
    }

    if (level === logLevel.ERROR) {
      logger.error(payload, rawMessage);
      return;
    }
    if (level === logLevel.WARN) {
      logger.warn(payload, rawMessage);
      return;
    }
    if (level === logLevel.INFO) {
      logger.info(payload, rawMessage);
      return;
    }
    logger.debug(payload, rawMessage);
  };
}

const kafka = new Kafka({
  clientId: config.kafka.clientId,
  brokers: config.kafka.brokers,
  ssl: config.kafka.ssl,
  sasl: config.kafka.sasl,
  retry: config.kafka.retry,
  logLevel: toKafkaLogLevel(process.env.KAFKA_LOG_LEVEL || 'error'),
  logCreator: kafkaLogCreator
});

let producer;
let consumer;

function wrapProducer(instance) {
  if (!instance || instance.__cabMetricsWrapped) {
    return instance;
  }

  const originalSend = instance.send.bind(instance);
  instance.send = async (payload) => {
    const startedAt = Date.now();
    const topic = payload && payload.topic ? String(payload.topic) : 'unknown';
    try {
      const result = await originalSend(payload);
      monitoring.recordDependencyRequest({
        dependencyType: 'kafka',
        dependencyName: topic,
        operation: 'publish',
        outcome: 'success',
        durationMs: Date.now() - startedAt
      });
      return result;
    } catch (error) {
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
  };

  instance.__cabMetricsWrapped = true;
  return instance;
}

async function getProducer() {
  if (!producer) {
    producer = kafka.producer({
      retry: config.kafka.producerRetry,
      maxInFlightRequests: config.kafka.producerMaxInFlightRequests,
      idempotent: true
    });
    const startedAt = Date.now();
    try {
      await producer.connect();
      monitoring.recordDependencyRequest({
        dependencyType: 'kafka',
        dependencyName: 'broker',
        operation: 'connect_producer',
        outcome: 'success',
        durationMs: Date.now() - startedAt
      });
    } catch (error) {
      monitoring.recordDependencyRequest({
        dependencyType: 'kafka',
        dependencyName: 'broker',
        operation: 'connect_producer',
        outcome: 'error',
        durationMs: Date.now() - startedAt,
        attributes: {
          error_type: String(error && error.name ? error.name : 'connect_error')
        }
      });
      throw error;
    }
    producer = wrapProducer(producer);
  }
  return producer;
}

async function getConsumer() {
  if (!consumer) {
    consumer = kafka.consumer({
      groupId: config.kafka.consumerGroupId,
      sessionTimeout: config.kafka.sessionTimeout,
      rebalanceTimeout: config.kafka.rebalanceTimeout,
      heartbeatInterval: config.kafka.heartbeatInterval,
      maxBytesPerPartition: config.kafka.maxBytesPerPartition,
      minBytes: config.kafka.minBytes,
      maxBytes: config.kafka.maxBytes,
      maxWaitTimeInMs: config.kafka.maxWaitTimeInMs,
      retry: config.kafka.retry
    });
    const startedAt = Date.now();
    try {
      await consumer.connect();
      monitoring.recordDependencyRequest({
        dependencyType: 'kafka',
        dependencyName: 'broker',
        operation: 'connect_consumer',
        outcome: 'success',
        durationMs: Date.now() - startedAt
      });
    } catch (error) {
      monitoring.recordDependencyRequest({
        dependencyType: 'kafka',
        dependencyName: 'broker',
        operation: 'connect_consumer',
        outcome: 'error',
        durationMs: Date.now() - startedAt,
        attributes: {
          error_type: String(error && error.name ? error.name : 'connect_error')
        }
      });
      throw error;
    }
  }
  return consumer;
}

async function disconnectKafka() {
  if (producer) {
    await producer.disconnect();
    producer = null;
  }
  if (consumer) {
    await consumer.disconnect();
    consumer = null;
  }
}

module.exports = { getProducer, getConsumer, disconnectKafka };
