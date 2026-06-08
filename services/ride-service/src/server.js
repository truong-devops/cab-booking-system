require('dotenv').config();
require('./observability');
const app = require('./app');
const { start: startConsumer } = require('./messaging/consumer');
const { startInboxProcessor } = require('./messaging/inboxProcessor');
const { startOutboxPoller } = require('./messaging/outboxPoller');
const redis = require('./cache/redis');
const { getClient, getDb } = require('./db/mongo');
const logger = require('./utils/logger');

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const port = Number(process.env.PORT || 3005);

async function runWithRetry(taskName, task) {
  const maxRetries = Math.max(0, Number(process.env.STARTUP_MAX_RETRIES || 0));
  const baseDelay = Math.max(100, Number(process.env.STARTUP_RETRY_INITIAL_DELAY_MS || 1000));
  const maxDelay = Math.max(baseDelay, Number(process.env.STARTUP_RETRY_MAX_DELAY_MS || 15000));
  let attempt = 0;

  while (true) {
    try {
      return await task();
    } catch (error) {
      attempt += 1;
      if (maxRetries > 0 && attempt > maxRetries) {
        throw error;
      }
      const delay = Math.min(maxDelay, baseDelay * 2 ** Math.min(attempt - 1, 8));
      logger.warn({ attempt, retry_in_ms: delay, err: error }, `[ride-service] ${taskName} failed, retrying`);
      await sleep(delay);
    }
  }
}

async function start() {
  await runWithRetry('mongo init', getDb);
  await runWithRetry('redis readiness', () => redis.ping());

  const stopInboxProcessor = startInboxProcessor();
  const stopOutboxPoller = startOutboxPoller();
  let stopConsumer = null;
  let shuttingDown = false;

  const startConsumerInBackground = async () => {
    while (!shuttingDown) {
      try {
        stopConsumer = await startConsumer();
        logger.info('[ride-service] kafka consumer started');
        return;
      } catch (error) {
        logger.error({ err: error }, '[ride-service] kafka consumer start failed, retrying');
        await sleep(Math.max(1000, Number(process.env.STARTUP_RETRY_INITIAL_DELAY_MS || 1000)));
      }
    }
  };

  const server = app.listen(port, () => {
    logger.info({ port }, '[ride-service] listening');
    startConsumerInBackground().catch((error) => {
      logger.error({ err: error }, '[ride-service] consumer retry loop crashed');
    });
  });

  const shutdown = async () => {
    shuttingDown = true;
    stopInboxProcessor();
    stopOutboxPoller();
    server.close();
    if (stopConsumer) {
      await stopConsumer();
    }
    await redis.quit();
    const mongoClient = await getClient();
    await mongoClient.close();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

start().catch((error) => {
  logger.error({ err: error }, '[ride-service] failed to bootstrap');
  process.exit(1);
});
