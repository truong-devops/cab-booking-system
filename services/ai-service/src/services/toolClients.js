const axios = require('axios');
const agentConfig = require('../config/agent-config.json');

function nowMs() {
  return Number(process.hrtime.bigint()) / 1e6;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function toNumber(value, fallback = null) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function resolveRetryConfig() {
  const conf = agentConfig.retry || {};
  const maxAttempts = Math.max(1, Number(process.env.AI_AGENT_TOOL_MAX_ATTEMPTS || conf.max_attempts || 3));
  const timeoutMs = Math.max(10, Number(process.env.AI_AGENT_TOOL_TIMEOUT_MS || conf.timeout_ms || 120));
  const jitterMs = Math.max(0, Number(process.env.AI_AGENT_TOOL_JITTER_MS || conf.jitter_ms || 20));

  const configuredBackoff = Array.isArray(conf.backoff_ms) && conf.backoff_ms.length ? conf.backoff_ms : [50, 100, 200];
  const fallbackBackoff = configuredBackoff.map((item) => Math.max(0, Number(item) || 0));

  return {
    maxAttempts,
    timeoutMs,
    jitterMs,
    backoffMs: fallbackBackoff
  };
}

function sleep(ms) {
  if (!Number.isFinite(ms) || ms <= 0) {
    return Promise.resolve();
  }
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withTimeout(promise, timeoutMs) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return promise;
  }

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const err = new Error('tool timeout');
      err.code = 'ETIMEDOUT';
      reject(err);
    }, timeoutMs);

    promise
      .then((result) => {
        clearTimeout(timer);
        resolve(result);
      })
      .catch((error) => {
        clearTimeout(timer);
        reject(error);
      });
  });
}

function calculateJitter(jitterMs) {
  if (!Number.isFinite(jitterMs) || jitterMs <= 0) {
    return 0;
  }
  return Math.floor(Math.random() * jitterMs);
}

function createRetryExecutor({ tool, simulateToolError = false }) {
  const retryConfig = resolveRetryConfig();
  let simulatedOnce = false;

  return async function execute(fn) {
    const startedAt = nowMs();
    let lastError = null;

    for (let attempt = 1; attempt <= retryConfig.maxAttempts; attempt += 1) {
      try {
        if (simulateToolError && !simulatedOnce) {
          simulatedOnce = true;
          const simulated = new Error(`simulated ${tool} error`);
          simulated.code = 'SIMULATED_TOOL_ERROR';
          throw simulated;
        }

        const data = await withTimeout(Promise.resolve().then(() => fn(attempt)), retryConfig.timeoutMs);
        return {
          tool,
          ok: true,
          status: 200,
          attempts: attempt,
          latency_ms: Number((nowMs() - startedAt).toFixed(2)),
          data
        };
      } catch (error) {
        lastError = error;
        if (attempt < retryConfig.maxAttempts) {
          const backoff = retryConfig.backoffMs[Math.min(attempt - 1, retryConfig.backoffMs.length - 1)] || 0;
          await sleep(backoff + calculateJitter(retryConfig.jitterMs));
        }
      }
    }

    return {
      tool,
      ok: false,
      status: Number(lastError?.response?.status || 503),
      attempts: retryConfig.maxAttempts,
      latency_ms: Number((nowMs() - startedAt).toFixed(2)),
      error: {
        code: String(lastError?.code || 'TOOL_FAILED'),
        message: String(lastError?.message || 'tool failed')
      }
    };
  };
}

function haversineKm(from, to) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const lat1 = toNumber(from?.lat);
  const lng1 = toNumber(from?.lng);
  const lat2 = toNumber(to?.lat);
  const lng2 = toNumber(to?.lng);
  if (![lat1, lng1, lat2, lng2].every((v) => Number.isFinite(v))) {
    return null;
  }

  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return 6371 * c;
}

function estimateEtaByDistance(distanceKm, trafficLevel = 0.4) {
  const safeDistanceKm = Math.max(0, Number(distanceKm) || 0);
  if (safeDistanceKm === 0) {
    return 0;
  }
  const safeTraffic = clamp(Number(trafficLevel) || 0.4, 0, 1);
  const speedKmh = Math.max(8, 30 - safeTraffic * 16);
  return Math.max(1, Math.round((safeDistanceKm / speedKmh) * 60));
}

function estimateFareByDistance(distanceKm, demandIndex = 1.2) {
  const safeDistanceKm = Math.max(0, Number(distanceKm) || 0);
  const safeDemand = Math.max(1, Number(demandIndex) || 1.2);
  const baseFare = 12000;
  const perKm = 5000;
  return Math.max(1000, Math.round((baseFare + safeDistanceKm * perKm) * safeDemand));
}

function scoreFromFare(fareVnd) {
  const fare = Math.max(1, Number(fareVnd) || 1);
  return clamp(1 - fare / 120000, 0.05, 1);
}

function buildHeaders({ authorization, traceId }) {
  const headers = {
    'x-trace-id': traceId || ''
  };
  if (authorization) {
    headers.authorization = authorization;
  }
  const internalKey = process.env.INTERNAL_API_KEY || (process.env.NODE_ENV === 'production' ? '' : 'dev-internal-key');
  if (internalKey) {
    headers['x-internal-key'] = internalKey;
  }
  return headers;
}

