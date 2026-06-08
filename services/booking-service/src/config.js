function toNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseBoolean(value, fallback = false) {
  if (value == null || value === '') {
    return fallback;
  }
  const normalized = String(value).trim().toLowerCase();
  if (['true', '1', 'yes'].includes(normalized)) {
    return true;
  }
  if (['false', '0', 'no'].includes(normalized)) {
    return false;
  }
  return fallback;
}

function normalizeBrokers(value) {
  return String(value || 'kafka:9092')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeTopics(value, fallback) {
  return String(value || fallback || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function buildKafkaSasl() {
  const mechanism = String(process.env.KAFKA_SASL_MECHANISM || '').trim();
  if (!mechanism) {
    return undefined;
  }

  const username = process.env.KAFKA_SASL_USERNAME;
  const password = process.env.KAFKA_SASL_PASSWORD;
  if (!username || !password) {
    throw new Error('KAFKA_SASL_USERNAME and KAFKA_SASL_PASSWORD are required when KAFKA_SASL_MECHANISM is set');
  }

  return { mechanism, username, password };
}

module.exports = {
  serviceName: process.env.SERVICE_NAME || 'booking-service',
  port: toNumber(process.env.PORT, 3003),
  kafka: {
    clientId: process.env.KAFKA_CLIENT_ID || 'booking-service',
    brokers: normalizeBrokers(process.env.KAFKA_BROKERS),
    ssl: parseBoolean(process.env.KAFKA_SSL, false),
    sasl: buildKafkaSasl(),
    requestTimeoutMs: toNumber(process.env.KAFKA_REQUEST_TIMEOUT_MS, 60000),
    connectionTimeoutMs: toNumber(process.env.KAFKA_CONNECTION_TIMEOUT_MS, 10000),
    consumeTopics: normalizeTopics(process.env.KAFKA_CONSUME_TOPICS, 'payment.completed,payment.failed'),
    consumerGroupId: process.env.KAFKA_CONSUMER_GROUP_ID || 'booking-service-group',
    partitionsConsumedConcurrently: toNumber(process.env.KAFKA_CONSUMER_PARTITIONS_CONCURRENCY, 1),
    maxMessagesPerBatch: toNumber(process.env.KAFKA_CONSUMER_MAX_MESSAGES_PER_BATCH, 100),
    maxBytesPerPartition: toNumber(process.env.KAFKA_CONSUMER_MAX_BYTES_PER_PARTITION, 1048576),
    minBytes: toNumber(process.env.KAFKA_CONSUMER_MIN_BYTES, 1),
    maxBytes: toNumber(process.env.KAFKA_CONSUMER_MAX_BYTES, 10485760),
    maxWaitTimeInMs: toNumber(process.env.KAFKA_CONSUMER_MAX_WAIT_MS, 5000),
    sessionTimeout: toNumber(process.env.KAFKA_CONSUMER_SESSION_TIMEOUT_MS, 30000),
    heartbeatInterval: toNumber(process.env.KAFKA_CONSUMER_HEARTBEAT_INTERVAL_MS, 3000),
    rebalanceTimeout: toNumber(process.env.KAFKA_CONSUMER_REBALANCE_TIMEOUT_MS, 60000),
    autoCommitInterval: toNumber(process.env.KAFKA_CONSUMER_AUTO_COMMIT_INTERVAL_MS, 1000),
    autoCommitThreshold: toNumber(process.env.KAFKA_CONSUMER_AUTO_COMMIT_THRESHOLD, 1),
    consumerRetry: {
      retries: toNumber(process.env.KAFKA_CONSUMER_RETRY_RETRIES, 8),
      initialRetryTime: toNumber(process.env.KAFKA_CONSUMER_RETRY_INITIAL_MS, 300),
      maxRetryTime: toNumber(process.env.KAFKA_CONSUMER_RETRY_MAX_MS, 30000)
    },
    producerConnectTimeoutMs: toNumber(process.env.KAFKA_PRODUCER_CONNECT_TIMEOUT_MS, 10000),
    producerAcks: toNumber(process.env.KAFKA_PRODUCER_ACKS, -1),
    producerRequestTimeoutMs: toNumber(process.env.KAFKA_PRODUCER_REQUEST_TIMEOUT_MS, 30000),
    producerRetry: {
      retries: toNumber(process.env.KAFKA_PRODUCER_RETRY_RETRIES, 8),
      initialRetryTime: toNumber(process.env.KAFKA_PRODUCER_RETRY_INITIAL_MS, 300),
      maxRetryTime: toNumber(process.env.KAFKA_PRODUCER_RETRY_MAX_MS, 30000)
    },
    producerMaxInFlightRequests: toNumber(process.env.KAFKA_PRODUCER_MAX_IN_FLIGHT_REQUESTS, 5)
  },
  startup: {
    maxRetries: toNumber(process.env.STARTUP_MAX_RETRIES, 0),
    retryInitialDelayMs: toNumber(process.env.STARTUP_RETRY_INITIAL_DELAY_MS, 1000),
    retryMaxDelayMs: toNumber(process.env.STARTUP_RETRY_MAX_DELAY_MS, 15000)
  },
  db: {
    connectionString: process.env.DATABASE_URL || 'postgres://cab:cabpass@postgres:5432/booking-service_db',
    maxPoolSize: toNumber(process.env.PGPOOL_MAX, 60),
    minPoolSize: toNumber(process.env.PGPOOL_MIN, 10),
    idleTimeoutMs: toNumber(process.env.PGPOOL_IDLE_TIMEOUT_MS, 10000),
    connectionTimeoutMs: toNumber(process.env.PGPOOL_CONNECTION_TIMEOUT_MS, 2000),
    maxUses: toNumber(process.env.PGPOOL_MAX_USES, 0)
  },
  outbox: {
    publishIntervalMs: toNumber(process.env.OUTBOX_PUBLISH_INTERVAL_MS, 3000),
    publishBatchSize: toNumber(process.env.OUTBOX_PUBLISH_BATCH_SIZE, 50),
    maxAttempts: toNumber(process.env.OUTBOX_MAX_ATTEMPTS, 10),
    retryBaseMs: toNumber(process.env.OUTBOX_RETRY_BASE_MS, 1000),
    retryMaxMs: toNumber(process.env.OUTBOX_RETRY_MAX_MS, 60000),
    processingTimeoutMs: toNumber(process.env.OUTBOX_PROCESSING_TIMEOUT_MS, 300000),
    workerId: process.env.OUTBOX_WORKER_ID || `${process.env.HOSTNAME || 'booking-service'}-${process.pid}`
  }
};
