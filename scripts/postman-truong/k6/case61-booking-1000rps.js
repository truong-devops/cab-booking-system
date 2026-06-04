import http from 'k6/http';
import encoding from 'k6/encoding';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { ensureUserTokens } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || __ENV.BOOKING_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';
const INTERNAL_API_KEY = __ENV.INTERNAL_API_KEY || 'dev-internal-key';

function decodeJwtPayload(token) {
  try {
    const parts = String(token).split('.');
    if (parts.length < 2) return null;
    const raw = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = raw + '='.repeat((4 - (raw.length % 4)) % 4);
    const json = encoding.b64decode(padded, 'std', 's');
    return JSON.parse(json);
  } catch (_e) {
    return null;
  }
}

function isFreshToken(token) {
  if (!token) return false;
  const payload = decodeJwtPayload(token);
  if (!payload || !payload.exp) return true;
  const nowSec = Math.floor(Date.now() / 1000);
  return Number(payload.exp) > nowSec + 60;
}

function parseTokens() {
  if (__ENV.CASE61_TOKENS_FILE) {
    try {
      const raw = open(__ENV.CASE61_TOKENS_FILE);
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed.length > 0) {
        return parsed.map((t) => String(t)).filter((t) => Boolean(t) && isFreshToken(t));
      }
    } catch (_e) {
      // fallback below
    }
  }
  if (__ENV.CASE61_TOKENS_B64) {
    try {
      const json = encoding.b64decode(__ENV.CASE61_TOKENS_B64, 'std', 's');
      const parsed = JSON.parse(json);
      if (Array.isArray(parsed) && parsed.length > 0) {
        return parsed.map((t) => String(t)).filter((t) => Boolean(t) && isFreshToken(t));
      }
    } catch (_e) {
      // fallback below
    }
  }
  if (__ENV.CASE61_TOKENS_JSON) {
    try {
      const parsed = JSON.parse(__ENV.CASE61_TOKENS_JSON);
      if (Array.isArray(parsed) && parsed.length > 0) {
        return parsed.map((t) => String(t)).filter((t) => Boolean(t) && isFreshToken(t));
      }
    } catch (_e) {
      // fallback below
    }
  }
  return USER_TOKEN && isFreshToken(USER_TOKEN) ? [USER_TOKEN] : [];
}

const TOKENS = parseTokens();

const successRate = new Rate('case61_success_rate');
const serverErrorRate = new Rate('case61_server_error_rate');
const debugNon2xx = (__ENV.CASE61_DEBUG_NON2XX || 'false').toLowerCase() === 'true';
const status2xx = new Counter('case61_status_2xx');
const status401 = new Counter('case61_status_401');
const status403 = new Counter('case61_status_403');
const status409 = new Counter('case61_status_409');
const status422 = new Counter('case61_status_422');
const status429 = new Counter('case61_status_429');
const statusOther4xx = new Counter('case61_status_other_4xx');

function parseDurationToSeconds(input) {
  const raw = String(input || '').trim().toLowerCase();
  const m = raw.match(/^(\d+(?:\.\d+)?)(ms|s|m|h)?$/);
  if (!m) return 20;
  const n = Number(m[1]);
  const unit = m[2] || 's';
  if (unit === 'ms') return n / 1000;
  if (unit === 'm') return n * 60;
  if (unit === 'h') return n * 3600;
  return n;
}

export function setup() {
  if (TOKENS.length > 0) {
    console.log(`[case61] using token cache/env: ${TOKENS.length} tokens`);
    return { autoTokens: [] };
  }
  const rate = Number(__ENV.CASE61_RATE || 1000);
  const durationSec = parseDurationToSeconds(__ENV.CASE61_DURATION || '20s');
  const bookingsPerUser = Math.max(1, Number(__ENV.CASE61_BOOKINGS_PER_USER || 1));
  const estimatedRequests = Math.ceil(rate * durationSec);
  const requiredUsers = Math.ceil(estimatedRequests / bookingsPerUser);
  const requestedTokenCount = Number(__ENV.CASE61_TOKEN_COUNT || 0);
  const tokenCount = Math.max(requestedTokenCount || 0, requiredUsers);
  console.log(
    `[case61] generating token pool: required≈${requiredUsers}, requested=${requestedTokenCount || 0}, using=${tokenCount}`
  );
  const autoTokens = ensureUserTokens(BASE_URL, 'case61', tokenCount);
  console.log(`[case61] generated tokens: ${autoTokens.length}`);
  return { autoTokens };
}

export const options = {
  scenarios: {
    case61_booking_rps: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE61_RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.CASE61_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE61_VUS || 300),
      maxVUs: Number(__ENV.CASE61_MAX_VUS || 1200)
    }
  },
  thresholds: {
    case61_server_error_rate: ['rate<0.01'],
    case61_success_rate: ['rate>0.95'],
    http_req_failed: ['rate<0.05'],
    'http_req_duration{case:61}': ['p(95)<450', 'p(99)<900']
  }
};

export default function (data) {
  const payload = JSON.stringify({
    pickup: { lat: 10.762622, lng: 106.660172 },
    drop: { lat: 10.780403, lng: 106.700928 },
    vehicleType: 'CAR'
  });

  const setupTokens = Array.isArray(data?.autoTokens) ? data.autoTokens : [];
  const activeTokens = TOKENS.length > 0 ? TOKENS : setupTokens;
  const token = activeTokens.length > 0 ? activeTokens[(__VU + __ITER) % activeTokens.length] : '';
  const headers = {
    'Content-Type': 'application/json',
    'x-internal-api-key': INTERNAL_API_KEY,
    'X-Load-Test': '1'
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = http.post(`${BASE_URL}/v1/bookings`, payload, {
    headers,
    timeout: __ENV.CASE61_TIMEOUT || '3s',
    tags: { case: '61', endpoint: 'bookings' }
  });

  const timedOut = Boolean(res.error_code);
  const statusOk = res.status >= 200 && res.status < 300;
  const success = statusOk && !timedOut;
  const serverError = res.status >= 500;

  if (res.status >= 200 && res.status < 300) status2xx.add(1);
  else if (res.status === 401) status401.add(1);
  else if (res.status === 403) status403.add(1);
  else if (res.status === 409) status409.add(1);
  else if (res.status === 422) status422.add(1);
  else if (res.status === 429) status429.add(1);
  else if (res.status >= 400 && res.status < 500) statusOther4xx.add(1);

  if (!statusOk && debugNon2xx && __ITER < 3) {
    let code = '';
    let msg = '';
    try {
      const body = res.json();
      code = body?.code || '';
      msg = body?.error || body?.message || '';
    } catch (_e) {
      code = '';
      msg = '';
    }
    console.log(`[case61] non-2xx status=${res.status} code=${code || '-'} msg=${msg || '-'}`);
  }

  successRate.add(success);
  serverErrorRate.add(serverError);

  check(res, {
    'case61 status success': () => statusOk,
    'case61 no timeout': () => !timedOut
  });

  sleep(0.001);
}
