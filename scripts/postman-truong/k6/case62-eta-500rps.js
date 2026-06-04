import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || __ENV.ETA_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const successRate = new Rate('case62_success_rate');
const timeoutRate = new Rate('case62_timeout_rate');
const invalidPayloadRate = new Rate('case62_invalid_payload_rate');
const timeoutCount = new Counter('case62_timeout_total');

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case62');
  return { autoToken };
}

function isValidEtaResponse(body) {
  const data = body?.data;
  if (!data || typeof data !== 'object') return false;
  const distance = Number(data.distance_km);
  const traffic = Number(data.traffic_level);
  const eta = Number(data.eta_minutes);
  return (
    Number.isFinite(distance) &&
    distance >= 0 &&
    Number.isFinite(traffic) &&
    traffic >= 0 &&
    traffic <= 1 &&
    Number.isFinite(eta) &&
    eta >= 0
  );
}

export const options = {
  scenarios: {
    case62_eta_rps: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE62_RATE || 500),
      timeUnit: '1s',
      duration: __ENV.CASE62_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE62_VUS || 140),
      maxVUs: Number(__ENV.CASE62_MAX_VUS || 800)
    }
  },
  thresholds: {
    case62_success_rate: ['rate>0.995'],
    case62_timeout_rate: ['rate==0'],
    case62_invalid_payload_rate: ['rate==0'],
    http_req_failed: ['rate<0.01'],
    'http_req_duration{case:62}': ['p(95)<200']
  }
};

export default function (data) {
  const payload = JSON.stringify({
    distance_km: 4.7,
    traffic_level: 0.6
  });

  const headers = { 'Content-Type': 'application/json' };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = http.post(`${BASE_URL}/v1/eta/estimate`, payload, {
    headers: {
      ...headers
    },
    timeout: __ENV.CASE62_TIMEOUT || '2s',
    tags: { case: '62', endpoint: 'eta-estimate' }
  });

  const timedOut = Boolean(res.error_code);
  timeoutRate.add(timedOut);
  if (timedOut) timeoutCount.add(1);

  let validPayload = false;
  if (!timedOut && res.status === 200) {
    try {
      validPayload = isValidEtaResponse(res.json());
    } catch (_e) {
      validPayload = false;
    }
  }

  const success = res.status === 200 && !timedOut && validPayload;
  successRate.add(success);
  invalidPayloadRate.add(!timedOut && res.status === 200 && !validPayload);

  check(res, {
    'case62 status 200': (r) => r.status === 200,
    'case62 no timeout': (r) => !r.error_code,
    'case62 payload valid': () => validPayload
  });

  sleep(0.001);
}
