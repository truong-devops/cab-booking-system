import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { ensureUserToken } from './auto-auth.js';

const BASE_URL = __ENV.BASE_URL || 'http://host.docker.internal:3000';
const USER_TOKEN = __ENV.USER_TOKEN || '';
const SLA_P95_MS = Number(__ENV.CASE68_SLA_P95_MS || 200);
const SLA_P99_MS = Number(__ENV.CASE68_SLA_P99_MS || 300);

const successRate = new Rate('case68_success_rate');
const timeoutRate = new Rate('case68_timeout_rate');
const overP95SlaRate = new Rate('case68_over_p95_sla_rate');
const overP99SlaRate = new Rate('case68_over_p99_sla_rate');

export function setup() {
  const autoToken = ensureUserToken(BASE_URL, 'case68');
  return { autoToken };
}

export const options = {
  scenarios: {
    case68_latency_under_spike: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.CASE68_START_RATE || 150),
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.CASE68_VUS || 150),
      maxVUs: Number(__ENV.CASE68_MAX_VUS || 800),
      stages: [
        { target: Number(__ENV.CASE68_BASELINE_RATE || 200), duration: __ENV.CASE68_BASELINE_DURATION || '5s' },
        { target: Number(__ENV.CASE68_SPIKE_RATE || 1000), duration: __ENV.CASE68_SPIKE_UP_DURATION || '2s' },
        { target: Number(__ENV.CASE68_SPIKE_RATE || 1000), duration: __ENV.CASE68_SPIKE_HOLD_DURATION || '8s' },
        { target: Number(__ENV.CASE68_RECOVERY_RATE || 200), duration: __ENV.CASE68_RECOVERY_DURATION || '5s' }
      ]
    }
  },
  thresholds: {
    case68_success_rate: ['rate>0.99'],
    case68_timeout_rate: ['rate==0'],
    http_req_failed: ['rate<0.01'],
    'http_req_duration{case:68}': [`p(95)<${SLA_P95_MS}`, `p(99)<${SLA_P99_MS}`],
    case68_over_p95_sla_rate: ['rate<0.05'],
    case68_over_p99_sla_rate: ['rate<0.01']
  }
};

export default function (data) {
  const payload = JSON.stringify({
    distance_km: 6,
    traffic_level: 0.7
  });

  const headers = { 'Content-Type': 'application/json' };
  const token = USER_TOKEN || data?.autoToken || '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = http.post(`${BASE_URL}/v1/eta/estimate`, payload, {
    headers,
    timeout: __ENV.CASE68_TIMEOUT || '2s',
    tags: { case: '68', endpoint: 'eta-estimate' }
  });

  const timedOut =
    res.timedOut === true ||
    res.status === 0 ||
    String(res.error || '').toLowerCase().includes('timeout');

  const ok = res.status === 200 && !timedOut;
  successRate.add(ok);
  timeoutRate.add(timedOut);
  overP95SlaRate.add(res.timings.duration > SLA_P95_MS);
  overP99SlaRate.add(res.timings.duration > SLA_P99_MS);

  check(res, {
    'case68 status 200': () => res.status === 200,
    'case68 no timeout': () => !timedOut
  });

  sleep(0.001);
}
