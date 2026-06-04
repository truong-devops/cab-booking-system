import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

export const options = {
  scenarios: {
    case68_latency: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE68_RATE || 250),
      timeUnit: '1s',
      duration: __ENV.CASE68_DURATION || '60s',
      preAllocatedVUs: Number(__ENV.CASE68_VUS || 100),
      maxVUs: Number(__ENV.CASE68_MAX_VUS || 400),
      exec: 'etaFlow'
    },
    case69_peak_ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 80,
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.CASE69_VUS || 120),
      maxVUs: Number(__ENV.CASE69_MAX_VUS || 700),
      stages: [
        { target: Number(__ENV.CASE69_STAGE1 || 250), duration: '20s' },
        { target: Number(__ENV.CASE69_STAGE2 || 500), duration: '20s' },
        { target: Number(__ENV.CASE69_STAGE3 || 900), duration: '20s' },
        { target: 0, duration: '15s' }
      ],
      startTime: '5s',
      exec: 'bookingFlow'
    },
    case70_scale_trigger: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE70_RATE || 700),
      timeUnit: '1s',
      duration: __ENV.CASE70_DURATION || '90s',
      preAllocatedVUs: Number(__ENV.CASE70_VUS || 200),
      maxVUs: Number(__ENV.CASE70_MAX_VUS || 900),
      startTime: '10s',
      exec: 'bookingFlow'
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<500']
  }
};

function authHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;
  return headers;
}

export function bookingFlow() {
  const payload = JSON.stringify({
    pickup: { lat: 10.761, lng: 106.661 },
    drop: { lat: 10.771, lng: 106.701 },
    vehicleType: 'CAR',
    simulate_pricing_timeout: __ENV.SIMULATE_TIMEOUT === '1'
  });
  const res = http.post(`${BASE_URL}/v1/bookings`, payload, { headers: authHeaders() });
  check(res, { 'booking status accepted': (r) => [200, 201, 409, 422].includes(r.status) });
}

export function etaFlow() {
  const payload = JSON.stringify({ distance_km: 6, traffic_level: 0.7 });
  const res = http.post(`${BASE_URL}/v1/eta/estimate`, payload, { headers: authHeaders() });
  check(res, { 'eta status accepted': (r) => [200, 401, 403].includes(r.status) });
}
