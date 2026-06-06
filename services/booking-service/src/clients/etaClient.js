const axios = require('axios');
const monitoring = require('../monitoring');
const logger = require('../utils/logger');
const {
  createDependencyCircuitBreaker,
  computeExponentialBackoffMs,
  buildCircuitOpenError
} = require('./dependencyCircuitBreaker');

const baseURL = process.env.ETA_BASE_URL || 'http://eta-service:3012';
const REQUEST_TIMEOUT_MS = Math.max(200, Number(process.env.ETA_HTTP_TIMEOUT_MS || 1500));
const RETRY_MAX = Number(process.env.ETA_HTTP_RETRY_MAX || 1);
const RETRY_BACKOFF_BASE_MS = Number(process.env.ETA_HTTP_RETRY_BACKOFF_MS || 100);
const RETRY_BACKOFF_MAX_MS = Number(process.env.ETA_HTTP_RETRY_MAX_BACKOFF_MS || 1200);
const CIRCUIT_BREAKER = createDependencyCircuitBreaker({
  name: 'eta-service',
  enabled: String(process.env.ETA_CIRCUIT_BREAKER_ENABLED || 'true') !== 'false',
  failureThreshold: Number(process.env.ETA_CIRCUIT_BREAKER_FAILURE_THRESHOLD || 3),
  openMs: Number(process.env.ETA_CIRCUIT_BREAKER_OPEN_MS || 12000)
});
const http = axios.create({ baseURL, timeout: REQUEST_TIMEOUT_MS });

class EtaServiceError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = 'EtaServiceError';
    this.code = 'ETA_UNAVAILABLE';
    this.statusCode = 502;
    this.cause = options.cause;
  }
}

function haversineKm(from, to) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const lat1 = Number(from?.lat);
  const lng1 = Number(from?.lng);
  const lat2 = Number(to?.lat);
  const lng2 = Number(to?.lng);
  if (!Number.isFinite(lat1) || !Number.isFinite(lng1) || !Number.isFinite(lat2) || !Number.isFinite(lng2)) {
    return 0;
  }
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return 6371 * c;
}

function localFallbackEta({ pickup, drop, distanceKm, trafficLevel }) {
  const normalizedDistance = Number.isFinite(distanceKm) && distanceKm >= 0 ? distanceKm : haversineKm(pickup, drop);
  const normalizedTraffic = Number.isFinite(trafficLevel) ? Math.min(1, Math.max(0, trafficLevel)) : 0.4;

  if (normalizedDistance <= 0) {
    return { etaMinutes: 0, distanceKm: 0 };
  }

  const speedKmh = Math.max(8, 28 - normalizedTraffic * 14);
  const etaMinutes = Math.max(1, Math.round((normalizedDistance / speedKmh) * 60));
  return {
    etaMinutes,
    distanceKm: Number(normalizedDistance.toFixed(3))
  };
}

function isFallbackEnabled() {
  if (process.env.NODE_ENV === 'production') {
    return false;
  }
  return process.env.ENABLE_ETA_FALLBACK_MOCK !== 'false';
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function estimateEta({ pickup, drop, distanceKm, trafficLevel }) {
  const startedAt = Date.now();
  try {
    const payload = {
      pickup,
      drop,
      distance_km: distanceKm,
      traffic_level: trafficLevel
    };
    const totalAttempts = Math.max(1, RETRY_MAX + 1);
    let res = null;
    let lastError = null;
    for (let attempt = 1; attempt <= totalAttempts; attempt += 1) {
      const gate = CIRCUIT_BREAKER.allowRequest();
      if (!gate.allowed) {
        lastError = buildCircuitOpenError('eta-service', gate);
        break;
      }
      try {
        res = await http.post('/v1/eta/estimate', payload);
        CIRCUIT_BREAKER.onSuccess();
        break;
      } catch (error) {
        CIRCUIT_BREAKER.onFailure();
        lastError = error;
        const code = String(error?.code || '').toUpperCase();
        const retryableCode = ['ECONNABORTED', 'ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'EAI_AGAIN'].includes(code);
        const status = Number(error?.response?.status);
        const retryableStatus = Number.isFinite(status) && status >= 500;
        const retryable = retryableCode || retryableStatus;
        if (!retryable || attempt >= totalAttempts) {
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

    if (!res) {
      throw lastError || new Error('eta_request_failed');
    }

    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'eta-service',
      operation: 'estimate_eta',
      outcome: monitoring.toOutcomeFromStatus(res.status),
      durationMs: Date.now() - startedAt,
      attributes: { status_code: String(res.status) }
    });
    const data = res.data?.data || res.data || {};
    const etaMinutes = Number(data.eta_minutes);
    const resolvedDistanceKm = Number(data.distance_km);
    if (!Number.isFinite(etaMinutes) || etaMinutes < 0) {
      throw new EtaServiceError('ETA response invalid');
    }
    return {
      etaMinutes: Math.round(etaMinutes),
      distanceKm: Number.isFinite(resolvedDistanceKm) ? Number(resolvedDistanceKm.toFixed(3)) : undefined
    };
  } catch (error) {
    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'eta-service',
      operation: 'estimate_eta',
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: {
        error_type: String(error?.code || 'request_failed')
      }
    });

    if (isFallbackEnabled()) {
      logger.warn(
        {
          dependency: 'eta-service',
          fallback: 'local_rule',
          reason: error?.code || error?.message,
          circuit_state: CIRCUIT_BREAKER.snapshot().state
        },
        'eta request failed, using local fallback eta'
      );
      return localFallbackEta({
        pickup,
        drop,
        distanceKm,
        trafficLevel
      });
    }

    throw new EtaServiceError('ETA service unavailable', {
      cause: error
    });
  }
}

module.exports = {
  estimateEta,
  EtaServiceError
};
