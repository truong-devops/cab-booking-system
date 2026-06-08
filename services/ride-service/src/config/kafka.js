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

function parseBrokers(value) {
  return String(value || 'kafka:9092')
    .split(',')
    .map((broker) => broker.trim())
    .filter(Boolean);
}

function buildSaslConfig() {
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

function buildKafkaClientOptions({ clientId, retry }) {
  return {
    clientId,
    brokers: parseBrokers(process.env.KAFKA_BROKERS),
    ssl: parseBoolean(process.env.KAFKA_SSL, false),
    sasl: buildSaslConfig(),
    retry
  };
}

module.exports = {
  buildKafkaClientOptions,
  parseBoolean,
  parseBrokers
};
