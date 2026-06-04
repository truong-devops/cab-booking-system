import http from 'k6/http';
import { check, sleep } from 'k6';

const AI_URL = __ENV.AI_URL || 'http://host.docker.internal:3013';
const USER_TOKEN = __ENV.USER_TOKEN || '';

export const options = {
  scenarios: {
    case47_realtime_latency: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE47_RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.CASE47_DURATION || '30s',
      preAllocatedVUs: Number(__ENV.CASE47_PRE_VUS || 200),
      maxVUs: Number(__ENV.CASE47_MAX_VUS || 1200)
    }
  },
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
    'http_req_duration{case:47}': ['p(95)<200']
  }
};

export default function () {
  const payload = JSON.stringify({
    zone_id: 'hcm-q1',
    horizon_min: 15,
    timestamp: new Date().toISOString()
  });

  const headers = { 'Content-Type': 'application/json' };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;

  const res = http.post(`${AI_URL}/v1/ai/forecast-demand`, payload, {
    headers,
    timeout: __ENV.CASE47_TIMEOUT || '2s',
    tags: { case: '47', endpoint: 'forecast-demand' }
  });

  check(res, {
    'case47 status 200': (r) => r.status === 200,
    'case47 no timeout': (r) => !r.error_code
  });

  sleep(0.001);
}
