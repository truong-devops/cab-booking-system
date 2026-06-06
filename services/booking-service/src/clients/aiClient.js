const axios = require('axios');
const monitoring = require('../monitoring');
const logger = require('../utils/logger');

const baseURL = process.env.AI_BASE_URL || 'http://ai-service:3013';
const http = axios.create({ baseURL, timeout: Number(process.env.AI_REQUEST_TIMEOUT_MS || 1200) });

class AiServiceError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = 'AiServiceError';
    this.code = 'AI_UNAVAILABLE';
    this.statusCode = 502;
    this.cause = options.cause;
  }
}

async function post(path, payload, { authorization, traceId, operation }) {
  const startedAt = Date.now();
  try {
    const res = await http.post(path, payload, {
      headers: {
        authorization: authorization || '',
        'x-trace-id': traceId || ''
      }
    });
    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'ai-service',
      operation,
      outcome: monitoring.toOutcomeFromStatus(res.status),
      durationMs: Date.now() - startedAt,
      attributes: {
        status_code: String(res.status)
      }
    });
    return res.data?.data || res.data || {};
  } catch (error) {
    monitoring.recordDependencyRequest({
      dependencyType: 'http',
      dependencyName: 'ai-service',
      operation,
      outcome: 'error',
      durationMs: Date.now() - startedAt,
      attributes: {
        error_type: String(error?.code || 'request_failed')
      }
    });
    throw new AiServiceError('AI service unavailable', { cause: error });
  }
}

async function recommendDrivers({ pickup, vehicleType, candidates, authorization, traceId }) {
  return post(
    '/v1/ai/recommend-drivers',
    {
      pickup,
      vehicle_type: vehicleType,
      candidates
    },
    {
      authorization,
      traceId,
      operation: 'recommend_drivers'
    }
  );
}

async function agentSelectDriver({ pickup, drop, vehicleType, candidates, context, simulateToolError, simulateModelError, authorization, traceId }) {
  return post(
    '/v1/ai/agent/select-driver',
    {
      pickup,
      drop,
      vehicle_type: vehicleType,
      candidates,
      context,
      simulate_tool_error: Boolean(simulateToolError),
      simulate_model_error: Boolean(simulateModelError)
    },
    {
      authorization,
      traceId,
      operation: 'agent_select_driver'
    }
  );
}

async function forecastDemand({ zoneId, horizonMin, timestamp, authorization, traceId }) {
  return post(
    '/v1/ai/forecast-demand',
    {
      zone_id: zoneId,
      horizon_min: horizonMin,
      timestamp
    },
    {
      authorization,
      traceId,
      operation: 'forecast_demand'
    }
  );
}

async function scoreFraud({ payload, authorization, traceId }) {
  return post('/v1/ai/fraud-score', payload, {
    authorization,
    traceId,
    operation: 'fraud_score'
  });
}

function logAiFallback(req, reason) {
  logger.withTrace(req).warn(
    {
      dependency: 'ai-service',
      reason: reason || 'unknown'
    },
    'ai-service request failed, fallback to local rules'
  );
}

module.exports = {
  recommendDrivers,
  agentSelectDriver,
  forecastDemand,
  scoreFraud,
  logAiFallback,
  AiServiceError
};
