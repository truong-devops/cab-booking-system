#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

AGENT_URL="${AGENT_URL:-http://localhost:3013/v1/ai/agent/select-driver}"
AI_URL="${AI_URL:-http://host.docker.internal:3013}"
USER_TOKEN="${USER_TOKEN:-}"

PARALLEL_REQUESTS="${PARALLEL_REQUESTS:-200}"
CASE59_RATE="${CASE59_RATE:-1000}"
CASE59_DURATION="${CASE59_DURATION:-20s}"
CASE59_PRE_VUS="${CASE59_PRE_VUS:-300}"
CASE59_MAX_VUS="${CASE59_MAX_VUS:-1000}"
CASE59_TIMEOUT="${CASE59_TIMEOUT:-2s}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case59}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
BURST_JSON="$OUT_DIR/case59-burst-check.json"
K6_LOG="$OUT_DIR/k6-case59.log"
META_FILE="$OUT_DIR/meta.env"

mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd node
need_cmd docker

CASE_59_PAYLOAD='{
  "pickup": {"lat": 10.76, "lng": 106.66},
  "drop": {"lat": 10.77, "lng": 106.70},
  "vehicle_type": "CAR",
  "context": {"objective": "balanced_eta_price", "max_eta_min": 15, "budget_weight": 0.7, "latency_budget_ms": 200},
  "candidates": [
    {"driver_id": "d54_1", "distance_m": 220, "rating": 4.5, "online": true},
    {"driver_id": "d54_2", "distance_m": 420, "rating": 4.9, "online": true}
  ]
}'

run_burst_conflict_check() {
  PARALLEL_REQUESTS="$PARALLEL_REQUESTS" AGENT_URL="$AGENT_URL" CASE_PAYLOAD="$CASE_59_PAYLOAD" node - <<'NODE' | tee "$BURST_JSON"
const total = Number(process.env.PARALLEL_REQUESTS || 200);
const url = process.env.AGENT_URL;
const payload = JSON.parse(process.env.CASE_PAYLOAD || '{}');
const allowedSelected = new Set(['d54_1', 'd54_2']);

async function one(i) {
  const traceId = `case59-${Date.now()}-${i}`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-trace-id': traceId
      },
      body: JSON.stringify(payload)
    });
    const text = await res.text();
    let parsed = null;
    try { parsed = JSON.parse(text); } catch (_e) { parsed = null; }
    return {
      status: res.status,
      selected_driver: parsed?.data?.selected_driver?.driver_id || parsed?.data?.selected_driver?.driverId || null,
      strategy: parsed?.data?.strategy || null,
      trace_sent: traceId,
      trace_returned: parsed?.data?.decision_log?.trace_id || null
    };
  } catch (_e) {
    return { status: 0, selected_driver: null, strategy: null, trace_sent: traceId, trace_returned: null };
  }
}

(async () => {
  const statuses = await Promise.all(Array.from({ length: total }, (_, i) => one(i)));
  const ok200 = statuses.filter((x) => x.status === 200).length;
  const hasSelected = statuses.filter((x) => x.selected_driver).length;
  const invalidSelected = statuses.filter((x) => x.selected_driver && !allowedSelected.has(String(x.selected_driver))).length;
  const traceMismatch = statuses.filter((x) => x.trace_returned !== x.trace_sent).length;
  const traceReturnedSet = new Set(statuses.map((x) => x.trace_returned).filter(Boolean));
  const stableStrategy = statuses.every((x) => x.strategy === 'balanced_eta_price');
  const noConflict = ok200 === total
    && hasSelected === total
    && invalidSelected === 0
    && traceMismatch === 0
    && traceReturnedSet.size === total
    && stableStrategy;
  process.stdout.write(JSON.stringify({
    total,
    ok200,
    hasSelected,
    invalidSelected,
    traceMismatch,
    uniqueTraceReturned: traceReturnedSet.size,
    stableStrategy,
    noConflict,
    fail: total - ok200
  }, null, 2));
})();
NODE
}

run_k6_case59() {
  (
    cd "$REPO_ROOT"
    docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 \
      run \
      --env AI_URL="$AI_URL" \
      --env USER_TOKEN="$USER_TOKEN" \
      --env CASE59_RATE="$CASE59_RATE" \
      --env CASE59_DURATION="$CASE59_DURATION" \
      --env CASE59_PRE_VUS="$CASE59_PRE_VUS" \
      --env CASE59_MAX_VUS="$CASE59_MAX_VUS" \
      --env CASE59_TIMEOUT="$CASE59_TIMEOUT" \
      /work/case59-parallel-agent.js
  ) | tee "$K6_LOG"
}

{
  echo "CASE=59"
  echo "RUN_ID=$RUN_ID"
  echo "AGENT_URL=$AGENT_URL"
  echo "AI_URL=$AI_URL"
  echo "PARALLEL_REQUESTS=$PARALLEL_REQUESTS"
  echo "CASE59_RATE=$CASE59_RATE"
  echo "CASE59_DURATION=$CASE59_DURATION"
  echo "CASE59_PRE_VUS=$CASE59_PRE_VUS"
  echo "CASE59_MAX_VUS=$CASE59_MAX_VUS"
  echo "CASE59_TIMEOUT=$CASE59_TIMEOUT"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

echo "[case59] Step 1/2: burst conflict/race check ($PARALLEL_REQUESTS parallel requests)"
run_burst_conflict_check

if node -e "const fs=require('fs'); const j=JSON.parse(fs.readFileSync('$BURST_JSON','utf8')); process.exit(j.noConflict===true?0:1);"; then
  echo "[case59] Burst check: PASS (no conflict/race)"
  BURST_PASS=1
else
  echo "[case59] Burst check: FAIL (conflict/race detected)"
  BURST_PASS=0
fi

echo "[case59] Step 2/2: sustained parallel load by k6"
K6_PASS=1
if ! run_k6_case59; then
  K6_PASS=0
fi

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "BURST_PASS=$BURST_PASS" >> "$META_FILE"
echo "K6_PASS=$K6_PASS" >> "$META_FILE"

echo "Evidence saved:"
echo "- $BURST_JSON"
echo "- $K6_LOG"
echo "- $META_FILE"

if [[ "$BURST_PASS" != "1" || "$K6_PASS" != "1" ]]; then
  exit 1
fi