function shouldUseRemoteTools(context = {}) {
  if (context.use_remote_tools === true) {
    return true;
  }
  return String(process.env.AI_AGENT_USE_REMOTE_TOOLS || '').toLowerCase() === 'true';
}

function resolveDistanceKm({ pickup, drop, candidate }) {
  const fromCandidate = toNumber(candidate?.distance_m);
  if (Number.isFinite(fromCandidate)) {
    return Math.max(0, fromCandidate / 1000);
  }
  const byGeo = haversineKm(pickup, drop);
  if (Number.isFinite(byGeo)) {
    return Math.max(0, byGeo);
  }
  return 1;
}

async function fetchDriverAvailability({ pickup, candidates = [], context = {}, simulateToolError = false }) {
  const execute = createRetryExecutor({ tool: 'driver_availability', simulateToolError });
  const result = await execute(async () => {
    const onlineItems = (Array.isArray(candidates) ? candidates : []).filter((item) => item && item.online !== false);
    return {
      pickup,
      objective: context.objective || 'auto',
      count: onlineItems.length
    };
  });

  return result;
}

async function fetchEta({ pickup, drop, candidate, context = {}, authorization, traceId, simulateToolError = false }) {
  const execute = createRetryExecutor({ tool: 'eta', simulateToolError });
  const distanceKm = resolveDistanceKm({ pickup, drop, candidate });
  const trafficLevel = clamp(Number(context.traffic_level ?? agentConfig.defaults.traffic_level), 0, 1);
  const useRemote = shouldUseRemoteTools(context);
  const etaBaseUrl = process.env.ETA_SERVICE_URL || process.env.ETA_BASE_URL || 'http://eta-service:3012';

  const result = await execute(async () => {
    if (!useRemote) {
      return {
        eta_min: estimateEtaByDistance(distanceKm, trafficLevel),
        distance_km: Number(distanceKm.toFixed(3)),
        source: 'eta-local'
      };
    }

    const response = await axios.post(
      `${etaBaseUrl}/v1/eta/estimate`,
      {
        distance_km: Number(distanceKm.toFixed(3)),
        traffic_level: trafficLevel,
        pickup,
        drop
      },
      {
        timeout: resolveRetryConfig().timeoutMs,
        headers: buildHeaders({ authorization, traceId })
      }
    );

    const etaMin = toNumber(response?.data?.data?.eta_minutes);
    if (!Number.isFinite(etaMin)) {
      throw new Error('Invalid eta response');
    }

    return {
      eta_min: Math.max(0, etaMin),
      distance_km: Number(distanceKm.toFixed(3)),
      source: 'eta-service'
    };
  });

  if (result.ok) {
    return result;
  }

  return {
    ...result,
    data: {
      eta_min: estimateEtaByDistance(distanceKm, trafficLevel),
      distance_km: Number(distanceKm.toFixed(3)),
      source: 'eta-fallback'
    }
  };
}

async function fetchPricing({ pickup, drop, candidate, context = {}, authorization, traceId, simulateToolError = false }) {
  const execute = createRetryExecutor({ tool: 'pricing', simulateToolError });
  const distanceKm = resolveDistanceKm({ pickup, drop, candidate });
  const demandIndex = Math.max(1, Number(context.demand_index ?? agentConfig.defaults.demand_index));
  const useRemote = shouldUseRemoteTools(context);
  const pricingBaseUrl = process.env.PRICING_SERVICE_URL || process.env.PRICING_BASE_URL || 'http://pricing-service:3006';

  const result = await execute(async () => {
    if (!useRemote) {
      const localFare = estimateFareByDistance(distanceKm, demandIndex);
      return {
        estimated_fare: localFare,
        surge: Math.max(1, demandIndex),
        price_score: scoreFromFare(localFare),
        source: 'pricing-local'
      };
    }

    const response = await axios.post(
      `${pricingBaseUrl}/v1/pricing/estimate`,
      {
        distance_km: Number(distanceKm.toFixed(3)),
        demand_index: demandIndex
      },
      {
        timeout: resolveRetryConfig().timeoutMs,
        headers: buildHeaders({ authorization, traceId })
      }
    );

    const fare = toNumber(response?.data?.data?.price);
    const surge = toNumber(response?.data?.data?.surge, demandIndex);
    if (!Number.isFinite(fare)) {
      throw new Error('Invalid pricing response');
    }

    return {
      estimated_fare: Math.max(1, fare),
      surge: Math.max(1, surge),
      price_score: scoreFromFare(fare),
      source: 'pricing-service'
    };
  });

  if (result.ok) {
    return result;
  }

  const fallbackFare = estimateFareByDistance(distanceKm, demandIndex);
  return {
    ...result,
    data: {
      estimated_fare: fallbackFare,
      surge: Math.max(1, demandIndex),
      price_score: scoreFromFare(fallbackFare),
      source: 'pricing-fallback'
    }
  };
}

module.exports = {
  fetchDriverAvailability,
  fetchEta,
  fetchPricing,
  estimateEtaByDistance,
  estimateFareByDistance,
  scoreFromFare,
  createRetryExecutor
};
