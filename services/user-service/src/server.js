require('dotenv').config();
require('./observability');

const app = require('./app');
const logger = require('./utils/logger');
const pool = require('./db/pool');

const port = Number(process.env.PORT || 4004);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

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
      logger.warn({ attempt, retry_in_ms: delay, err: error }, `[user-service] ${taskName} failed, retrying`);
      await sleep(delay);
    }
  }
}

async function start() {
  await runWithRetry('postgres readiness', () => pool.query('SELECT 1'));
  const server = app.listen(port, () => {
    logger.info({ port }, '[user-service] listening');
  });

  const shutdown = async () => {
    server.close();
    await pool.end();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

start().catch((error) => {
  logger.error({ err: error }, '[user-service] failed to bootstrap');
  process.exit(1);
});
