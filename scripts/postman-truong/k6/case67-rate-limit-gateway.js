import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const rateLimitHitRate = new Rate('case67_rate_limit_hit_rate');
const timeoutRate = new Rate('case67_timeout_rate');
const serverErrorRate = new Rate('case67_server_error_rate');
const unexpectedStatusRate = new Rate('case67_unexpected_status_rate');

const expectedStatuses = http.expectedStatuses(200, 201, 202, 429);

export const options = {
  scenarios: {
    case67_gateway_rate_limit: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE67_RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.CASE67_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE67_VUS || 300),
      maxVUs: Number(__ENV.CASE67_MAX_VUS || 1200)
    }
  },
  thresholds: {
    case67_rate_limit_hit_rate: ['rate>0.90'],
    case67_timeout_rate: ['rate==0'],
    case67_server_error_rate: ['rate==0'],
    case67_unexpected_status_rate: ['rate<0.01'],
    'http_req_duration{case:67}': ['p(95)<200']
  }
};

export default function () {
  const payload = JSON.stringify({
    pickup: { lat: 10.762622, lng: 106.660172 },
    drop: { lat: 10.780403, lng: 106.700928 },
    vehicleType: 'CAR'
  });

  const headers = {
    'Content-Type': 'application/json',
    'X-Load-Test': 'security-rate-limit'
  };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;

  const res = http.post(`${BASE_URL}/v1/bookings`, payload, {
    headers,
    timeout: __ENV.CASE67_TIMEOUT || '2s',
    responseCallback: expectedStatuses,
    tags: { case: '67', endpoint: 'bookings' }
  });

  const timedOut =
    res.timedOut === true ||
    res.status === 0 ||
    String(res.error || '').toLowerCase().includes('timeout');
  const is429 = res.status === 429;
  const isServerError = res.status >= 500;
  const isExpected = [200, 201, 202, 429].includes(res.status);

  rateLimitHitRate.add(is429);
  timeoutRate.add(timedOut);
  serverErrorRate.add(isServerError);
  unexpectedStatusRate.add(!isExpected);

  check(res, {
    'case67 got 429 or 2xx': () => isExpected,
    'case67 no timeout': () => !timedOut
  });

  sleep(0.001);
}
