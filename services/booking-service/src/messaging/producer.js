const { Kafka } = require('kafkajs');
const config = require('../config');

const kafka = new Kafka({
  clientId: config.kafka.clientId,
  brokers: config.kafka.brokers,
  ssl: config.kafka.ssl,
  sasl: config.kafka.sasl,
  retry: config.kafka.producerRetry,
  requestTimeout: config.kafka.requestTimeoutMs,
  connectionTimeout: config.kafka.connectionTimeoutMs
});

let producerPromise = null;

async function getProducer() {
  if (!producerPromise) {
    const producer = kafka.producer({
      transactionTimeout: config.kafka.producerConnectTimeoutMs,
      maxInFlightRequests: config.kafka.producerMaxInFlightRequests,
      idempotent: true,
      retry: config.kafka.producerRetry
    });
    producerPromise = producer
      .connect()
      .then(() => producer)
      .catch((error) => {
        producerPromise = null;
        throw error;
      });
  }
  return producerPromise;
}

async function publish(topic, message, options = {}) {
  const producer = await getProducer();
  await producer.send({
    topic,
    acks: config.kafka.producerAcks,
    timeout: config.kafka.producerRequestTimeoutMs,
    messages: [
      {
        key: options.key || null,
        value: JSON.stringify(message),
        headers: options.headers || undefined
      }
    ]
  });
}

async function disconnect() {
  if (!producerPromise) {
    return;
  }
  const producer = await producerPromise;
  await producer.disconnect();
  producerPromise = null;
}

module.exports = { publish, disconnect };
