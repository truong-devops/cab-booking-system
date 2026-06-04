import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';
const VERBOSE = (__ENV.CASE35_VERBOSE || 'true').toLowerCase() === 'true';
const VERBOSE_BODY = (__ENV.CASE35_VERBOSE_BODY || 'true').toLowerCase() === 'true';

const pairSuccessRate = new Rate('case35_pair_success_rate');
const serverErrorRate = new Rate('case35_server_error_rate');
const timeoutRate = new Rate('case35_timeout_rate');
const bookingExpectedStatuses = http.expectedStatuses(200, 201, 409);

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case35');
  return { autoToken };
}

export const options = {
  scenarios: {
    case35_parallel_booking: {
      executor: 'shared-iterations',
      vus: Number(__ENV.CASE35_VUS || 1),
      iterations: Number(__ENV.CASE35_ITERATIONS || 1),
      maxDuration: __ENV.CASE35_MAX_DURATION || '10s'
    }
  },
  thresholds: {
    case35_pair_success_rate: ['rate==1'],
    case35_server_error_rate: ['rate<0.01'],
    case35_timeout_rate: ['rate<0.01'],
    http_req_failed: ['rate==0'],
    'http_req_duration{case:35}': ['p(95)<500']
  }
};

export default function (data) {
  const pairStartMs = Date.now();
  const payload = JSON.stringify({
    pickup: { lat: 10.7602, lng: 106.6602 },
    drop: { lat: 10.7711, lng: 106.7011 },
    vehicleType: 'CAR'
  });

  const headers = { 'Content-Type': 'application/json' };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const req = {
    method: 'POST',
    url: `${BASE_URL}/v1/bookings`,
    body: payload,
    params: {
      headers,
      timeout: __ENV.CASE35_TIMEOUT || '3s',
      responseCallback: bookingExpectedStatuses,
      tags: { case: '35', endpoint: 'bookings' }
    }
  };

  // Fire two booking requests at nearly the same time to validate concurrent behavior.
  const [r1, r2] = http.batch([req, req]);
  const pairEndMs = Date.now();

  const isTimeout = (r) =>
    r.timedOut === true ||
    r.status === 0 ||
    String(r.error || '').toLowerCase().includes('timeout');
  const isServerErr = (r) => r.status >= 500;
  const isCreated = (r) => r.status === 201 || r.status === 200;
  const isConflictActiveBooking = (r) => {
    if (r.status !== 409) return false;
    try {
      const body = r.json();
      return body?.code === 'ACTIVE_BOOKING_EXISTS';
    } catch (_e) {
      return false;
    }
  };
  const isExpected = (r) => isCreated(r) || isConflictActiveBooking(r);
  const pairExpectedRaceResult =
    (isCreated(r1) && isConflictActiveBooking(r2)) || (isCreated(r2) && isConflictActiveBooking(r1));

  if (VERBOSE) {
    let c1 = '';
    let c2 = '';
    try {
      c1 = r1.json()?.code || '';
    } catch (_e) {
      c1 = '';
    }
    try {
      c2 = r2.json()?.code || '';
    } catch (_e) {
      c2 = '';
    }
    const req1StartMs = pairStartMs;
    const req2StartMs = pairStartMs;
    const req1EndMs = req1StartMs + Math.round(r1.timings.duration);
    const req2EndMs = req2StartMs + Math.round(r2.timings.duration);
    const req1TotalSec = (r1.timings.duration / 1000).toFixed(6);
    const req2TotalSec = (r2.timings.duration / 1000).toFixed(6);

    console.log(`[case35] REQ1_START_MS=${req1StartMs}`);
    console.log(`[case35] REQ1_END_MS=${req1EndMs}`);
    console.log(`[case35] REQ2_START_MS=${req2StartMs}`);
    console.log(`[case35] REQ2_END_MS=${req2EndMs}`);
    console.log(
      `[case35] pair_window_ms=${pairEndMs - pairStartMs} | req1_status=${r1.status} req2_status=${r2.status} | pair_ok=${pairExpectedRaceResult}`
    );

    if (VERBOSE_BODY) {
      console.log('[case35] === REQ1 ===');
      console.log(r1.body || '');
      console.log(`[case35] HTTP_STATUS:${r1.status}`);
      console.log(`[case35] CURL_TOTAL:${req1TotalSec}`);
      console.log('[case35] === REQ2 ===');
      console.log(r2.body || '');
      console.log(`[case35] HTTP_STATUS:${r2.status}`);
      console.log(`[case35] CURL_TOTAL:${req2TotalSec}`);
    }
  }

  timeoutRate.add(isTimeout(r1) || isTimeout(r2));
  serverErrorRate.add(isServerErr(r1) || isServerErr(r2));
  pairSuccessRate.add(pairExpectedRaceResult && !isTimeout(r1) && !isTimeout(r2));

  check(r1, {
    'case35 req1 status expected (201|409-active-booking)': (res) => isExpected(res),
    'case35 req1 no timeout': (res) => !isTimeout(res)
  });
  check(r2, {
    'case35 req2 status expected (201|409-active-booking)': (res) => isExpected(res),
    'case35 req2 no timeout': (res) => !isTimeout(res)
  });
  check(null, {
    'case35 pair matches race expectation (1 created + 1 conflict)': () => pairExpectedRaceResult
  });

  sleep(0.001);
}
