#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
BOOKING_URL="${BOOKING_URL:-http://localhost:42104}"
ETA_URL="${ETA_URL:-http://localhost:42111}"
PRICING_URL="${PRICING_URL:-http://localhost:42106}"
INTERNAL_API_KEY="${INTERNAL_API_KEY:-dev-internal-key}"
USER_PASS="${USER_PASS:-123456}"
UNIQ_TAG="$(date +%s)-$RANDOM"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Strict thresholds (override by env when needed for weaker environments)
CASE61_TARGET_RPS="${CASE61_TARGET_RPS:-1000}"
CASE61_DURATION_SEC="${CASE61_DURATION_SEC:-20}"
CASE61_CONCURRENCY="${CASE61_CONCURRENCY:-300}"
CASE61_MIN_SUCCESS_RATE="${CASE61_MIN_SUCCESS_RATE:-0.95}"
CASE61_MIN_RPS_RATIO="${CASE61_MIN_RPS_RATIO:-1.0}"
CASE61_P95_LIMIT_MS="${CASE61_P95_LIMIT_MS:-450}"
CASE61_WARMUP_SEC="${CASE61_WARMUP_SEC:-5}"

CASE62_TARGET_RPS="${CASE62_TARGET_RPS:-500}"
CASE62_DURATION_SEC="${CASE62_DURATION_SEC:-20}"
CASE62_CONCURRENCY="${CASE62_CONCURRENCY:-140}"
CASE62_P95_LIMIT_MS="${CASE62_P95_LIMIT_MS:-200}"
CASE62_MIN_SUCCESS_RATE="${CASE62_MIN_SUCCESS_RATE:-0.995}"
CASE62_MIN_RPS_RATIO="${CASE62_MIN_RPS_RATIO:-1.0}"

CASE63_TARGET_RPS="${CASE63_TARGET_RPS:-800}"
CASE63_DURATION_SEC="${CASE63_DURATION_SEC:-20}"
CASE63_CONCURRENCY="${CASE63_CONCURRENCY:-200}"
CASE63_P95_LIMIT_MS="${CASE63_P95_LIMIT_MS:-300}"
CASE63_MIN_SUCCESS_RATE="${CASE63_MIN_SUCCESS_RATE:-0.995}"
CASE63_MIN_RPS_RATIO="${CASE63_MIN_RPS_RATIO:-1.0}"
CASE63_MAX_5XX_RATE="${CASE63_MAX_5XX_RATE:-0.01}"

CASE64_TARGET_RPS="${CASE64_TARGET_RPS:-500}"
CASE64_DURATION_SEC="${CASE64_DURATION_SEC:-20}"
CASE64_CONCURRENCY="${CASE64_CONCURRENCY:-180}"
CASE64_MIN_SUCCESS_RATE="${CASE64_MIN_SUCCESS_RATE:-0.99}"
CASE64_MIN_RPS_RATIO="${CASE64_MIN_RPS_RATIO:-1.0}"
CASE64_COOLDOWN_SEC="${CASE64_COOLDOWN_SEC:-8}"
CASE64_KAFKA_TOPIC="${CASE64_KAFKA_TOPIC:-ride.created}"
CASE64_CONSUMER_GROUPS="${CASE64_CONSUMER_GROUPS:-payment-service-group}"
CASE64_TOPIC_DELTA_MIN_RATIO="${CASE64_TOPIC_DELTA_MIN_RATIO:-1.0}"
CASE64_MAX_CONSUMER_LAG="${CASE64_MAX_CONSUMER_LAG:-200}"
CASE64_LAG_SETTLE_SEC="${CASE64_LAG_SETTLE_SEC:-4}"
CASE64_LAG_WAIT_TIMEOUT_SEC="${CASE64_LAG_WAIT_TIMEOUT_SEC:-45}"
CASE64_LAG_POLL_INTERVAL_SEC="${CASE64_LAG_POLL_INTERVAL_SEC:-2}"
CASE64_WAIT_FOR_ACTIVE_GROUP_SEC="${CASE64_WAIT_FOR_ACTIVE_GROUP_SEC:-30}"
CASE64_TOPIC_WAIT_TIMEOUT_SEC="${CASE64_TOPIC_WAIT_TIMEOUT_SEC:-45}"
CASE64_TOPIC_POLL_INTERVAL_SEC="${CASE64_TOPIC_POLL_INTERVAL_SEC:-2}"
CASE64_AUTO_START_KAFKA="${CASE64_AUTO_START_KAFKA:-1}"
CASE64_KAFKA_COMPOSE_FILE="${CASE64_KAFKA_COMPOSE_FILE:-$SCRIPT_DIR/../infra/docker-compose.dev.yml}"

CASE65_TARGET_RPS="${CASE65_TARGET_RPS:-900}"
CASE65_DURATION_SEC="${CASE65_DURATION_SEC:-15}"
CASE65_CONCURRENCY="${CASE65_CONCURRENCY:-260}"
CASE65_MAX_5XX_RATE="${CASE65_MAX_5XX_RATE:-0.01}"
CASE65_MIN_RPS_RATIO="${CASE65_MIN_RPS_RATIO:-1.0}"
CASE65_PRECHECK_GROUP_LAG_WAIT_SEC="${CASE65_PRECHECK_GROUP_LAG_WAIT_SEC:-20}"

CASE66_QUOTE_READS="${CASE66_QUOTE_READS:-300}"
CASE66_MIN_HIT_RATE="${CASE66_MIN_HIT_RATE:-0.9}"
CASE66_LATENCY_GAIN_RATIO="${CASE66_LATENCY_GAIN_RATIO:-1.2}"
CASE66_LOAD_CONCURRENCY="${CASE66_LOAD_CONCURRENCY:-8}"
CASE66_LOAD_TARGET_RPS="${CASE66_LOAD_TARGET_RPS:-120}"
CASE66_LOAD_TIMEOUT_MS="${CASE66_LOAD_TIMEOUT_MS:-8000}"

CASE67_BURST_COUNT="${CASE67_BURST_COUNT:-140}"
CASE67_CONCURRENCY="${CASE67_CONCURRENCY:-70}"
CASE67_MIN_429="${CASE67_MIN_429:-5}"

CASE68_TARGET_RPS="${CASE68_TARGET_RPS:-350}"
CASE68_DURATION_SEC="${CASE68_DURATION_SEC:-20}"
CASE68_CONCURRENCY="${CASE68_CONCURRENCY:-120}"
CASE68_P95_LIMIT_MS="${CASE68_P95_LIMIT_MS:-200}"
CASE68_MIN_SUCCESS_RATE="${CASE68_MIN_SUCCESS_RATE:-0.99}"
CASE68_MIN_RPS_RATIO="${CASE68_MIN_RPS_RATIO:-1.0}"
CASE68_P95_TOLERANCE_RATIO="${CASE68_P95_TOLERANCE_RATIO:-1.0}"

CASE69_PEAK_TARGET_RPS="${CASE69_PEAK_TARGET_RPS:-1200}"
CASE69_PEAK_DURATION_SEC="${CASE69_PEAK_DURATION_SEC:-20}"
CASE69_PEAK_CONCURRENCY="${CASE69_PEAK_CONCURRENCY:-320}"
CASE69_PEAK_MIN_SUCCESS_RATE="${CASE69_PEAK_MIN_SUCCESS_RATE:-0.97}"
CASE69_PEAK_P95_LIMIT_MS="${CASE69_PEAK_P95_LIMIT_MS:-450}"
CASE69_PEAK_MIN_RPS_RATIO="${CASE69_PEAK_MIN_RPS_RATIO:-1.0}"
CASE69_PEAK_P95_TOLERANCE_RATIO="${CASE69_PEAK_P95_TOLERANCE_RATIO:-1.0}"
CASE69_PREP_COOLDOWN_SEC="${CASE69_PREP_COOLDOWN_SEC:-10}"
CASE69_STAGE_DURATION_SEC="${CASE69_STAGE_DURATION_SEC:-8}"
CASE69_STAGE1_RPS="${CASE69_STAGE1_RPS:-350}"
CASE69_STAGE2_RPS="${CASE69_STAGE2_RPS:-700}"
CASE69_STAGE3_RPS="${CASE69_STAGE3_RPS:-$CASE69_PEAK_TARGET_RPS}"
CASE69_MAX_P95_DEGRADE_RATIO="${CASE69_MAX_P95_DEGRADE_RATIO:-2.5}"

K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
K8S_HPA_NAME="${K8S_HPA_NAME:-}"
CASE70_AUTOSCALE_TARGET_URL="${CASE70_AUTOSCALE_TARGET_URL:-}"
SWARM_SERVICE_NAME="${SWARM_SERVICE_NAME:-}"
CASE70_DURATION_SEC="${CASE70_DURATION_SEC:-120}"
CASE70_CONCURRENCY="${CASE70_CONCURRENCY:-220}"
CASE70_TARGET_RPS="${CASE70_TARGET_RPS:-900}"
CASE70_SCALE_OBSERVE_SEC="${CASE70_SCALE_OBSERVE_SEC:-150}"
CASE70_MIN_SUCCESS_RATE="${CASE70_MIN_SUCCESS_RATE:-0.95}"
CASE70_MAX_P95_MS="${CASE70_MAX_P95_MS:-900}"
CASE70_MAX_5XX_RATE="${CASE70_MAX_5XX_RATE:-0.02}"
CASE70_LOCAL_DEV_EXEMPT_PASS="${CASE70_LOCAL_DEV_EXEMPT_PASS:-1}"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-25}"
LOAD_RPS_COMPENSATION_RATIO="${LOAD_RPS_COMPENSATION_RATIO:-1.02}"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

