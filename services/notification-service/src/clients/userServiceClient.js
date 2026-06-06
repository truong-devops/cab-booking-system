const logger = require('../utils/logger');
const monitoring = require('../monitoring');

const fetchFn = global.fetch || require('node-fetch');

const CACHE_TTL_MS = Number(process.env.USER_CACHE_TTL_MS || 5 * 60 * 1000);
const DEFAULT_TIMEOUT_MS = Number(process.env.USER_SERVICE_TIMEOUT_MS || 2000);
const DEFAULT_RETRY_COUNT = Number(process.env.USER_SERVICE_RETRY || 1);

const cache = new Map();

function getCache(userId) {
  const entry = cache.get(userId);
  if (!entry) {
    return null;
  }
  if (Date.now() > entry.expiresAt) {
    cache.delete(userId);
    return null;
  }
  return entry.value;
}

function setCache(userId, value) {
  cache.set(userId, {
    value,
    expiresAt: Date.now() + CACHE_TTL_MS
  });
}

function buildHeaders(context) {
  const headers = {};
  if (context?.authorization) {
    headers.authorization = context.authorization;
  }
  if (context?.traceId) {
    headers['x-trace-id'] = context.traceId;
  }
  if (context?.requestId) {
    headers['x-request-id'] = context.requestId;
  }
  if (context?.correlationId) {
    headers['x-correlation-id'] = context.correlationId;
  }
  if (context?.forwardedFor) {
    headers['x-forwarded-for'] = context.forwardedFor;
  }
  if (context?.realIp) {
    headers['x-real-ip'] = context.realIp;
  }

  const internalKey = process.env.INTERNAL_API_KEY;
  if (internalKey) {
    headers['x-internal-key'] = internalKey;
  }
  return headers;
}

function normalizeUser(payload) {
  if (!payload) {
    return null;
  }

  const contacts = payload.contacts || {};
  const roles = Array.isArray(payload.roles) && payload.roles.length ? payload.roles : payload.role ? [payload.role] : [];
  let pushTokens = [];
  if (Array.isArray(contacts.pushTokens)) {
    pushTokens = contacts.pushTokens;
  } else if (Array.isArray(payload.pushTokens)) {
    pushTokens = payload.pushTokens;
  } else if (payload.pushToken) {
    pushTokens = [payload.pushToken];
  }

  return {
    id: payload.id,
    status: payload.status,
    roles,
    contacts: {
      email: contacts.email || payload.email || null,
      phone: contacts.phone || payload.phone || null,
      pushTokens
    },
    locale: payload.locale || null
  };
}

async function requestWithRetry(url, options, retryCount) {
  let lastError;
  for (let attempt = 0; attempt <= retryCount; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
    const startedAt = Date.now();
    try {
      const response = await fetchFn(url, {
        ...options,
        signal: controller.signal
      });
      monitoring.recordDependencyRequest({
        dependencyType: 'http',
        dependencyName: 'user-service',
        operation: 'get_user',
        outcome: monitoring.toOutcomeFromStatus(response.status),
        durationMs: Date.now() - startedAt,
        attributes: {
          status_code: String(response.status),
          attempt: String(attempt + 1)
        }
      });
      return response;
    } catch (error) {
      lastError = error;
      monitoring.recordDependencyRequest({
        dependencyType: 'http',
        dependencyName: 'user-service',
        operation: 'get_user',
        outcome: 'error',
        durationMs: Date.now() - startedAt,
        attributes: {
          error_type: String(error && error.name ? error.name : 'request_failed'),
          attempt: String(attempt + 1)
        }
      });
      if (attempt < retryCount) {
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    } finally {
      clearTimeout(timeout);
    }
  }
  throw lastError;
}

async function getUserById(userId, context = {}) {
  const cached = getCache(userId);
  if (cached) {
    return cached;
  }

  const baseUrl = process.env.USER_SERVICE_BASE_URL || process.env.USER_SERVICE_URL || 'http://user-service:4004';

  const internalKey = process.env.INTERNAL_API_KEY;
  const path = internalKey ? `/internal/users/${userId}` : `/v1/users/${userId}`;

  const url = new URL(path, baseUrl).toString();
  const headers = buildHeaders(context);

  const response = await requestWithRetry(url, { method: 'GET', headers }, DEFAULT_RETRY_COUNT);

  if (response.status === 404) {
    return null;
  }

  const contentType = response.headers.get('content-type') || '';
  const rawBody = await response.text();
  const body = contentType.includes('application/json') ? JSON.parse(rawBody || '{}') : null;

  if (!response.ok) {
    const error = new Error('User service request failed');
    error.status = response.status;
    error.body = body;
    throw error;
  }

  const data = body?.data || body;
  const normalized = normalizeUser(data);
  if (normalized) {
    setCache(userId, normalized);
  }
  return normalized;
}

module.exports = {
  getUserById
};
