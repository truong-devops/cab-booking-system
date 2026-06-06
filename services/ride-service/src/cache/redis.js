const Redis = require('ioredis');
const monitoring = require('../monitoring');

const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379', {
  lazyConnect: process.env.NODE_ENV === 'test'
});

function wrapCommand(method, operation = method) {
  if (typeof redis[method] !== 'function') {
    return;
  }

  const original = redis[method].bind(redis);
  redis[method] = async (...args) => {
    const startedAt = Date.now();
    try {
      const result = await original(...args);
      monitoring.recordDependencyRequest({
        dependencyType: 'redis',
        dependencyName: 'redis',
        operation,
        outcome: 'success',
        durationMs: Date.now() - startedAt
      });
      return result;
    } catch (error) {
      monitoring.recordDependencyRequest({
        dependencyType: 'redis',
        dependencyName: 'redis',
        operation,
        outcome: 'error',
        durationMs: Date.now() - startedAt,
        attributes: {
          error_type: String(error && error.code ? error.code : 'redis_error')
        }
      });
      throw error;
    }
  };
}

['get', 'set', 'del', 'ping'].forEach((command) => wrapCommand(command));

module.exports = redis;
