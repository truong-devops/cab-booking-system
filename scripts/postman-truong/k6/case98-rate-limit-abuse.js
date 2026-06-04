import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const rateLimitHitRate = new Rate('case98_rate_limit_hit_rate');
const timeoutRate = new Rate('case98_timeout_rate');
const serverErrorRate = new Rate('case98_server_error_rate');
const unexpectedStatusRate = new Rate('case98_unexpected_status_rate');
const healthOkRate = new Rate('case98_health_ok_rate');

const bookingExpectedStatuses = http.expectedStatuses(200, 201, 202, 409, 422, 429);

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case98');
  return { autoToken };
}

export const options = {
  scenarios: {
    case98_abuse_attack: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE98_RATE || 150),
      timeUnit: '1s',
      duration: __ENV.CASE98_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE98_VUS || 80),
      maxVUs: Number(__ENV.CASE98_MAX_VUS || 400),
      exec: 'abuseAttack'
    },
    case98_gateway_health_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE98_HEALTH_RATE || 3),
      timeUnit: '1s',
      duration: __ENV.CASE98_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE98_HEALTH_VUS || 3),
      maxVUs: Number(__ENV.CASE98_HEALTH_MAX_VUS || 20),
      exec: 'healthProbe'
    }
  },
  thresholds: {
    case98_rate_limit_hit_rate: ['rate>0.50'],
    case98_timeout_rate: ['rate<0.01'],
    case98_server_error_rate: ['rate<0.01'],
    case98_unexpected_status_rate: ['rate<0.01'],
    case98_health_ok_rate: ['rate==1'],
    'http_req_duration{case:98,endpoint:bookings}': ['p(95)<300'],
    'http_req_duration{case:98,endpoint:health}': ['p(95)<200']
  }
};

export function abuseAttack(data) {
  const payload = JSON.stringify({
    pickup: { lat: 10.762622, lng: 106.660172 },
    drop: { lat: 10.780403, lng: 106.700928 },
    vehicleType: 'CAR'
  });

  const headers = {
    'Content-Type': 'application/json',
    'X-Load-Test': 'case98-rate-limit-abuse'
  };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const res = http.post(`${BASE_URL}/v1/bookings`, payload, {
    headers,
    timeout: __ENV.CASE98_TIMEOUT || '3s',
    responseCallback: bookingExpectedStatuses,
    tags: { case: '98', endpoint: 'bookings' }
  });

  const timedOut =
    res.timedOut === true ||
    res.status === 0 ||
    String(res.error || '').toLowerCase().includes('timeout');
  const is429 = res.status === 429;
  const isServerError = res.status >= 500;
  const isExpected = [200, 201, 202, 409, 422, 429].includes(res.status);

  rateLimitHitRate.add(is429);
  timeoutRate.add(timedOut);
  serverErrorRate.add(isServerError);
  unexpectedStatusRate.add(!isExpected);

  check(res, {
    'case98 got 429 or expected status': () => isExpected
  });

  sleep(0.001);
}

export function healthProbe() {
  const res = http.get(`${BASE_URL}/health`, {
    timeout: __ENV.CASE98_TIMEOUT || '3s',
    tags: { case: '98', endpoint: 'health' }
  });
  healthOkRate.add(res.status === 200);
  check(res, { 'case98 gateway health 200': (r) => r.status === 200 });
}
