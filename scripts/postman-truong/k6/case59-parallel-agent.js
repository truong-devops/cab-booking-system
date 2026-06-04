import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const AI_URL = __ENV.AI_URL || 'http://host.docker.internal:3013';
const USER_TOKEN = __ENV.USER_TOKEN || '';

const successRate = new Rate('case59_success_rate');
const timeoutRate = new Rate('case59_timeout_rate');

export const options = {
  scenarios: {
    case59_parallel_agent: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.CASE59_RATE || 1000),
      timeUnit: '1s',
      duration: __ENV.CASE59_DURATION || '20s',
      preAllocatedVUs: Number(__ENV.CASE59_PRE_VUS || 300),
      maxVUs: Number(__ENV.CASE59_MAX_VUS || 1000)
    }
  },
  thresholds: {
    checks: ['rate>0.99'],
    case59_success_rate: ['rate>0.95'],
    case59_timeout_rate: ['rate==0'],
    http_req_failed: ['rate<0.01']
  }
};

export default function () {
  const payload = JSON.stringify({
    pickup: { lat: 10.76, lng: 106.66 },
    drop: { lat: 10.77, lng: 106.7 },
    vehicle_type: 'CAR',
    context: {
      objective: 'balanced_eta_price',
      max_eta_min: 15,
      budget_weight: 0.7,
      latency_budget_ms: 200
    },
    candidates: [
      { driver_id: 'd54_1', distance_m: 220, rating: 4.5, online: true },
      { driver_id: 'd54_2', distance_m: 420, rating: 4.9, online: true }
    ]
  });

  const headers = { 'Content-Type': 'application/json' };
  if (USER_TOKEN) headers.Authorization = `Bearer ${USER_TOKEN}`;

  const res = http.post(`${AI_URL}/v1/ai/agent/select-driver`, payload, {
    headers,
    timeout: __ENV.CASE59_TIMEOUT || '2s',
    tags: { case: '59', endpoint: 'agent-select-driver' }
  });

  const timedOut = Boolean(res.error_code);
  timeoutRate.add(timedOut);

  let hasSelectedDriver = false;
  if (!timedOut && res.status === 200) {
    try {
      const body = res.json();
      hasSelectedDriver = Boolean(
        body?.data?.selected_driver?.driver_id || body?.data?.selected_driver?.driverId
      );
    } catch (_e) {
      hasSelectedDriver = false;
    }
  }

  const success = res.status === 200 && !timedOut && hasSelectedDriver;
  successRate.add(success);

  check(res, {
    'case59 status 200': (r) => r.status === 200,
    'case59 no timeout': () => !timedOut,
    'case59 selected driver exists': () => hasSelectedDriver
  });

  sleep(0.001);
}
