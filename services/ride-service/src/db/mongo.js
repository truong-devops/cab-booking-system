const { MongoClient } = require('mongodb');
const logger = require('../utils/logger');

let client = null;
let clientPromise = null;
let indexesPromise = null;
let cachedDbName = null;

function resolveMongoUri() {
  return process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://mongo:27017/ride_service';
}

function resolveDbName(uri) {
  if (cachedDbName) {
    return cachedDbName;
  }

  const envDb = process.env.MONGODB_DB || process.env.MONGO_DB;
  if (envDb) {
    cachedDbName = envDb;
    return envDb;
  }

  try {
    const url = new URL(uri);
    const path = url.pathname || '';
    const parsed = path.replace(/^\/+/, '');
    if (parsed) {
      cachedDbName = parsed;
      return parsed;
    }
  } catch (error) {
    logger.debug({ err: error }, '[ride-service] failed to parse mongo uri');
  }

  cachedDbName = 'ride_service';
  return cachedDbName;
}

async function getClient() {
  if (client) {
    return client;
  }

  if (!clientPromise) {
    const uri = resolveMongoUri();
    const poolSize = Number(process.env.MONGO_POOL_SIZE || 10);
    clientPromise = MongoClient.connect(uri, {
      maxPoolSize: Number.isFinite(poolSize) ? poolSize : 10
    }).then((connected) => {
      client = connected;
      return connected;
    });
  }

  return clientPromise;
}

async function ensureIndexes(db) {
  await Promise.all([
    db.collection('rides').createIndex({ external_ride_id: 1 }, { unique: true }),
    db.collection('rides').createIndex({ rider_id: 1, created_at: -1 }),
    db.collection('rides').createIndex({ status: 1, created_at: -1 }),
    db.collection('ride_status_history').createIndex({ ride_id: 1, occurred_at: -1 }),
    db.collection('idempotency_keys').createIndex({ route_key: 1, user_id: 1, idem_key: 1 }, { unique: true }),
    db.collection('inbox_events').createIndex({ event_id: 1, consumer: 1 }, { unique: true }),
    db.collection('inbox_events').createIndex({ topic: 1, received_at: -1 }),
    db.collection('inbox_events').createIndex({ state: 1, next_retry_at: 1, received_at: 1 }),
    db.collection('outbox_events').createIndex({ status: 1, next_retry_at: 1, occurred_at: 1 }),
    db.collection('outbox_events').createIndex({ event_id: 1 }, { unique: true })
  ]);
}

async function getDb() {
  const mongoClient = await getClient();
  const dbName = resolveDbName(resolveMongoUri());
  const db = mongoClient.db(dbName);

  if (!indexesPromise) {
    indexesPromise = ensureIndexes(db).catch((error) => {
      indexesPromise = null;
      throw error;
    });
  }

  await indexesPromise;
  return db;
}

async function runWithOptionalTransaction(fn) {
  const mongoClient = await getClient();

  if (process.env.MONGODB_TRANSACTIONS === 'false') {
    return fn(null);
  }

  const session = mongoClient.startSession();
  try {
    let result;
    await session.withTransaction(async () => {
      result = await fn(session);
    });
    return result;
  } catch (error) {
    const message = String(error?.message || '');
    if (message.includes('Transaction numbers') || message.includes('replica set') || message.includes('mongos')) {
      return fn(null);
    }
    throw error;
  } finally {
    await session.endSession();
  }
}

module.exports = {
  getClient,
  getDb,
  runWithOptionalTransaction
};