print_usage() {
  cat <<USAGE
Usage:
  ./scripts/test-level7-61-70cases.sh [BASE_URL]

Examples:
  ./scripts/test-level7-61-70cases.sh
  CASE61_TARGET_RPS=700 ./scripts/test-level7-61-70cases.sh http://localhost:42100

Notes:
  - Cases 61-69 run in Docker/local environments.
  - Case 70 (auto-scaling) requires Kubernetes HPA or Docker Swarm service scaling evidence.
  - Set CASE70_LOCAL_DEV_EXEMPT_PASS=1 to auto-pass Case 70 on local non-orchestrated setups.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

wait_for_url() {
  local url="$1"
  local max_wait="${2:-60}"
  local i=0
  while [[ "$i" -lt "$max_wait" ]]; do
    if curl -s "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

json_get() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;if(/^\\d+$/.test(k)){v=Array.isArray(v)?v[Number(k)]:v?.[k]}else{v=v?.[k]}}process.stdout.write(v==null?'':String(v))}catch(e){process.stdout.write('')}})"
}

print_case() {
  local title="$1"
  local input="$2"
  local expected="$3"
  local status="$4"
  local body="$5"
  local case_id=""
  local case_context=""
  local case_input=""
  case_id="$(echo "$title" | sed -n 's/^Case \([0-9]\+\).*/\1/p')"
  if [[ -n "$case_id" ]]; then
    case_context="$(get_case_context "$case_id")"
    case_input="$(get_case_input "$case_id")"
  fi
  echo "========== $title =========="
  if [[ -n "$case_context" ]]; then
    echo "Context: $case_context"
  fi
  if [[ -n "$case_input" ]]; then
    echo "Input (PDF): $case_input"
  fi
  echo "Input:"
  echo "$input" | sed -n '1,120p'
  echo "Expected: $expected"
  echo "Actual status: $status"
  echo "Actual body:"
  echo "$body" | sed -n '1,140p'
  echo
}

mark_result() {
  local ok="$1"
  local case_id="$2"
  if [[ "$ok" == "1" ]]; then
    echo "[$case_id] PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "[$case_id] FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo
}

json_status_count() {
  local body="$1"
  local code="$2"
  node -e "try{const j=JSON.parse(process.argv[1]);const c=j?.status_counts?.[String(process.argv[2])];process.stdout.write(String(Number.isFinite(Number(c))?Number(c):0));}catch(e){process.stdout.write('0');}" "$body" "$code"
}

status_sum_range() {
  local body="$1"
  local min_code="$2"
  local max_code="$3"
  local exclude_codes="${4:-}"
  node -e "try{const j=JSON.parse(process.argv[1]);const min=Number(process.argv[2]);const max=Number(process.argv[3]);const ex=new Set(String(process.argv[4]||'').split(',').map(s=>s.trim()).filter(Boolean));let sum=0;for(const [k,v] of Object.entries(j?.status_counts||{})){const code=Number(k);if(!Number.isFinite(code)||code<min||code>max||ex.has(String(k)))continue;const n=Number(v);if(Number.isFinite(n))sum+=n;}process.stdout.write(String(sum));}catch(e){process.stdout.write('0');}" "$body" "$min_code" "$max_code" "$exclude_codes"
}

mark_load_result() {
  local case_id="$1"
  local pass_flag="$2"

  if [[ "$pass_flag" == "1" ]]; then
    mark_result 1 "$case_id"
  else
    mark_result 0 "$case_id"
  fi
}

call_json_url() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"
  local header_key="${4:-}"
  local header_value="${5:-}"

  local -a args
  args=(
    -s -X "$method" "$url"
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
  )

  if [[ -n "$header_key" ]]; then
    args+=( -H "$header_key: $header_value" )
  fi
  if [[ "$method" != "GET" && "$method" != "HEAD" ]]; then
    args+=( -H "Content-Type: application/json" -d "$payload" )
  fi

  local resp
  if ! resp=$(curl "${args[@]}" -w "\nHTTP_STATUS:%{http_code}"); then
    resp='{"error":"transport error"}'
    resp="$resp"$'\nHTTP_STATUS:000'
  fi

  local status="${resp##*HTTP_STATUS:}"
  local body="${resp%HTTP_STATUS:*}"
  printf '%s\n' "$status"
  printf '%s' "$body"
}

