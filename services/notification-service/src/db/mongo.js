const { MongoClient } = require('mongodb');
const logger = require('../utils/logger');

let client = null;
let clientPromise = null;
let indexesPromise = null;
let cachedDbName = null;

function resolveMongoUri() {
  return process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://mongo:27017/notification_service';
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
    logger.debug({ err: error }, '[notification-service] failed to parse mongo uri');
  }

  cachedDbName = 'notification_service';
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
    db.collection('notifications').createIndex({ dedupeKey: 1 }, { unique: true }),
    db.collection('notifications').createIndex({ userId: 1, createdAt: -1 }),
    db.collection('notifications').createIndex({ status: 1, createdAt: -1 }),
    db.collection('notifications').createIndex({ scheduledAt: 1 }),
    db.collection('notification_preferences').createIndex({ userId: 1 }, { unique: true })
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

module.exports = {
  getClient,
  getDb
};
