import http from 'k6/http';
import { check } from 'k6';

const BOOKING_URL = __ENV.BOOKING_URL || 'http://host.docker.internal:3003';
const PRICING_URL = __ENV.PRICING_URL || 'http://host.docker.internal:3006';
const INTERNAL_API_KEY = __ENV.INTERNAL_API_KEY || 'dev-internal-key';
const USER_TOKEN = __ENV.USER_TOKEN || '';

function authHeaders(extra = {}) {
  const headers = { ...extra };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;
  return headers;
}

export const options = {
  scenarios: {
    case64_kafka_publish: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE64_RATE || 300),
      timeUnit: '1s',
      duration: __ENV.CASE64_DURATION || '45s',
      preAllocatedVUs: Number(__ENV.CASE64_VUS || 80),
      maxVUs: Number(__ENV.CASE64_MAX_VUS || 300),
      exec: 'publishDemoRide'
    },
    case65_db_pool_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE65_RATE || 250),
      timeUnit: '1s',
      duration: __ENV.CASE65_DURATION || '45s',
      preAllocatedVUs: Number(__ENV.CASE65_VUS || 80),
      maxVUs: Number(__ENV.CASE65_MAX_VUS || 300),
      exec: 'bookingListProbe',
      startTime: '5s'
    },
    case66_quote_reuse: {
      executor: 'constant-vus',
      vus: Number(__ENV.CASE66_VUS || 30),
      duration: __ENV.CASE66_DURATION || '40s',
      exec: 'quoteFlow',
      startTime: '10s'
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.05']
  }
};

export function publishDemoRide() {
  const payload = JSON.stringify({
    ride_id: `ride-k6-${__VU}-${__ITER}`,
    user_id: '12345678',
    status: 'REQUESTED'
  });
  const res = http.post(`${BOOKING_URL}/demo/ride-created`, payload, {
    headers: {
      'Content-Type': 'application/json',
      'x-internal-key': INTERNAL_API_KEY
    }
  });
  check(res, { 'case64 demo publish status': (r) => [200, 201].includes(r.status) });
}

export function bookingListProbe() {
  const res = http.get(`${BOOKING_URL}/v1/bookings?limit=20`, { headers: authHeaders() });
  check(res, { 'case65 no hard fail': (r) => ![500, 502, 503, 504].includes(r.status) });
}

export function quoteFlow() {
  const createRes = http.post(
    `${PRICING_URL}/v1/pricing/quotes`,
    JSON.stringify({
      pickup: { lat: 10.76, lng: 106.66 },
      dropoff: { lat: 10.77, lng: 106.7 },
      serviceType: 'STANDARD'
    }),
    {
      headers: authHeaders({ 'Content-Type': 'application/json' })
    }
  );

  check(createRes, { 'quote create ok': (r) => [200, 201].includes(r.status) });

  let quoteId = '';
  try {
    quoteId = createRes.json('data.quoteId') || createRes.json('quoteId') || '';
  } catch (_) {
    quoteId = '';
  }

  if (quoteId) {
    const readRes = http.get(`${PRICING_URL}/v1/pricing/quotes/${quoteId}`, { headers: authHeaders() });
    check(readRes, { 'quote read ok': (r) => [200].includes(r.status) });
  }
}
