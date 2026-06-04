import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const successRate = new Rate('case63_success_rate');
const timeoutRate = new Rate('case63_timeout_rate');
const serverErrorRate = new Rate('case63_server_error_rate');
const invalidPriceRate = new Rate('case63_invalid_price_rate');
const timeoutCount = new Counter('case63_timeout_total');

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case63');
  return { autoToken };
}

function isValidPricingResponse(body) {
  const data = body?.data;
  if (!data || typeof data !== 'object') return false;

  const price = Number(data.price);
  const baseFare = Number(data.base_fare);
  const surge = Number(data.surge);
  const demandIndex = Number(data.demand_index);
  const distanceKm = Number(data.distance_km);

  if (!Number.isFinite(price) || price <= 0 || price >= 1e7) return false;
  if (!Number.isFinite(surge) || surge < 1 || surge > 5) return false;
  if (!Number.isFinite(demandIndex) || demandIndex < 1 || demandIndex > 5) return false;
  if (!Number.isFinite(distanceKm) || distanceKm < 0) return false;
  if (Number.isFinite(baseFare) && price < baseFare) return false;

  return true;
}

export const options = {
  scenarios: {
    case63_pricing_spike: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.CASE63_START_RATE || 100),
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.CASE63_VUS || 200),
      maxVUs: Number(__ENV.CASE63_MAX_VUS || 1200),
      stages: [
        { target: Number(__ENV.CASE63_START_RATE || 100), duration: __ENV.CASE63_WARMUP || '5s' },
        { target: Number(__ENV.CASE63_SPIKE_RATE || 1000), duration: '0s' },
        { target: Number(__ENV.CASE63_SPIKE_RATE || 1000), duration: __ENV.CASE63_HOLD || '20s' },
        { target: 100, duration: __ENV.CASE63_COOLDOWN || '5s' }
      ]
    }
  },
  thresholds: {
    case63_success_rate: ['rate>0.995'],
    case63_timeout_rate: ['rate==0'],
    case63_server_error_rate: ['rate<0.01'],
    case63_invalid_price_rate: ['rate==0'],
    http_req_failed: ['rate<0.01'],
    'http_req_duration{case:63}': ['p(95)<300']
  }
};

export default function (data) {
  const demandProfile = [1.2, 2, 5];
  const demandIndex = demandProfile[__ITER % demandProfile.length];
  const payload = JSON.stringify({
    distance_km: 5,
    demand_index: demandIndex,
    supply_index: 1
  });

  const headers = { 'Content-Type': 'application/json' };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = http.post(`${BASE_URL}/v1/pricing/estimate`, payload, {
    headers: {
      ...headers
    },
    timeout: __ENV.CASE63_TIMEOUT || '2s',
    tags: { case: '63', endpoint: 'pricing-estimate' }
  });

  const timedOut = Boolean(res.error_code);
  timeoutRate.add(timedOut);
  if (timedOut) timeoutCount.add(1);

  const serverErr = res.status >= 500;
  serverErrorRate.add(serverErr);

  let validPrice = false;
  if (!timedOut && res.status === 200) {
    try {
      validPrice = isValidPricingResponse(res.json());
    } catch (_e) {
      validPrice = false;
    }
  }

  const success = res.status === 200 && !timedOut && validPrice;
  successRate.add(success);
  invalidPriceRate.add(!timedOut && res.status === 200 && !validPrice);

  check(res, {
    'case63 status 200': (r) => r.status === 200,
    'case63 no timeout': (r) => !r.error_code,
    'case63 price valid': () => validPrice
  });
}
