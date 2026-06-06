function parseBoolean(value, defaultValue = false) {
  if (value == null || value === '') {
    return defaultValue;
  }
  const normalized = String(value).trim().toLowerCase();
  if (normalized === 'true' || normalized === '1' || normalized === 'yes') {
    return true;
  }
  if (normalized === 'false' || normalized === '0' || normalized === 'no') {
    return false;
  }
  return defaultValue;
}

function parseNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

const config = {
  serviceName: process.env.SERVICE_NAME || 'payment-service',
  port: Number(process.env.PORT || 3007),
  startup: {
    maxRetries: parseNumber(process.env.STARTUP_MAX_RETRIES, 0),
    retryInitialDelayMs: parseNumber(process.env.STARTUP_RETRY_INITIAL_DELAY_MS, 1000),
    retryMaxDelayMs: parseNumber(process.env.STARTUP_RETRY_MAX_DELAY_MS, 15000)
  },
  db: {
    connectionString: process.env.DATABASE_URL || '',
    host: process.env.PGHOST || 'postgres',
    port: Number(process.env.PGPORT || 5432),
    user: process.env.PGUSER || 'postgres',
    password: process.env.PGPASSWORD || 'postgres',
    database: process.env.PGDATABASE || 'payment-service_db',
    max: Number(process.env.PGPOOL_MAX || 10)
  },
  kafka: {
    clientId: process.env.KAFKA_CLIENT_ID || 'payment-service',
    brokers: (process.env.KAFKA_BROKERS || 'kafka:9092')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean),
    consumerGroupId: process.env.KAFKA_CONSUMER_GROUP_ID || 'payment-service-group',
    consumeTopics: (process.env.KAFKA_CONSUME_TOPICS || '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean),
    partitionsConsumedConcurrently: parseNumber(process.env.KAFKA_CONSUMER_PARTITIONS_CONCURRENCY, 1),
    maxMessagesPerBatch: parseNumber(process.env.KAFKA_CONSUMER_MAX_MESSAGES_PER_BATCH, 100),
    maxBytesPerPartition: parseNumber(process.env.KAFKA_CONSUMER_MAX_BYTES_PER_PARTITION, 1048576),
    minBytes: parseNumber(process.env.KAFKA_CONSUMER_MIN_BYTES, 1),
    maxBytes: parseNumber(process.env.KAFKA_CONSUMER_MAX_BYTES, 10485760),
    maxWaitTimeInMs: parseNumber(process.env.KAFKA_CONSUMER_MAX_WAIT_MS, 5000),
    sessionTimeout: parseNumber(process.env.KAFKA_CONSUMER_SESSION_TIMEOUT_MS, 30000),
    heartbeatInterval: parseNumber(process.env.KAFKA_CONSUMER_HEARTBEAT_INTERVAL_MS, 3000),
    rebalanceTimeout: parseNumber(process.env.KAFKA_CONSUMER_REBALANCE_TIMEOUT_MS, 60000),
    autoCommitInterval: parseNumber(process.env.KAFKA_CONSUMER_AUTO_COMMIT_INTERVAL_MS, 1000),
    autoCommitThreshold: parseNumber(process.env.KAFKA_CONSUMER_AUTO_COMMIT_THRESHOLD, 1),
    retry: {
      retries: parseNumber(process.env.KAFKA_CONSUMER_RETRY_RETRIES, 8),
      initialRetryTime: parseNumber(process.env.KAFKA_CONSUMER_RETRY_INITIAL_MS, 300),
      maxRetryTime: parseNumber(process.env.KAFKA_CONSUMER_RETRY_MAX_MS, 30000)
    },
    producerRetry: {
      retries: parseNumber(process.env.KAFKA_PRODUCER_RETRY_RETRIES, 8),
      initialRetryTime: parseNumber(process.env.KAFKA_PRODUCER_RETRY_INITIAL_MS, 300),
      maxRetryTime: parseNumber(process.env.KAFKA_PRODUCER_RETRY_MAX_MS, 30000)
    },
    producerMaxInFlightRequests: parseNumber(process.env.KAFKA_PRODUCER_MAX_IN_FLIGHT_REQUESTS, 5),
    producerRequestTimeout: parseNumber(process.env.KAFKA_PRODUCER_REQUEST_TIMEOUT_MS, 30000),
    producerAcks: parseNumber(process.env.KAFKA_PRODUCER_ACKS, -1)
  },
  outbox: {
    publishIntervalMs: Number(process.env.OUTBOX_PUBLISH_INTERVAL_MS || 5000),
    publishBatchSize: Number(process.env.OUTBOX_PUBLISH_BATCH_SIZE || 50),
    maxAttempts: Number(process.env.OUTBOX_MAX_ATTEMPTS || 10),
    retryBaseMs: Number(process.env.OUTBOX_RETRY_BASE_MS || 1000),
    retryMaxMs: Number(process.env.OUTBOX_RETRY_MAX_MS || 60000),
    processingTimeoutMs: Number(process.env.OUTBOX_PROCESSING_TIMEOUT_MS || 300000),
    workerId: process.env.OUTBOX_WORKER_ID || `${process.env.HOSTNAME || 'payment-service'}-${process.pid}`
  },
  gateway: {
    retryMax: Number(process.env.PAYMENT_GATEWAY_RETRY_MAX || 2),
    retryBaseMs: Number(process.env.PAYMENT_GATEWAY_RETRY_BASE_MS || 200),
    retryMaxMs: Number(process.env.PAYMENT_GATEWAY_RETRY_MAX_MS || 2000),
    retryMultiplier: Number(process.env.PAYMENT_GATEWAY_RETRY_MULTIPLIER || 2),
    retryJitter: Number(process.env.PAYMENT_GATEWAY_RETRY_JITTER || 0.2),
    timeoutMs: Number(process.env.PAYMENT_GATEWAY_TIMEOUT_MS || 8000)
  },
  services: {
    ride: process.env.RIDE_SERVICE_URL || 'http://ride-service:3005',
    booking: process.env.BOOKING_SERVICE_URL || 'http://booking-service:3003'
  },
  saga: {
    bookingCompensationOnPaymentFailed: {
      enabled: parseBoolean(process.env.PAYMENT_BOOKING_COMPENSATION_ON_FAILED, true),
      path: process.env.PAYMENT_BOOKING_COMPENSATION_PATH || '/v1/bookings/internal/payment-failed-compensation',
      timeoutMs: parseNumber(process.env.PAYMENT_BOOKING_COMPENSATION_TIMEOUT_MS, 2500),
      maxAttempts: Math.max(1, parseNumber(process.env.PAYMENT_BOOKING_COMPENSATION_MAX_ATTEMPTS, 2)),
      retryBackoffMs: Math.max(0, parseNumber(process.env.PAYMENT_BOOKING_COMPENSATION_RETRY_BACKOFF_MS, 200))
    }
  },
  redis: {
    url: process.env.REDIS_URL || 'redis://redis:6379'
  },
  idempotency: {
    ttlSeconds: Number(process.env.IDEMPOTENCY_TTL_SECONDS || 86400),
    lockTtlMs: Number(process.env.IDEMPOTENCY_LOCK_TTL_MS || 15000)
  },
  vietqr: {
    apiUrl: process.env.VIETQR_API_URL || 'https://api.vietqr.io/v2/generate',
    bankBin: process.env.VIETQR_BANK_BIN || '',
    accountNumber: process.env.VIETQR_ACCOUNT_NUMBER || '',
    accountName: process.env.VIETQR_ACCOUNT_NAME || '',
    merchantCity: process.env.VIETQR_MERCHANT_CITY || 'HO CHI MINH',
    format: process.env.VIETQR_FORMAT || 'text',
    clientId: process.env.VIETQR_CLIENT_ID || '',
    apiKey: process.env.VIETQR_API_KEY || '',
    expiresInMinutes: Number(process.env.VIETQR_EXPIRES_IN_MINUTES || 15)
  },
  payos: {
    apiBaseUrl: process.env.PAYOS_API_URL || 'https://api-merchant.payos.vn',
    clientId: process.env.PAYOS_CLIENT_ID || '',
    apiKey: process.env.PAYOS_API_KEY || '',
    checksumKey: process.env.PAYOS_CHECKSUM_KEY || '',
    partnerCode: process.env.PAYOS_PARTNER_CODE || '',
    returnUrl: process.env.PAYOS_RETURN_URL || '',
    cancelUrl: process.env.PAYOS_CANCEL_URL || '',
    qrSource: (process.env.PAYOS_QR_SOURCE || 'PAYOS').trim().toUpperCase(),
    autoSyncEnabled: parseBoolean(process.env.PAYOS_AUTO_SYNC_ENABLED, false),
    autoSyncIntervalMs: Number(process.env.PAYOS_AUTO_SYNC_INTERVAL_MS || 15000),
    autoSyncBatchSize: Number(process.env.PAYOS_AUTO_SYNC_BATCH_SIZE || 20)
  },
  auth: {
    jwtAccessSecret: process.env.JWT_ACCESS_SECRET || process.env.AUTH_JWT_SECRET || process.env.JWT_SECRET || ''
  },
  internalApiKey: process.env.INTERNAL_API_KEY || 'dev-internal-key'
};

module.exports = config;
