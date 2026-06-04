const axios = require('axios');
const monitoring = require('../monitoring');
const logger = require('../utils/logger');
const {
  createDependencyCircuitBreaker,
  computeExponentialBackoffMs,
  buildCircuitOpenError
} = require('./dependencyCircuitBreaker');

const baseURL = process.env.PRICING_BASE_URL || 'http://localhost:3006';
const REQUEST_TIMEOUT_MS = Math.max(200, Number(process.env.PRICING_HTTP_TIMEOUT_MS || 1800));
const http = axios.create({ baseURL, timeout: REQUEST_TIMEOUT_MS });
const RETRY_MAX = Number(process.env.PRICING_HTTP_RETRY_MAX || 2);
const RETRY_BACKOFF_BASE_MS = Number(process.env.PRICING_HTTP_RETRY_BACKOFF_MS || 120);
const RETRY_BACKOFF_MAX_MS = Number(process.env.PRICING_HTTP_RETRY_MAX_BACKOFF_MS || 1500);
const CIRCUIT_BREAKER = createDependencyCircuitBreaker({
  name: 'pricing-service',
  enabled: String(process.env.PRICING_CIRCUIT_BREAKER_ENABLED || 'true') !== 'false',
  failureThreshold: Number(process.env.PRICING_CIRCUIT_BREAKER_FAILURE_THRESHOLD || 3),
  openMs: Number(process.env.PRICING_CIRCUIT_BREAKER_OPEN_MS || 12000)
});

class PricingServiceError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = 'PricingServiceError';
    this.code = 'PRICING_UNAVAILABLE';
    this.statusCode = 502;
    this.cause = options.cause;
  }
}

function isFallbackEnabled() {
  const raw = String(process.env.ENABLE_PRICING_FALLBACK_MOCK || '').trim().toLowerCase();
  if (raw === 'true') {
    return true;
  }
  if (raw === 'false') {
    return false;
  }
  return process.env.NODE_ENV !== 'production';
}

function isRetryableError(err) {
  if (!err) {
    return false;
  }
  const code = String(err.code || '').toUpperCase();
  if (['ECONNABORTED', 'ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'EAI_AGAIN', 'ENOTFOUND'].includes(code)) {
    return true;
  }
  const status = Number(err.response?.status);
  return Number.isFinite(status) && status >= 500;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function toNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function haversineKm(from, to) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const lat1 = toNumber(from?.lat);
  const lng1 = toNumber(from?.lng);
  const lat2 = toNumber(to?.lat);
  const lng2 = toNumber(to?.lng);
  if (lat1 === null || lng1 === null || lat2 === null || lng2 === null) {
    return null;
  }
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return 6371 * c;
}

function serviceRate(serviceType) {
  const normalized = String(serviceType || 'STANDARD').toUpperCase();
  if (normalized === 'PREMIUM') {
    return {
      baseFare: 22000,
      perKmRate: 5200,
      perMinRate: 850,
      averageSpeedKmh: 24
    };
  }
  return {
    baseFare: 12000,
    perKmRate: 3800,
    perMinRate: 550,
    averageSpeedKmh: 25
  };
}

function buildLocalFallbackQuote(payload = {}) {
  const rates = serviceRate(payload.serviceType);
  const fallbackDistance = Number.isFinite(Number(payload.distanceKm)) ? Number(payload.distanceKm) : haversineKm(payload.pickup, payload.dropoff);
  const distanceKm = Number.isFinite(fallbackDistance) && fallbackDistance >= 0 ? Number(fallbackDistance.toFixed(3)) : 3.2;
  const durationRaw = (distanceKm / Math.max(8, Number(rates.averageSpeedKmh || 25))) * 60;
  const durationMin = Number(Math.max(1, durationRaw).toFixed(2));
  const estimatedFare = Math.round(Math.max(0, rates.baseFare + rates.perKmRate * distanceKm + rates.perMinRate * durationMin));

  return {
    quoteId: `quote_local_fallback_${Date.now()}`,
    estimatedFare,
    surge: 1,
    currency: 'VND',
    distanceKm,
    durationMin,
    breakdown: {
      base: rates.baseFare,
      perKm: Number((rates.perKmRate * distanceKm).toFixed(2)),
      perMin: Number((rates.perMinRate * durationMin).toFixed(2)),
      discount: 0,
      surge: 0
    },
    expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString()
  };
}

async function postQuoteWithRetry(payload, headers) {
  let lastError = null;
  const totalAttempts = Math.max(1, RETRY_MAX + 1);

  for (let attempt = 1; attempt <= totalAttempts; attempt += 1) {
    const gate = CIRCUIT_BREAKER.allowRequest();
    if (!gate.allowed) {
      throw buildCircuitOpenError('pricing-service', gate);
    }
    try {
      const response = await http.post('/v1/pricing/quotes', payload, { headers });
      CIRCUIT_BREAKER.onSuccess();
      return response;
    } catch (err) {
      CIRCUIT_BREAKER.onFailure();
      lastError = err;
      if (!isRetryableError(err) || attempt >= totalAttempts) {
        break;
      }
      const backoff = computeExponentialBackoffMs({
        attempt,
        baseMs: RETRY_BACKOFF_BASE_MS,
        maxMs: RETRY_BACKOFF_MAX_MS
      });
      await sleep(backoff);
    } finally {
      CIRCUIT_BREAKER.release();
    }
  }

  throw lastError || new Error('pricing_request_failed');
}

function mapServiceType(vehicleType) {
  switch (vehicleType) {
    case 'SUV':
      return 'PREMIUM';
    case 'BIKE':
    case 'CAR':
    default:
      return 'STANDARD';
  }
}

/**
 * Bạn cần pricing-service có endpoint /quote (MVP).
 * Nếu chưa có, bạn có thể tạm mock response ở đây để chạy end-to-end.
 */
async function getQuote({ pickup, dropoff, vehicleType, simulateTimeout = false }) {
  // Option A: gọi thật
  const startedAt = Date.now();
  const serviceType = mapServiceType(vehicleType);
  try {
    if (simulateTimeout) {
      const timeoutError = new Error('simulated pricing timeout');
      timeoutError.code = 'ETIMEDOUT';
      throw timeoutError;
    }
    const headers = {};
    if (process.env.INTERNAL_API_KEY) {
      headers['x-internal-key'] = process.env.INTERNAL_API_KEY;
    }
    const requestPayload = { pickup, dropoff, serviceType };
    const res = await postQuoteWithRetry(requestPayload, headers);
    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'pricing-service',
      operation: 'create_quote',
      outcome: monitoring.toOutcomeFromStatus(res.status),
      durationMs: Date.now() - startedAt,
      attributes: {
        status_code: String(res.status)
      }
    });
    const quote = res.data?.data || res.data || {};
    const surge = Number(quote.surge);
    return {
      ...quote,
      surge: Number.isFinite(surge) && surge >= 1 ? surge : 1
    };
  } catch (err) {
    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'pricing-service',
      operation: 'create_quote',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: {
        error_type: String(err && err.code ? err.code : 'request_failed')
      }
    });
    if (isFallbackEnabled()) {
      logger.warn(
        {
          dependency: 'pricing-service',
          fallback: 'local_quote',
          reason: err.code || err.message,
          circuit_state: CIRCUIT_BREAKER.snapshot().state
        },
        'pricing request failed, using local quote fallback'
      );
      return buildLocalFallbackQuote({
        pickup,
        dropoff,
        serviceType
      });
    }

    throw new PricingServiceError('Pricing service unavailable', {
      cause: err
    });
  }
}

module.exports = { getQuote, PricingServiceError };