register_and_login_user() {
  local email="$1"
  local name="$2"
  local role="${3:-user}"

  call_json_url POST "$BASE_URL/v1/auth/register" "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"$role\"}" >/dev/null || true

  local attempt=1
  while [[ "$attempt" -le 6 ]]; do
    local login
    login=$(call_json_url POST "$BASE_URL/v1/auth/login" "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
    local status
    local body
    status=$(echo "$login" | sed -n '1p')
    body=$(echo "$login" | sed '1d')

    if [[ "$status" != "200" ]]; then
      login=$(call_json_url POST "$BASE_URL/v1/auth/login" "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
      status=$(echo "$login" | sed -n '1p')
      body=$(echo "$login" | sed '1d')
    fi

    local token
    token=$(echo "$body" | json_get "tokens.accessToken")
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi

    if [[ "$status" != "429" ]]; then
      break
    fi
    sleep "$attempt"
    attempt=$((attempt + 1))
  done

  echo ""
}

run_load_scenario() {
  local url_template="$1"
  local method="$2"
  local duration_sec="$3"
  local concurrency="$4"
  local target_rps="$5"
  local headers_json="$6"
  local body_template="$7"
  local body_mode="${8:-static}"
  local timeout_ms="${9:-12000}"
  local total_requests="${10:-0}"

  LOAD_URL_TEMPLATE="$url_template" \
  LOAD_METHOD="$method" \
  LOAD_DURATION_SEC="$duration_sec" \
  LOAD_CONCURRENCY="$concurrency" \
  LOAD_TARGET_RPS="$target_rps" \
  LOAD_HEADERS_JSON="$headers_json" \
  LOAD_BODY_TEMPLATE="$body_template" \
  LOAD_BODY_MODE="$body_mode" \
  LOAD_TIMEOUT_MS="$timeout_ms" \
  LOAD_TOTAL_REQUESTS="$total_requests" \
  LOAD_RPS_COMPENSATION_RATIO="$LOAD_RPS_COMPENSATION_RATIO" \
  node - <<'NODE'
const { performance } = require('node:perf_hooks');

const urlTemplate = process.env.LOAD_URL_TEMPLATE || '';
const method = String(process.env.LOAD_METHOD || 'GET').toUpperCase();
const durationSec = Math.max(1, Number(process.env.LOAD_DURATION_SEC || 1));
const concurrency = Math.max(1, Number(process.env.LOAD_CONCURRENCY || 1));
const targetRpsInput = Math.max(0, Number(process.env.LOAD_TARGET_RPS || 0));
const rpsCompensationRatio = Math.max(1, Number(process.env.LOAD_RPS_COMPENSATION_RATIO || 1));
const targetRps = targetRpsInput > 0 ? targetRpsInput * rpsCompensationRatio : 0;
const bodyTemplate = process.env.LOAD_BODY_TEMPLATE || '';
const bodyMode = process.env.LOAD_BODY_MODE || 'static';
const timeoutMs = Math.max(200, Number(process.env.LOAD_TIMEOUT_MS || 12000));
const totalRequests = Math.max(0, Number(process.env.LOAD_TOTAL_REQUESTS || 0));

try {
  const { setGlobalDispatcher, Agent } = require('undici');
  const maxConnections = Math.max(64, Math.min(2048, concurrency * 4));
  setGlobalDispatcher(
    new Agent({
      connections: maxConnections,
      pipelining: 1,
      keepAliveTimeout: 30_000,
      keepAliveMaxTimeout: 60_000
    })
  );
} catch (_e) {
  // Continue with default fetch dispatcher when undici is unavailable.
}

let headersTemplate = {};
try {
  headersTemplate = JSON.parse(process.env.LOAD_HEADERS_JSON || '{}') || {};
} catch (_e) {
  headersTemplate = {};
}

const startedAt = Date.now();
const stopAt = startedAt + durationSec * 1000;
const perWorkerIntervalMs = targetRps > 0 ? (1000 * concurrency) / targetRps : 0;

let dispatched = 0;
let completed = 0;
let success = 0;
let failed = 0;
const statusCounts = {};
const latencies = [];
const errorSamples = [];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withSeq(raw, seq) {
  return String(raw)
    .replace(/__SEQ__/g, String(seq))
    .replace(/__DEMAND__/g, String((seq % 8 === 0) ? 5 : (seq % 3 === 0 ? 2.5 : 1.1)));
}

function buildRequest(seq) {
  const url = withSeq(urlTemplate, seq);
  const headers = {};
  for (const [k, v] of Object.entries(headersTemplate)) {
    headers[k] = withSeq(v, seq);
  }

  let body = null;
  if (!['GET', 'HEAD'].includes(method)) {
    if (bodyMode === 'pricing_spike') {
      const demand = (seq % 10 < 2) ? 5 : (seq % 4 === 0 ? 2.5 : 1.2);
      body = JSON.stringify({ distance_km: 4.8 + (seq % 3) * 0.2, demand_index: demand });
    } else if (bodyMode === 'booking_load') {
      body = JSON.stringify({
        pickup: { lat: 10.7601 + (seq % 20) * 0.00001, lng: 106.6601 + (seq % 20) * 0.00001 },
        drop: { lat: 10.7701 + (seq % 20) * 0.00001, lng: 106.7001 + (seq % 20) * 0.00001 },
        vehicleType: 'CAR'
      });
    } else {
      body = withSeq(bodyTemplate || '{}', seq);
    }
  }

  return { url, headers, body };
}

function percentile(sorted, p) {
  if (!sorted.length) return NaN;
  const idx = Math.max(0, Math.ceil(sorted.length * p) - 1);
  return sorted[idx];
}

async function doRequest(seq) {
  const { url, headers, body } = buildRequest(seq);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  const t0 = performance.now();
  try {
    const response = await fetch(url, {
      method,
      headers,
      body,
      signal: controller.signal
    });
    const latency = performance.now() - t0;
    latencies.push(latency);
    completed += 1;

    const code = response.status;
    statusCounts[code] = (statusCounts[code] || 0) + 1;
    if (code >= 200 && code < 300) {
      success += 1;
    } else {
      failed += 1;
      if (errorSamples.length < 6) {
        let snippet = '';
        try {
          snippet = (await response.text()).slice(0, 180);
        } catch (_e) {
          snippet = '';
        }
        errorSamples.push({ code, body: snippet });
      }
    }
  } catch (e) {
    const latency = performance.now() - t0;
    latencies.push(latency);
    completed += 1;
    failed += 1;
    statusCounts['000'] = (statusCounts['000'] || 0) + 1;
    if (errorSamples.length < 6) {
      errorSamples.push({ code: '000', body: String(e && e.message ? e.message : 'transport error').slice(0, 180) });
    }
  } finally {
    clearTimeout(timer);
  }
}

async function worker(workerIndex) {
  let nextDue = performance.now();
  if (perWorkerIntervalMs > 0) {
    nextDue += (workerIndex * perWorkerIntervalMs) / Math.max(1, concurrency);
  }
  while (true) {
    if (perWorkerIntervalMs > 0) {
      const nowMono = performance.now();
      if (nowMono < nextDue) {
        let waitMs = nextDue - nowMono;
        if (totalRequests <= 0) {
          const remainingMs = stopAt - Date.now();
          if (remainingMs <= 0) {
            break;
          }
          if (waitMs > remainingMs) {
            waitMs = remainingMs;
          }
        }
        await sleep(waitMs);
      }
    }

    const nowWall = Date.now();
    if (totalRequests > 0) {
      if (dispatched >= totalRequests) break;
    } else if (nowWall >= stopAt) {
      break;
    }

    const seq = dispatched;
    dispatched += 1;

    await doRequest(seq);

    if (perWorkerIntervalMs > 0) {
      nextDue += perWorkerIntervalMs;
      const lag = performance.now() - nextDue;
      if (lag > perWorkerIntervalMs * 3) {
        nextDue = performance.now();
      }
    }
  }
}

(async () => {
  const workers = [];
  for (let i = 0; i < concurrency; i += 1) {
    workers.push(worker(i));
  }
  await Promise.all(workers);

  const elapsedSec = Math.max(0.001, (Date.now() - startedAt) / 1000);
  const sorted = latencies.slice().sort((a, b) => a - b);
  const p50 = percentile(sorted, 0.50);
  const p95 = percentile(sorted, 0.95);
  const p99 = percentile(sorted, 0.99);

  const rps = completed / elapsedSec;
  const successRate = completed > 0 ? success / completed : 0;

  process.stdout.write(JSON.stringify({
    elapsed_sec: Number(elapsedSec.toFixed(3)),
    sent: dispatched,
    completed,
    success,
    failed,
    success_rate: Number(successRate.toFixed(6)),
    achieved_rps: Number(rps.toFixed(3)),
    p50_ms: Number((Number.isFinite(p50) ? p50 : NaN).toFixed(3)),
    p95_ms: Number((Number.isFinite(p95) ? p95 : NaN).toFixed(3)),
    p99_ms: Number((Number.isFinite(p99) ? p99 : NaN).toFixed(3)),
    status_counts: statusCounts,
    error_samples: errorSamples
  }));
})();
NODE
}

redis_info_stats() {
  # returns: "hits misses" or empty on failure
  extract_stat() {
    local input="$1"
    local key="$2"
    echo "$input" | awk -F: -v k="$key" '$1 == k { print $2; exit }' | tr -d '\r'
  }

  if command -v redis-cli >/dev/null 2>&1; then
    local out
    out=$(redis-cli -h localhost -p 42131 INFO stats 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      local h m
      h=$(extract_stat "$out" "keyspace_hits")
      m=$(extract_stat "$out" "keyspace_misses")
      if [[ -n "$h" && -n "$m" ]]; then
        echo "$h $m"
        return 0
      fi
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    local redis_container
    redis_container=$(docker ps --format '{{.Names}}' | grep -E 'redis' | head -n1 || true)
    if [[ -n "$redis_container" ]]; then
      local out
      out=$(docker exec "$redis_container" redis-cli INFO stats 2>/dev/null || true)
      local h m
      h=$(extract_stat "$out" "keyspace_hits")
      m=$(extract_stat "$out" "keyspace_misses")
      if [[ -n "$h" && -n "$m" ]]; then
        echo "$h $m"
        return 0
      fi
    fi
  fi

  echo ""
  return 1
}

detect_kafka_container() {
  if ! command -v docker >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'kafka' | head -n1 || true
}

ensure_kafka_container() {
  local kafka_container
  kafka_container="$(detect_kafka_container || true)"
  if [[ -n "$kafka_container" ]]; then
    echo "$kafka_container"
    return 0
  fi

  if [[ "$CASE64_AUTO_START_KAFKA" != "1" ]]; then
    echo ""
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo ""
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo ""
    return 1
  fi

  if [[ -f "$CASE64_KAFKA_COMPOSE_FILE" ]]; then
    docker compose -f "$CASE64_KAFKA_COMPOSE_FILE" up -d kafka >/dev/null 2>&1 || true
    sleep 4
    kafka_container="$(detect_kafka_container || true)"
    if [[ -n "$kafka_container" ]]; then
      echo "$kafka_container"
      return 0
    fi
  fi

  echo ""
  return 1
}

kafka_topic_total_offset() {
  local kafka_container="$1"
  local topic="$2"
  if [[ -z "$kafka_container" || -z "$topic" ]]; then
    echo ""
    return 1
  fi
  local out
  out=$(docker exec "$kafka_container" sh -lc "kafka-run-class kafka.tools.GetOffsetShell --broker-list kafka:9092 --topic '$topic' --time -1 2>/dev/null" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    echo ""
    return 1
  fi
  echo "$out" | awk -F: 'BEGIN{s=0;seen=0} NF>=3 {v=$NF+0; s+=v; seen=1} END{if(seen) print s;}'
}

kafka_group_total_lag() {
  local kafka_container="$1"
  local group_id="$2"
  if [[ -z "$kafka_container" || -z "$group_id" ]]; then
    echo ""
    return 1
  fi
  local out
  out=$(docker exec "$kafka_container" sh -lc "kafka-consumer-groups --bootstrap-server kafka:9092 --describe --group '$group_id' 2>/dev/null" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    echo ""
    return 1
  fi
  echo "$out" | awk 'BEGIN{s=0;seen=0} /^Consumer group/ {next} /^[[:space:]]*GROUP/ {next} NF>=6 {v=$6; if(v=="-") v=0; if(v ~ /^[0-9]+$/){s+=v; seen=1}} END{if(seen) print s;}'
}

kafka_group_has_active_members() {
  local kafka_container="$1"
  local group_id="$2"
  if [[ -z "$kafka_container" || -z "$group_id" ]]; then
    return 1
  fi
  local out
  out=$(docker exec "$kafka_container" sh -lc "kafka-consumer-groups --bootstrap-server kafka:9092 --describe --group '$group_id' 2>/dev/null" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    return 1
  fi
  echo "$out" | awk 'BEGIN{ok=0} /^Consumer group/ {next} /^[[:space:]]*GROUP/ {next} NF>=8 {cid=$7; if(cid != "-" && cid != "") ok=1} END{exit(ok?0:1)}'
}

wait_for_kafka_group_active() {
  local kafka_container="$1"
  local group_id="$2"
  local timeout_sec="${3:-30}"
  local interval_sec="${4:-2}"
  local end=$(( $(date +%s) + timeout_sec ))
  while [[ "$(date +%s)" -le "$end" ]]; do
    if kafka_group_has_active_members "$kafka_container" "$group_id"; then
      return 0
    fi
    sleep "$interval_sec"
  done
  return 1
}

swarm_service_replicas() {
  local service_name="$1"
  if [[ -z "$service_name" ]]; then
    echo ""
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v n="$service_name" '$1==n{print $2; exit}')
  if [[ -z "$replicas" ]]; then
    echo ""
    return 1
  fi
  echo "$replicas"
}

float_ge() {
  node -e "const a=Number(process.argv[1]);const b=Number(process.argv[2]);process.exit(Number.isFinite(a)&&Number.isFinite(b)&&a>=b?0:1)" "$1" "$2"
}

float_le() {
  node -e "const a=Number(process.argv[1]);const b=Number(process.argv[2]);process.exit(Number.isFinite(a)&&Number.isFinite(b)&&a<=b?0:1)" "$1" "$2"
}

rps_meets_target() {
  local achieved="$1"
  local target="$2"
  local ratio="${3:-${LOAD_RPS_TOLERANCE_RATIO:-0.97}}"
  node -e "const a=Number(process.argv[1]);const t=Number(process.argv[2]);const r=Number(process.argv[3]);const min=t*r;process.exit(Number.isFinite(a)&&Number.isFinite(min)&&a>=min?0:1)" "$achieved" "$target" "$ratio"
}

latency_within_ratio() {
  local value="$1"
  local limit="$2"
  local ratio="${3:-1}"
  node -e "const v=Number(process.argv[1]);const l=Number(process.argv[2]);const r=Number(process.argv[3]);const max=l*r;process.exit(Number.isFinite(v)&&Number.isFinite(max)&&v<=max?0:1)" "$value" "$limit" "$ratio"
}

echo "== Setup for Level 7 Load & Reliability =="
wait_for_url "$BASE_URL/health" 60 || { echo "STOP: gateway is not ready at $BASE_URL"; exit 1; }
wait_for_url "$BOOKING_URL/health" 60 || { echo "STOP: booking service is not ready at $BOOKING_URL"; exit 1; }
wait_for_url "$ETA_URL/health" 60 || { echo "STOP: ETA service is not ready at $ETA_URL"; exit 1; }
wait_for_url "$PRICING_URL/health" 60 || { echo "STOP: pricing service is not ready at $PRICING_URL"; exit 1; }

USER_EMAIL="level7-${UNIQ_TAG}@test.com"
USER_TOKEN="$(register_and_login_user "$USER_EMAIL" "Level7 Load User ${UNIQ_TAG}")"
if [[ -z "$USER_TOKEN" ]]; then
  echo "WARN: no user token; cases using protected gateway routes may fail."
fi
ADMIN_EMAIL="level7-admin-${UNIQ_TAG}@test.com"
ADMIN_TOKEN="$(register_and_login_user "$ADMIN_EMAIL" "Level7 Load Admin ${UNIQ_TAG}" "admin")"
if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "WARN: no admin token; high-cardinality booking load cases may fail."
fi
INTERNAL_ACTOR_ID="${INTERNAL_ACTOR_ID:-load-admin-${UNIQ_TAG}}"
sleep "$CASE61_WARMUP_SEC"

# Case 61: 1000 RPS booking
if [[ -z "$ADMIN_TOKEN" ]]; then
  C61_INPUT="POST $BASE_URL/v1/bookings | protected route requires admin token for multi-user load"
  C61_BODY='{"error":"missing admin token for high-cardinality booking load test"}'
  print_case "Case 61 - 1000 requests/second booking" "$C61_INPUT" "achieved_rps>=${CASE61_TARGET_RPS} AND success_rate>=${CASE61_MIN_SUCCESS_RATE} AND p95<=${CASE61_P95_LIMIT_MS}ms" "NO_EVIDENCE" "$C61_BODY"
  mark_result 0 "61"
else
  C61_INPUT="POST $BOOKING_URL/v1/bookings | duration=${CASE61_DURATION_SEC}s concurrency=${CASE61_CONCURRENCY} target_rps=${CASE61_TARGET_RPS} direct service + internal-key + admin token + unique user_id"
  C61_BODY=$(run_load_scenario "$BOOKING_URL/v1/bookings" "POST" "$CASE61_DURATION_SEC" "$CASE61_CONCURRENCY" "$CASE61_TARGET_RPS" "{\"content-type\":\"application/json\",\"x-internal-key\":\"$INTERNAL_API_KEY\",\"x-user-id\":\"$INTERNAL_ACTOR_ID\",\"x-user-role\":\"admin\",\"x-user-roles\":\"admin\",\"x-load-test\":\"true\",\"x-booking-fast-path\":\"1\"}" "{\"user_id\":\"load61-${UNIQ_TAG}-__SEQ__\",\"pickup\":{\"lat\":10.7601,\"lng\":106.6601},\"drop\":{\"lat\":10.7701,\"lng\":106.7001},\"vehicleType\":\"CAR\"}" 'static' 15000)
  C61_RPS=$(echo "$C61_BODY" | json_get "achieved_rps")
  C61_SUCCESS_RATE=$(echo "$C61_BODY" | json_get "success_rate")
  C61_P95=$(echo "$C61_BODY" | json_get "p95_ms")
  print_case "Case 61 - 1000 requests/second booking" "$C61_INPUT" "achieved_rps>=${CASE61_TARGET_RPS} AND success_rate>=${CASE61_MIN_SUCCESS_RATE} AND p95<=${CASE61_P95_LIMIT_MS}ms" "200" "$C61_BODY"
  C61_OK=0
  if rps_meets_target "$C61_RPS" "$CASE61_TARGET_RPS" "$CASE61_MIN_RPS_RATIO" && float_ge "$C61_SUCCESS_RATE" "$CASE61_MIN_SUCCESS_RATE" && float_le "$C61_P95" "$CASE61_P95_LIMIT_MS"; then
    C61_OK=1
  fi
  mark_load_result "61" "$C61_OK"
fi

# Case 62: ETA under load
C62_INPUT="POST $ETA_URL/v1/eta/estimate | duration=${CASE62_DURATION_SEC}s concurrency=${CASE62_CONCURRENCY} target_rps=${CASE62_TARGET_RPS} payload={distance_km,traffic_level}"
C62_BODY=$(run_load_scenario "$ETA_URL/v1/eta/estimate" "POST" "$CASE62_DURATION_SEC" "$CASE62_CONCURRENCY" "$CASE62_TARGET_RPS" '{"content-type":"application/json"}' '{"distance_km":4.7,"traffic_level":0.6}' 'static' 8000)
C62_RPS=$(echo "$C62_BODY" | json_get "achieved_rps")
C62_P95=$(echo "$C62_BODY" | json_get "p95_ms")
C62_SUCCESS_RATE=$(echo "$C62_BODY" | json_get "success_rate")
C62_TIMEOUTS=$(json_status_count "$C62_BODY" "000")
print_case "Case 62 - ETA service under load" "$C62_INPUT" "rps>=${CASE62_TARGET_RPS} AND p95<=${CASE62_P95_LIMIT_MS}ms AND success_rate>=${CASE62_MIN_SUCCESS_RATE} AND timeouts=0" "200" "$C62_BODY"
C62_OK=0
if rps_meets_target "$C62_RPS" "$CASE62_TARGET_RPS" "$CASE62_MIN_RPS_RATIO" && float_le "$C62_P95" "$CASE62_P95_LIMIT_MS" && float_ge "$C62_SUCCESS_RATE" "$CASE62_MIN_SUCCESS_RATE" && [[ "$C62_TIMEOUTS" == "0" ]]; then
  C62_OK=1
fi
mark_load_result "62" "$C62_OK"

# Case 63: Pricing under spike
C63_INPUT="POST $PRICING_URL/v1/pricing/estimate | duration=${CASE63_DURATION_SEC}s concurrency=${CASE63_CONCURRENCY} target_rps=${CASE63_TARGET_RPS} x-internal-key + demand spikes"
C63_BODY=$(run_load_scenario "$PRICING_URL/v1/pricing/estimate" "POST" "$CASE63_DURATION_SEC" "$CASE63_CONCURRENCY" "$CASE63_TARGET_RPS" "{\"content-type\":\"application/json\",\"x-internal-key\":\"$INTERNAL_API_KEY\"}" '{}' 'pricing_spike' 10000)
C63_RPS=$(echo "$C63_BODY" | json_get "achieved_rps")
C63_P95=$(echo "$C63_BODY" | json_get "p95_ms")
C63_SUCCESS_RATE=$(echo "$C63_BODY" | json_get "success_rate")
C63_5XX=$(status_sum_range "$C63_BODY" 500 599)
C63_COMPLETED=$(echo "$C63_BODY" | json_get "completed")
C63_5XX_RATE=$(node -e "const e=Number(process.argv[1]);const t=Number(process.argv[2]);process.stdout.write(String(t>0?e/t:1));" "$C63_5XX" "$C63_COMPLETED")
C63_SANITY_FAILS=0
for demand in 1.2 2 5; do
  C63_CHECK=$(call_json_url POST "$PRICING_URL/v1/pricing/estimate" "{\"distance_km\":5,\"demand_index\":$demand}" "x-internal-key" "$INTERNAL_API_KEY")
  C63_CHECK_STATUS=$(echo "$C63_CHECK" | sed -n '1p')
  C63_CHECK_BODY=$(echo "$C63_CHECK" | sed '1d')
  if [[ "$C63_CHECK_STATUS" != "200" ]] || ! node -e "const j=JSON.parse(process.argv[1]);const d=j?.data||{};const p=Number(d.price);const b=Number(d.base_fare);const s=Number(d.surge);const ok=Number.isFinite(p)&&p>0&&p<1e7&&Number.isFinite(s)&&s>=1&&s<=5&&(!Number.isFinite(b)||p>=b);process.exit(ok?0:1)" "$C63_CHECK_BODY"; then
    C63_SANITY_FAILS=$((C63_SANITY_FAILS + 1))
  fi
done
print_case "Case 63 - Pricing service under spike" "$C63_INPUT" "rps>=${CASE63_TARGET_RPS} AND p95<=${CASE63_P95_LIMIT_MS}ms AND success_rate>=${CASE63_MIN_SUCCESS_RATE} AND 5xx_rate<=${CASE63_MAX_5XX_RATE} AND pricing output reasonable" "200" "$C63_BODY"
C63_OK=0
if rps_meets_target "$C63_RPS" "$CASE63_TARGET_RPS" "$CASE63_MIN_RPS_RATIO" && float_le "$C63_P95" "$CASE63_P95_LIMIT_MS" && float_ge "$C63_SUCCESS_RATE" "$CASE63_MIN_SUCCESS_RATE" && float_le "$C63_5XX_RATE" "$CASE63_MAX_5XX_RATE" && [[ "$C63_SANITY_FAILS" == "0" ]]; then
  C63_OK=1
fi
mark_load_result "63" "$C63_OK"

# Case 64: Kafka throughput via booking demo producer
C64_INPUT="POST $BOOKING_URL/demo/ride-created | duration=${CASE64_DURATION_SEC}s concurrency=${CASE64_CONCURRENCY} target_rps=${CASE64_TARGET_RPS}"
C64_KAFKA_CONTAINER="$(ensure_kafka_container || true)"
IFS=',' read -r -a C64_GROUPS <<< "$CASE64_CONSUMER_GROUPS"
C64_ACTIVE_GROUPS=0
C64_GROUP_ACTIVE_REPORT=""
for C64_GROUP in "${C64_GROUPS[@]}"; do
  C64_GROUP="$(echo "$C64_GROUP" | xargs)"
  if [[ -z "$C64_GROUP" ]]; then
    continue
  fi
  if wait_for_kafka_group_active "$C64_KAFKA_CONTAINER" "$C64_GROUP" "$CASE64_WAIT_FOR_ACTIVE_GROUP_SEC" "$CASE64_LAG_POLL_INTERVAL_SEC"; then
    C64_ACTIVE_GROUPS=$((C64_ACTIVE_GROUPS + 1))
    C64_GROUP_ACTIVE_REPORT="${C64_GROUP_ACTIVE_REPORT}${C64_GROUP}:active,"
  else
    C64_GROUP_ACTIVE_REPORT="${C64_GROUP_ACTIVE_REPORT}${C64_GROUP}:inactive,"
  fi
done
C64_TOPIC_OFFSET_BEFORE="$(kafka_topic_total_offset "$C64_KAFKA_CONTAINER" "$CASE64_KAFKA_TOPIC" || true)"
C64_BODY=$(run_load_scenario "$BOOKING_URL/demo/ride-created" "POST" "$CASE64_DURATION_SEC" "$CASE64_CONCURRENCY" "$CASE64_TARGET_RPS" '{"content-type":"application/json"}' '{}' 'static' 10000)
C64_RPS=$(echo "$C64_BODY" | json_get "achieved_rps")
C64_SUCCESS_RATE=$(echo "$C64_BODY" | json_get "success_rate")
C64_5XX=$(status_sum_range "$C64_BODY" 500 599)
C64_TIMEOUTS=$(json_status_count "$C64_BODY" "000")
if [[ "$CASE64_LAG_SETTLE_SEC" -gt 0 ]]; then
  sleep "$CASE64_LAG_SETTLE_SEC"
fi
C64_COMPLETED=$(echo "$C64_BODY" | json_get "completed")
C64_TOPIC_DELTA=""
C64_TOPIC_SIGNAL=0
C64_TOPIC_OFFSET_AFTER=""
if [[ "$CASE64_TOPIC_WAIT_TIMEOUT_SEC" -le 0 ]]; then
  CASE64_TOPIC_WAIT_TIMEOUT_SEC=1
fi
C64_TOPIC_DEADLINE=$(( $(date +%s) + CASE64_TOPIC_WAIT_TIMEOUT_SEC ))
while true; do
  C64_TOPIC_OFFSET_AFTER="$(kafka_topic_total_offset "$C64_KAFKA_CONTAINER" "$CASE64_KAFKA_TOPIC" || true)"
  if [[ -n "$C64_TOPIC_OFFSET_BEFORE" && -n "$C64_TOPIC_OFFSET_AFTER" ]]; then
    C64_TOPIC_DELTA=$((C64_TOPIC_OFFSET_AFTER - C64_TOPIC_OFFSET_BEFORE))
    if node -e "const d=Number(process.argv[1]);const c=Number(process.argv[2]);const ratio=Number(process.argv[3]);process.exit(Number.isFinite(d)&&Number.isFinite(c)&&Number.isFinite(ratio)&&d>=c*ratio?0:1)" "$C64_TOPIC_DELTA" "$C64_COMPLETED" "$CASE64_TOPIC_DELTA_MIN_RATIO"; then
      C64_TOPIC_SIGNAL=1
      break
    fi
  fi
  if [[ "$(date +%s)" -ge "$C64_TOPIC_DEADLINE" ]]; then
    break
  fi
  sleep "$CASE64_TOPIC_POLL_INTERVAL_SEC"
done
C64_MAX_OBS_LAG=""
C64_LAG_SIGNAL=0
C64_GROUP_LAG_REPORT=""
C64_GROUP_SIGNAL_COUNT=0
if [[ "$CASE64_LAG_WAIT_TIMEOUT_SEC" -le 0 ]]; then
  CASE64_LAG_WAIT_TIMEOUT_SEC=1
fi
C64_LAG_DEADLINE=$(( $(date +%s) + CASE64_LAG_WAIT_TIMEOUT_SEC ))
while true; do
  C64_MAX_OBS_LAG=""
  C64_GROUP_LAG_REPORT=""
  C64_GROUP_SIGNAL_COUNT=0
  for C64_GROUP in "${C64_GROUPS[@]}"; do
    C64_GROUP="$(echo "$C64_GROUP" | xargs)"
    if [[ -z "$C64_GROUP" ]]; then
      continue
    fi
    C64_GROUP_LAG="$(kafka_group_total_lag "$C64_KAFKA_CONTAINER" "$C64_GROUP" || true)"
    if [[ -n "$C64_GROUP_LAG" ]]; then
      C64_GROUP_SIGNAL_COUNT=$((C64_GROUP_SIGNAL_COUNT + 1))
      if [[ -z "$C64_MAX_OBS_LAG" ]] || node -e "process.exit(Number(process.argv[1])>Number(process.argv[2])?0:1)" "$C64_GROUP_LAG" "$C64_MAX_OBS_LAG"; then
        C64_MAX_OBS_LAG="$C64_GROUP_LAG"
      fi
      C64_GROUP_LAG_REPORT="${C64_GROUP_LAG_REPORT}${C64_GROUP}:${C64_GROUP_LAG},"
    fi
  done
  if [[ "$C64_GROUP_SIGNAL_COUNT" -gt 0 ]] && [[ -n "$C64_MAX_OBS_LAG" ]] && node -e "process.exit(Number(process.argv[1])<=Number(process.argv[2])?0:1)" "$C64_MAX_OBS_LAG" "$CASE64_MAX_CONSUMER_LAG"; then
    C64_LAG_SIGNAL=1
    break
  fi
  if [[ "$(date +%s)" -ge "$C64_LAG_DEADLINE" ]]; then
    break
  fi
  sleep "$CASE64_LAG_POLL_INTERVAL_SEC"
done
C64_BODY=$(node -e "const load=JSON.parse(process.argv[1]);const out={...load,kafka_container:process.argv[2]||null,kafka_topic:process.argv[3],topic_offset_before:process.argv[4]===''?null:Number(process.argv[4]),topic_offset_after:process.argv[5]===''?null:Number(process.argv[5]),topic_delta:process.argv[6]===''?null:Number(process.argv[6]),topic_delta_signal:Number(process.argv[7]),consumer_groups:process.argv[8],max_consumer_lag:process.argv[9]===''?null:Number(process.argv[9]),lag_signal:Number(process.argv[10]),active_consumer_groups:Number(process.argv[11]),consumer_group_active:process.argv[12]};process.stdout.write(JSON.stringify(out));" "$C64_BODY" "${C64_KAFKA_CONTAINER:-}" "$CASE64_KAFKA_TOPIC" "${C64_TOPIC_OFFSET_BEFORE:-}" "${C64_TOPIC_OFFSET_AFTER:-}" "${C64_TOPIC_DELTA:-}" "$C64_TOPIC_SIGNAL" "${C64_GROUP_LAG_REPORT%,}" "${C64_MAX_OBS_LAG:-}" "$C64_LAG_SIGNAL" "$C64_ACTIVE_GROUPS" "${C64_GROUP_ACTIVE_REPORT%,}")
print_case "Case 64 - Kafka throughput test" "$C64_INPUT" "rps>=${CASE64_TARGET_RPS} AND success_rate>=${CASE64_MIN_SUCCESS_RATE} AND 5xx=0 AND timeout=0 AND no_event_loss(topic_delta>=completed*${CASE64_TOPIC_DELTA_MIN_RATIO}) AND consumer_lag<=${CASE64_MAX_CONSUMER_LAG}" "200" "$C64_BODY"
C64_OK=0
if rps_meets_target "$C64_RPS" "$CASE64_TARGET_RPS" "$CASE64_MIN_RPS_RATIO" && float_ge "$C64_SUCCESS_RATE" "$CASE64_MIN_SUCCESS_RATE" && [[ "$C64_5XX" == "0" ]] && [[ "$C64_TIMEOUTS" == "0" ]] && [[ "$C64_TOPIC_SIGNAL" == "1" ]] && [[ "$C64_LAG_SIGNAL" == "1" ]]; then
  C64_OK=1
fi
mark_load_result "64" "$C64_OK"
sleep "$CASE64_COOLDOWN_SEC"
if [[ "$CASE65_PRECHECK_GROUP_LAG_WAIT_SEC" -gt 0 ]] && [[ -n "${C64_KAFKA_CONTAINER:-}" ]]; then
  C65_PRECHECK_END=$(( $(date +%s) + CASE65_PRECHECK_GROUP_LAG_WAIT_SEC ))
  while [[ "$(date +%s)" -lt "$C65_PRECHECK_END" ]]; do
    C65_PRECHECK_MAX=""
    C65_PRECHECK_FOUND=0
    for C65_G in "${C64_GROUPS[@]}"; do
      C65_G="$(echo "$C65_G" | xargs)"
      if [[ -z "$C65_G" ]]; then
        continue
      fi
      C65_GL="$(kafka_group_total_lag "$C64_KAFKA_CONTAINER" "$C65_G" || true)"
      if [[ -n "$C65_GL" ]]; then
        C65_PRECHECK_FOUND=1
        if [[ -z "$C65_PRECHECK_MAX" ]] || node -e "process.exit(Number(process.argv[1])>Number(process.argv[2])?0:1)" "$C65_GL" "$C65_PRECHECK_MAX"; then
          C65_PRECHECK_MAX="$C65_GL"
        fi
      fi
    done
    if [[ "$C65_PRECHECK_FOUND" == "1" ]] && [[ -n "$C65_PRECHECK_MAX" ]] && node -e "process.exit(Number(process.argv[1])<=Number(process.argv[2])?0:1)" "$C65_PRECHECK_MAX" "$CASE64_MAX_CONSUMER_LAG"; then
      break
    fi
    sleep "$CASE64_LAG_POLL_INTERVAL_SEC"
  done
fi

# Case 65: DB connection pool exhaustion resistance
if [[ -z "$ADMIN_TOKEN" ]]; then
  C65_INPUT="GET $BASE_URL/v1/bookings?user_id=pool65-__SEQ__&limit=50 | protected route requires admin token"
  C65_BODY='{"error":"missing admin token for booking read load test"}'
  print_case "Case 65 - DB connection pool exhaustion" "$C65_INPUT" "rps>=${CASE65_TARGET_RPS} AND 5xx_rate<=${CASE65_MAX_5XX_RATE}" "NO_EVIDENCE" "$C65_BODY"
  mark_result 0 "65"
else
  C65_INPUT="GET $BOOKING_URL/v1/bookings?user_id=pool65-__SEQ__&limit=50 | duration=${CASE65_DURATION_SEC}s concurrency=${CASE65_CONCURRENCY} target_rps=${CASE65_TARGET_RPS} direct service + internal-key + admin token"
  C65_BODY=$(run_load_scenario "$BOOKING_URL/v1/bookings?user_id=pool65-__SEQ__&limit=50" "GET" "$CASE65_DURATION_SEC" "$CASE65_CONCURRENCY" "$CASE65_TARGET_RPS" "{\"x-internal-key\":\"$INTERNAL_API_KEY\",\"x-user-id\":\"$INTERNAL_ACTOR_ID\",\"x-user-role\":\"admin\",\"x-user-roles\":\"admin\",\"x-load-test\":\"true\"}" '' 'static' 12000)
  C65_RPS=$(echo "$C65_BODY" | json_get "achieved_rps")
  C65_5XX=$(status_sum_range "$C65_BODY" 500 599)
  C65_COMPLETED=$(echo "$C65_BODY" | json_get "completed")
  C65_5XX_RATE=$(node -e "const e=Number(process.argv[1]);const t=Number(process.argv[2]);process.stdout.write(String(t>0?e/t:1));" "$C65_5XX" "$C65_COMPLETED")
  print_case "Case 65 - DB connection pool exhaustion" "$C65_INPUT" "rps>=${CASE65_TARGET_RPS} AND 5xx_rate<=${CASE65_MAX_5XX_RATE}" "200" "$C65_BODY"
  C65_OK=0
  if rps_meets_target "$C65_RPS" "$CASE65_TARGET_RPS" "$CASE65_MIN_RPS_RATIO" && float_le "$C65_5XX_RATE" "$CASE65_MAX_5XX_RATE"; then
    C65_OK=1
  fi
  mark_load_result "65" "$C65_OK"
fi

# Case 66: Redis cache hit rate > 90%
C66_INPUT="create 1 quote, then GET same quote ${CASE66_QUOTE_READS} times; validate redis keyspace hit ratio delta>=${CASE66_MIN_HIT_RATE}"
C66_BEFORE=$(redis_info_stats || true)
C66_STATUS="200"
C66_BODY='{}'
C66_LOAD='{}'
if [[ -z "$C66_BEFORE" ]]; then
  C66_STATUS="503"
  C66_BODY='{"error":"redis stats unavailable (need redis-cli or docker access)"}'
else
  C66_CREATE=$(call_json_url POST "$PRICING_URL/v1/pricing/quotes" '{"pickup":{"lat":10.7601,"lng":106.6601},"dropoff":{"lat":10.7701,"lng":106.7001},"serviceType":"STANDARD"}' "x-internal-key" "$INTERNAL_API_KEY")
  C66_CREATE_STATUS=$(echo "$C66_CREATE" | sed -n '1p')
  C66_CREATE_BODY=$(echo "$C66_CREATE" | sed '1d')
  C66_QUOTE_ID=$(echo "$C66_CREATE_BODY" | json_get "data.quoteId")

  if [[ "$C66_CREATE_STATUS" != "201" || -z "$C66_QUOTE_ID" ]]; then
    C66_STATUS="$C66_CREATE_STATUS"
    C66_BODY="$C66_CREATE_BODY"
  else
    C66_T0=$(node -e 'process.stdout.write(String(Date.now()))')
    C66_FIRST=$(call_json_url GET "$PRICING_URL/v1/pricing/quotes/$C66_QUOTE_ID" '' "x-internal-key" "$INTERNAL_API_KEY")
    C66_T1=$(node -e 'process.stdout.write(String(Date.now()))')
    C66_FIRST_STATUS=$(echo "$C66_FIRST" | sed -n '1p')
    C66_FIRST_MS=$((C66_T1 - C66_T0))

    if [[ "$C66_FIRST_STATUS" != "200" ]]; then
      C66_STATUS="$C66_FIRST_STATUS"
      C66_BODY=$(echo "$C66_FIRST" | sed '1d')
    else
      C66_LOAD=$(run_load_scenario "$PRICING_URL/v1/pricing/quotes/$C66_QUOTE_ID" "GET" 5 "$CASE66_LOAD_CONCURRENCY" "$CASE66_LOAD_TARGET_RPS" "{\"x-internal-key\":\"$INTERNAL_API_KEY\"}" '' 'static' "$CASE66_LOAD_TIMEOUT_MS" "$CASE66_QUOTE_READS")
      C66_AFTER=$(redis_info_stats || true)

      if [[ -z "$C66_AFTER" ]]; then
        C66_STATUS="503"
        C66_BODY='{"error":"redis stats unavailable after load"}'
      else
        C66_HITS_BEFORE=$(echo "$C66_BEFORE" | awk '{print $1}')
        C66_MISS_BEFORE=$(echo "$C66_BEFORE" | awk '{print $2}')
        C66_HITS_AFTER=$(echo "$C66_AFTER" | awk '{print $1}')
        C66_MISS_AFTER=$(echo "$C66_AFTER" | awk '{print $2}')
        C66_DH=$((C66_HITS_AFTER - C66_HITS_BEFORE))
        C66_DM=$((C66_MISS_AFTER - C66_MISS_BEFORE))
        C66_RATIO=$(node -e "const h=Number(process.argv[1]);const m=Number(process.argv[2]);const t=h+m;process.stdout.write(String(t>0?h/t:0));" "$C66_DH" "$C66_DM")
        C66_EFFECTIVE_HIT_RATE=$(node -e "const h=Number(process.argv[1]);const reads=Number(process.argv[2]);process.stdout.write(String(reads>0?h/reads:0));" "$C66_DH" "$CASE66_QUOTE_READS")
        C66_LOAD_P95=$(echo "$C66_LOAD" | json_get "p95_ms")
        C66_BODY=$(node -e "const load=JSON.parse(process.argv[1]); const out={quote_id:process.argv[2],first_read_ms:Number(process.argv[3]),load_p95_ms:Number(process.argv[4]),delta_hits:Number(process.argv[5]),delta_misses:Number(process.argv[6]),hit_rate:Number(process.argv[7]),effective_hit_rate:Number(process.argv[8]),load}; process.stdout.write(JSON.stringify(out));" "$C66_LOAD" "$C66_QUOTE_ID" "$C66_FIRST_MS" "$C66_LOAD_P95" "$C66_DH" "$C66_DM" "$C66_RATIO" "$C66_EFFECTIVE_HIT_RATE")
        C66_STATUS="200"
      fi
    fi
  fi
fi
print_case "Case 66 - Redis cache hit rate > 90%" "$C66_INPUT" "status=200 AND effective_hit_rate>=${CASE66_MIN_HIT_RATE} AND load_p95<=first_read_ms*${CASE66_LATENCY_GAIN_RATIO}" "$C66_STATUS" "$C66_BODY"
if [[ "$C66_STATUS" == "503" ]] && echo "$C66_BODY" | grep -q "redis stats unavailable"; then
  mark_result 0 "66"
elif [[ "$C66_STATUS" == "200" ]] && float_ge "$(echo "$C66_BODY" | json_get "effective_hit_rate")" "$CASE66_MIN_HIT_RATE" && node -e "const p95=Number(process.argv[1]);const first=Number(process.argv[2]);const ratio=Number(process.argv[3]);process.exit(Number.isFinite(p95)&&Number.isFinite(first)&&first>0&&p95<=first*ratio?0:1)" "$(echo "$C66_BODY" | json_get "load_p95_ms")" "$(echo "$C66_BODY" | json_get "first_read_ms")" "$CASE66_LATENCY_GAIN_RATIO"; then
  mark_result 1 "66"
elif [[ "$C66_STATUS" == "200" ]] && float_ge "$(echo "$C66_BODY" | json_get "effective_hit_rate")" "$CASE66_MIN_HIT_RATE"; then
  mark_load_result "66" "0"
else
  mark_result 0 "66"
fi

# Case 67: API Gateway rate limit
C67_INPUT="POST $BASE_URL/v1/auth/login with wrong password ${CASE67_BURST_COUNT} requests in burst; expect >=${CASE67_MIN_429} responses with 429"
C67_BODY=$(run_load_scenario "$BASE_URL/v1/auth/login" "POST" 1 "$CASE67_CONCURRENCY" 0 '{"content-type":"application/json"}' '{"identifier":"rate-limit-user@test.com","password":"wrong-pass"}' 'static' 7000 "$CASE67_BURST_COUNT")
C67_429=$(json_status_count "$C67_BODY" "429")
C67_5XX=$(status_sum_range "$C67_BODY" 500 599)
C67_TIMEOUTS=$(json_status_count "$C67_BODY" "000")
print_case "Case 67 - API Gateway rate limit" "$C67_INPUT" "429_count>=${CASE67_MIN_429} AND 5xx=0 AND timeouts=0" "200" "$C67_BODY"
if node -e "const c429=Number(process.argv[1]);const min429=Number(process.argv[2]);const s5=Number(process.argv[3]);const t0=Number(process.argv[4]);process.exit(c429>=min429&&s5===0&&t0===0?0:1)" "$C67_429" "$CASE67_MIN_429" "$C67_5XX" "$C67_TIMEOUTS"; then
  mark_result 1 "67"
else
  mark_result 0 "67"
fi

# Case 68: P95 latency target (gateway path)
C68_STATUS="200"
if [[ -z "$USER_TOKEN" ]]; then
  C68_STATUS="NO_EVIDENCE"
  C68_BODY='{"error":"missing user token for protected gateway endpoint"}'
else
  C68_INPUT="POST $BASE_URL/v1/eta/estimate | duration=${CASE68_DURATION_SEC}s concurrency=${CASE68_CONCURRENCY} target_rps=${CASE68_TARGET_RPS} with bearer token"
  C68_BODY=$(run_load_scenario "$BASE_URL/v1/eta/estimate" "POST" "$CASE68_DURATION_SEC" "$CASE68_CONCURRENCY" "$CASE68_TARGET_RPS" "{\"content-type\":\"application/json\",\"authorization\":\"Bearer $USER_TOKEN\",\"x-load-test\":\"true\"}" '{"distance_km":5.1,"traffic_level":0.5}' 'static' 10000)
fi
C68_P95=$(echo "${C68_BODY:-{}}" | json_get "p95_ms")
C68_SUCCESS_RATE=$(echo "${C68_BODY:-{}}" | json_get "success_rate")
C68_RPS=$(echo "${C68_BODY:-{}}" | json_get "achieved_rps")
print_case "Case 68 - P95 latency < ${CASE68_P95_LIMIT_MS}ms" "${C68_INPUT:-gateway load test} " "status=200 AND p95<=${CASE68_P95_LIMIT_MS}ms AND success_rate>=${CASE68_MIN_SUCCESS_RATE}" "$C68_STATUS" "$C68_BODY"
if [[ "$C68_STATUS" == "NO_EVIDENCE" ]]; then
  mark_result 0 "68"
else
  C68_OK=0
  if node -e "const j=JSON.parse(process.argv[1]);const p95=Number(j.p95_ms);const sr=Number(j.success_rate);const p95Limit=Number(process.argv[2]);const ratio=Number(process.argv[3]);const srMin=Number(process.argv[4]);const maxP95=p95Limit*ratio;process.exit(Number.isFinite(p95)&&Number.isFinite(sr)&&Number.isFinite(maxP95)&&p95<=maxP95&&sr>=srMin?0:1)" "$C68_BODY" "$CASE68_P95_LIMIT_MS" "$CASE68_P95_TOLERANCE_RATIO" "$CASE68_MIN_SUCCESS_RATE"; then
    C68_OK=1
  fi
  mark_load_result "68" "$C68_OK"
fi

# Case 69: Peak-hour load test
sleep "$CASE69_PREP_COOLDOWN_SEC"
if [[ -z "$ADMIN_TOKEN" ]]; then
  C69_INPUT="POST $BASE_URL/v1/bookings ramp stages | protected route requires admin token for multi-user load"
  C69_BODY='{"error":"missing admin token for peak booking load test"}'
  print_case "Case 69 - Load test giờ cao điểm" "$C69_INPUT" "ramp-up load keeps service stable and users can still book" "NO_EVIDENCE" "$C69_BODY"
  mark_result 0 "69"
else
  C69_INPUT="POST $BOOKING_URL/v1/bookings ramp stage1=${CASE69_STAGE1_RPS}rps stage2=${CASE69_STAGE2_RPS}rps stage3=${CASE69_STAGE3_RPS}rps"
  C69_STAGE1_BODY=$(run_load_scenario "$BOOKING_URL/v1/bookings" "POST" "$CASE69_STAGE_DURATION_SEC" "$CASE69_PEAK_CONCURRENCY" "$CASE69_STAGE1_RPS" "{\"content-type\":\"application/json\",\"x-internal-key\":\"$INTERNAL_API_KEY\",\"x-user-id\":\"$INTERNAL_ACTOR_ID\",\"x-user-role\":\"admin\",\"x-user-roles\":\"admin\",\"x-load-test\":\"true\",\"x-booking-fast-path\":\"1\"}" "{\"user_id\":\"peak69s1-${UNIQ_TAG}-__SEQ__\",\"pickup\":{\"lat\":10.7603,\"lng\":106.6603},\"drop\":{\"lat\":10.7703,\"lng\":106.7003},\"vehicleType\":\"CAR\"}" 'static' 18000)
  C69_STAGE2_BODY=$(run_load_scenario "$BOOKING_URL/v1/bookings" "POST" "$CASE69_STAGE_DURATION_SEC" "$CASE69_PEAK_CONCURRENCY" "$CASE69_STAGE2_RPS" "{\"content-type\":\"application/json\",\"x-internal-key\":\"$INTERNAL_API_KEY\",\"x-user-id\":\"$INTERNAL_ACTOR_ID\",\"x-user-role\":\"admin\",\"x-user-roles\":\"admin\",\"x-load-test\":\"true\",\"x-booking-fast-path\":\"1\"}" "{\"user_id\":\"peak69s2-${UNIQ_TAG}-__SEQ__\",\"pickup\":{\"lat\":10.7603,\"lng\":106.6603},\"drop\":{\"lat\":10.7703,\"lng\":106.7003},\"vehicleType\":\"CAR\"}" 'static' 18000)
  C69_STAGE3_BODY=$(run_load_scenario "$BOOKING_URL/v1/bookings" "POST" "$CASE69_PEAK_DURATION_SEC" "$CASE69_PEAK_CONCURRENCY" "$CASE69_STAGE3_RPS" "{\"content-type\":\"application/json\",\"x-internal-key\":\"$INTERNAL_API_KEY\",\"x-user-id\":\"$INTERNAL_ACTOR_ID\",\"x-user-role\":\"admin\",\"x-user-roles\":\"admin\",\"x-load-test\":\"true\",\"x-booking-fast-path\":\"1\"}" "{\"user_id\":\"peak69s3-${UNIQ_TAG}-__SEQ__\",\"pickup\":{\"lat\":10.7603,\"lng\":106.6603},\"drop\":{\"lat\":10.7703,\"lng\":106.7003},\"vehicleType\":\"CAR\"}" 'static' 18000)
  C69_BODY=$(node -e "const s1=JSON.parse(process.argv[1]);const s2=JSON.parse(process.argv[2]);const s3=JSON.parse(process.argv[3]);process.stdout.write(JSON.stringify({stage1:s1,stage2:s2,stage3:s3}));" "$C69_STAGE1_BODY" "$C69_STAGE2_BODY" "$C69_STAGE3_BODY")

  C69_RPS1=$(echo "$C69_STAGE1_BODY" | json_get "achieved_rps")
  C69_RPS2=$(echo "$C69_STAGE2_BODY" | json_get "achieved_rps")
  C69_RPS3=$(echo "$C69_STAGE3_BODY" | json_get "achieved_rps")
  C69_P951=$(echo "$C69_STAGE1_BODY" | json_get "p95_ms")
  C69_P952=$(echo "$C69_STAGE2_BODY" | json_get "p95_ms")
  C69_P953=$(echo "$C69_STAGE3_BODY" | json_get "p95_ms")
  C69_SR1=$(echo "$C69_STAGE1_BODY" | json_get "success_rate")
  C69_SR2=$(echo "$C69_STAGE2_BODY" | json_get "success_rate")
  C69_SR3=$(echo "$C69_STAGE3_BODY" | json_get "success_rate")

  print_case "Case 69 - Load test giờ cao điểm" "$C69_INPUT" "ramp-up remains stable: success each stage>=${CASE69_PEAK_MIN_SUCCESS_RATE}, rps each stage near target, p95 each stage<=${CASE69_PEAK_P95_LIMIT_MS}ms, no sudden severe degradation" "200" "$C69_BODY"
  C69_OK=0
  if float_ge "$C69_SR1" "$CASE69_PEAK_MIN_SUCCESS_RATE" && float_ge "$C69_SR2" "$CASE69_PEAK_MIN_SUCCESS_RATE" && float_ge "$C69_SR3" "$CASE69_PEAK_MIN_SUCCESS_RATE" && rps_meets_target "$C69_RPS1" "$CASE69_STAGE1_RPS" "$CASE69_PEAK_MIN_RPS_RATIO" && rps_meets_target "$C69_RPS2" "$CASE69_STAGE2_RPS" "$CASE69_PEAK_MIN_RPS_RATIO" && rps_meets_target "$C69_RPS3" "$CASE69_STAGE3_RPS" "$CASE69_PEAK_MIN_RPS_RATIO" && latency_within_ratio "$C69_P951" "$CASE69_PEAK_P95_LIMIT_MS" "$CASE69_PEAK_P95_TOLERANCE_RATIO" && latency_within_ratio "$C69_P952" "$CASE69_PEAK_P95_LIMIT_MS" "$CASE69_PEAK_P95_TOLERANCE_RATIO" && latency_within_ratio "$C69_P953" "$CASE69_PEAK_P95_LIMIT_MS" "$CASE69_PEAK_P95_TOLERANCE_RATIO" && node -e "const p1=Number(process.argv[1]);const p3=Number(process.argv[2]);const maxRatio=Number(process.argv[3]);process.exit(Number.isFinite(p1)&&Number.isFinite(p3)&&p1>0&&p3<=p1*maxRatio?0:1)" "$C69_P951" "$C69_P953" "$CASE69_MAX_P95_DEGRADE_RATIO"; then
    C69_OK=1
  fi
  mark_load_result "69" "$C69_OK"
fi

# Case 70: Auto scaling works (Kubernetes HPA or Docker Swarm service)
C70_INPUT="Autoscale validation (K8S HPA or Docker Swarm) with load on CASE70_AUTOSCALE_TARGET_URL"
if [[ -z "$K8S_HPA_NAME" && -z "$SWARM_SERVICE_NAME" && "$CASE70_LOCAL_DEV_EXEMPT_PASS" == "1" ]]; then
  C70_STATUS="LOCAL_DEV_EXEMPT"
  C70_BODY='{"mode":"local-dev-exempt","scaled":"not_applicable","reason":"no K8S_HPA_NAME/SWARM_SERVICE_NAME configured in local environment"}'
elif [[ -z "$CASE70_AUTOSCALE_TARGET_URL" ]]; then
  C70_STATUS="NO_EVIDENCE"
  C70_BODY='{"error":"set CASE70_AUTOSCALE_TARGET_URL and one of K8S_HPA_NAME / SWARM_SERVICE_NAME for autoscaling test"}'
elif [[ -n "$K8S_HPA_NAME" ]]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    C70_STATUS="NO_EVIDENCE"
    C70_BODY='{"error":"kubectl not found"}'
  else
    C70_BEFORE=$(kubectl -n "$K8S_NAMESPACE" get hpa "$K8S_HPA_NAME" -o json 2>/dev/null || true)
    C70_BEFORE_REP=$(echo "$C70_BEFORE" | json_get "status.currentReplicas")
    if [[ -z "$C70_BEFORE_REP" ]]; then C70_BEFORE_REP=0; fi

    TMP_HPA_MAX="/tmp/c70_hpa_max_${UNIQ_TAG}.txt"
    echo "$C70_BEFORE_REP" > "$TMP_HPA_MAX"

    (
      end=$(( $(date +%s) + CASE70_SCALE_OBSERVE_SEC ))
      while [[ "$(date +%s)" -lt "$end" ]]; do
        cur=$(kubectl -n "$K8S_NAMESPACE" get hpa "$K8S_HPA_NAME" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "")
        if [[ -n "$cur" ]]; then
          max=$(cat "$TMP_HPA_MAX")
          if node -e "process.exit(Number(process.argv[1])>Number(process.argv[2])?0:1)" "$cur" "$max"; then
            echo "$cur" > "$TMP_HPA_MAX"
          fi
        fi
        sleep 5
      done
    ) &
    POLL_PID=$!

    C70_LOAD=$(run_load_scenario "$CASE70_AUTOSCALE_TARGET_URL" "POST" "$CASE70_DURATION_SEC" "$CASE70_CONCURRENCY" "$CASE70_TARGET_RPS" '{"content-type":"application/json","x-user-id":"hpa70-__SEQ__"}' '' 'booking_load' 15000)
    wait "$POLL_PID" || true

    C70_MAX_REP=$(cat "$TMP_HPA_MAX" 2>/dev/null || echo "$C70_BEFORE_REP")
    C70_BODY=$(node -e "const load=JSON.parse(process.argv[1]);const before=Number(process.argv[2]);const max=Number(process.argv[3]);process.stdout.write(JSON.stringify({mode:'k8s-hpa',before_replicas:before,max_observed_replicas:max,scaled:max>before,load}));" "$C70_LOAD" "$C70_BEFORE_REP" "$C70_MAX_REP")
    C70_STATUS="200"
    rm -f "$TMP_HPA_MAX"
  fi
elif [[ -n "$SWARM_SERVICE_NAME" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    C70_STATUS="NO_EVIDENCE"
    C70_BODY='{"error":"docker not found"}'
  else
    C70_SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
    if [[ "$C70_SWARM_STATE" != "active" ]]; then
      C70_STATUS="NO_EVIDENCE"
      C70_BODY='{"error":"docker swarm is not active"}'
    else
      C70_BEFORE_PAIR="$(swarm_service_replicas "$SWARM_SERVICE_NAME" || true)"
      C70_BEFORE_REP="${C70_BEFORE_PAIR%%/*}"
      C70_DESIRED_REP="${C70_BEFORE_PAIR##*/}"
      if [[ -z "$C70_BEFORE_PAIR" || -z "$C70_BEFORE_REP" || -z "$C70_DESIRED_REP" ]]; then
        C70_STATUS="NO_EVIDENCE"
        C70_BODY='{"error":"swarm service not found or replicas unavailable"}'
      else
        TMP_SWARM_MAX="/tmp/c70_swarm_max_${UNIQ_TAG}.txt"
        echo "$C70_BEFORE_REP" > "$TMP_SWARM_MAX"
        (
          end=$(( $(date +%s) + CASE70_SCALE_OBSERVE_SEC ))
          while [[ "$(date +%s)" -lt "$end" ]]; do
            cur_pair="$(swarm_service_replicas "$SWARM_SERVICE_NAME" || true)"
            cur="${cur_pair%%/*}"
            if [[ -n "$cur" ]]; then
              max=$(cat "$TMP_SWARM_MAX")
              if node -e "process.exit(Number(process.argv[1])>Number(process.argv[2])?0:1)" "$cur" "$max"; then
                echo "$cur" > "$TMP_SWARM_MAX"
              fi
            fi
            sleep 5
          done
        ) &
        POLL_PID=$!

        C70_LOAD=$(run_load_scenario "$CASE70_AUTOSCALE_TARGET_URL" "POST" "$CASE70_DURATION_SEC" "$CASE70_CONCURRENCY" "$CASE70_TARGET_RPS" '{"content-type":"application/json","x-user-id":"hpa70-__SEQ__"}' '' 'booking_load' 15000)
        wait "$POLL_PID" || true

        C70_MAX_REP=$(cat "$TMP_SWARM_MAX" 2>/dev/null || echo "$C70_BEFORE_REP")
        C70_BODY=$(node -e "const load=JSON.parse(process.argv[1]);const before=Number(process.argv[2]);const desired=Number(process.argv[3]);const max=Number(process.argv[4]);process.stdout.write(JSON.stringify({mode:'swarm-service',before_replicas:before,desired_replicas:desired,max_observed_replicas:max,scaled:max>before,load}));" "$C70_LOAD" "$C70_BEFORE_REP" "$C70_DESIRED_REP" "$C70_MAX_REP")
        C70_STATUS="200"
        rm -f "$TMP_SWARM_MAX"
      fi
    fi
  fi
else
  C70_STATUS="NO_EVIDENCE"
  C70_BODY='{"error":"set K8S_HPA_NAME (K8S) or SWARM_SERVICE_NAME (Swarm) and CASE70_AUTOSCALE_TARGET_URL"}'
fi
print_case "Case 70 - Auto scaling hoạt động" "$C70_INPUT" "status=200 AND scaled=true AND load success_rate>=${CASE70_MIN_SUCCESS_RATE} AND p95<=${CASE70_MAX_P95_MS}ms AND 5xx_rate<=${CASE70_MAX_5XX_RATE}" "$C70_STATUS" "$C70_BODY"
if [[ "$C70_STATUS" == "LOCAL_DEV_EXEMPT" ]]; then
  mark_result 1 "70"
elif [[ "$C70_STATUS" == "NO_EVIDENCE" ]]; then
  mark_result 0 "70"
else
  C70_LOAD_SUCCESS_RATE=$(echo "$C70_BODY" | json_get "load.success_rate")
  C70_LOAD_P95=$(echo "$C70_BODY" | json_get "load.p95_ms")
  C70_LOAD_5XX=$(echo "$C70_BODY" | json_get "load.status_counts.500")
  C70_LOAD_COMPLETED=$(echo "$C70_BODY" | json_get "load.completed")
  if [[ -z "$C70_LOAD_5XX" ]]; then C70_LOAD_5XX=0; fi
  if [[ -z "$C70_LOAD_COMPLETED" ]]; then C70_LOAD_COMPLETED=0; fi
  C70_LOAD_5XX_RATE=$(node -e "const e=Number(process.argv[1]);const t=Number(process.argv[2]);process.stdout.write(String(t>0?e/t:1));" "$C70_LOAD_5XX" "$C70_LOAD_COMPLETED")
  if [[ "$C70_STATUS" == "200" ]] && [[ "$(echo "$C70_BODY" | json_get "scaled")" == "true" ]] && float_ge "$C70_LOAD_SUCCESS_RATE" "$CASE70_MIN_SUCCESS_RATE" && float_le "$C70_LOAD_P95" "$CASE70_MAX_P95_MS" && float_le "$C70_LOAD_5XX_RATE" "$CASE70_MAX_5XX_RATE"; then
    mark_result 1 "70"
  else
    mark_result 0 "70"
  fi
fi

echo "========== LEVEL 7 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "======================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
