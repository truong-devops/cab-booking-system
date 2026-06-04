import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';

export const options = {
  scenarios: {
    case61_booking_rps: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE61_RATE || 600),
      timeUnit: '1s',
      duration: __ENV.CASE61_DURATION || '60s',
      preAllocatedVUs: Number(__ENV.CASE61_VUS || 200),
      maxVUs: Number(__ENV.CASE61_MAX_VUS || 600),
      exec: 'bookingFlow'
    },
    case62_eta_rps: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE62_RATE || 300),
      timeUnit: '1s',
      duration: __ENV.CASE62_DURATION || '45s',
      preAllocatedVUs: Number(__ENV.CASE62_VUS || 100),
      maxVUs: Number(__ENV.CASE62_MAX_VUS || 400),
      startTime: '5s',
      exec: 'etaFlow'
    },
    case63_pricing_spike: {
      executor: 'ramping-arrival-rate',
      startRate: 50,
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.CASE63_VUS || 120),
      maxVUs: Number(__ENV.CASE63_MAX_VUS || 500),
      stages: [
        { target: Number(__ENV.CASE63_SPIKE_RATE || 500), duration: '15s' },
        { target: Number(__ENV.CASE63_SPIKE_RATE || 500), duration: '30s' },
        { target: 0, duration: '10s' }
      ],
      exec: 'pricingFlow'
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<450']
  }
};

function authHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;
  return headers;
}

export function bookingFlow() {
  const payload = JSON.stringify({
    pickup: { lat: 10.76, lng: 106.66 },
    drop: { lat: 10.77, lng: 106.7 },
    vehicleType: 'CAR'
  });
  const res = http.post(`${BASE_URL}/v1/bookings`, payload, { headers: authHeaders() });
  check(res, { 'case61 status ok': (r) => [200, 201, 409, 422].includes(r.status) });
}

export function etaFlow() {
  const payload = JSON.stringify({ distance_km: 5, traffic_level: 0.5 });
  const res = http.post(`${BASE_URL}/v1/eta/estimate`, payload, { headers: authHeaders() });
  check(res, { 'case62 status ok': (r) => [200, 401, 403].includes(r.status) });
}

export function pricingFlow() {
  const payload = JSON.stringify({ distance_km: 5, demand_index: 2, supply_index: 1 });
  const res = http.post(`${BASE_URL}/v1/pricing/estimate`, payload, { headers: authHeaders() });
  check(res, { 'case63 status ok': (r) => [200, 401, 403].includes(r.status) });
}
