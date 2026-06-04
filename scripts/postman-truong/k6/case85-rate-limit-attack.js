import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const rateLimitHitRate = new Rate('case85_rate_limit_hit_rate');
const timeoutRate = new Rate('case85_timeout_rate');
const serverErrorRate = new Rate('case85_server_error_rate');
const unexpectedStatusRate = new Rate('case85_unexpected_status_rate');
const healthOkRate = new Rate('case85_health_ok_rate');

const bookingExpectedStatuses = http.expectedStatuses(200, 201, 202, 409, 422, 429);

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case85');
  return { autoToken };
}

export const options = {
  scenarios: {
    case85_booking_attack: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE85_RATE || 1200),
      timeUnit: '1s',
      duration: __ENV.CASE85_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE85_VUS || 350),
      maxVUs: Number(__ENV.CASE85_MAX_VUS || 1400),
      exec: 'bookingAttack'
    },
    case85_gateway_health_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE85_HEALTH_RATE || 5),
      timeUnit: '1s',
      duration: __ENV.CASE85_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE85_HEALTH_VUS || 5),
      maxVUs: Number(__ENV.CASE85_HEALTH_MAX_VUS || 20),
      exec: 'healthProbe'
    }
  },
  thresholds: {
    case85_rate_limit_hit_rate: ['rate>0.90'],
    case85_timeout_rate: ['rate<0.005'],
    case85_server_error_rate: ['rate<0.01'],
    case85_unexpected_status_rate: ['rate<0.005'],
    case85_health_ok_rate: ['rate==1'],
    'http_req_duration{case:85,endpoint:bookings}': ['p(95)<400'],
    'http_req_duration{case:85,endpoint:health}': ['p(95)<200']
  }
};

export function bookingAttack(data) {
  const payload = JSON.stringify({
    pickup: { lat: 10.762622, lng: 106.660172 },
    drop: { lat: 10.780403, lng: 106.700928 },
    vehicleType: 'CAR'
  });

  const headers = {
    'Content-Type': 'application/json',
    'X-Load-Test': 'case85-rate-limit-attack'
  };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const res = http.post(`${BASE_URL}/v1/bookings`, payload, {
    headers,
    timeout: __ENV.CASE85_TIMEOUT || '3s',
    responseCallback: bookingExpectedStatuses,
    tags: { case: '85', endpoint: 'bookings' }
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
    'case85 got 429 or expected status': () => isExpected
  });

  sleep(0.001);
}

export function healthProbe() {
  const res = http.get(`${BASE_URL}/health`, {
    timeout: __ENV.CASE85_TIMEOUT || '3s',
    tags: { case: '85', endpoint: 'health' }
  });
  healthOkRate.add(res.status === 200);
  check(res, { 'case85 gateway health 200': (r) => r.status === 200 });
}
