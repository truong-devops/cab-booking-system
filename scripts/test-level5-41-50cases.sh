#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
AI_URL="${AI_URL:-http://localhost:42112}"
ETA_URL="${ETA_URL:-http://localhost:42111}"
PRICING_URL="${PRICING_URL:-http://localhost:42106}"
INTERNAL_API_KEY="${INTERNAL_API_KEY:-dev-internal-key}"
UNIQ_TAG="$(date +%s)-$RANDOM"
USER_EMAIL="${USER_EMAIL:-level5-strict-${UNIQ_TAG}@test.com}"
USER_PASS="${USER_PASS:-123456}"
USER_NAME="${USER_NAME:-Level5 Strict User ${UNIQ_TAG}}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-25}"
LATENCY_SAMPLES="${LATENCY_SAMPLES:-30}"
LATENCY_LIMIT_MS="${LATENCY_LIMIT_MS:-200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

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
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;if(/^\\d+$/.test(k)){v=Array.isArray(v)?v[Number(k)]:undefined}else{v=v?.[k]}}process.stdout.write(v==null?'':String(v))}catch(e){process.stdout.write('')}})"
}

print_case() {
  local title="$1"
  local expected="$2"
  local status="$3"
  local body="$4"
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
    echo "Input: $case_input"
  fi
  echo "Expected: $expected"
  echo "Actual status: $status"
  echo "Actual body:"
  echo "$body" | sed -n '1,60p'
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

call_json_url() {
  local method="$1"
  local url="$2"
  local token="${3:-}"
  local payload="${4:-}"
  local extra_header_key="${5:-}"
  local extra_header_value="${6:-}"

  local -a args
  args=(
    -s -X "$method" "$url"
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
  )

  if [[ -n "$token" ]]; then
    args+=( -H "Authorization: Bearer $token" )
  fi
  if [[ -n "$extra_header_key" ]]; then
    args+=( -H "$extra_header_key: $extra_header_value" )
  fi
  if [[ "$method" != "GET" && "$method" != "HEAD" ]]; then
    args+=( -H "Content-Type: application/json" )
    args+=( -d "$payload" )
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

call_gateway_json() {
  local method="$1"
  local path="$2"
  local token="${3:-}"
  local payload="${4:-}"
  call_json_url "$method" "$BASE_URL$path" "$token" "$payload"
}

extract_access_token() {
  local body="$1"
  echo "$body" | json_get "tokens.accessToken"
}

login_user() {
  local email="$1"
  local attempts="${2:-8}"
  local i=1
  local out='000
{"error":"login_not_attempted"}'
  while [[ "$i" -le "$attempts" ]]; do
    out=$(call_gateway_json POST "/v1/auth/login" "" "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}")
    local status
    status=$(echo "$out" | sed -n '1p')
    if [[ "$status" == "200" ]]; then
      printf '%s' "$out"
      return 0
    fi
    out=$(call_gateway_json POST "/v1/auth/login" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}")
    status=$(echo "$out" | sed -n '1p')
    if [[ "$status" == "200" ]]; then
      printf '%s' "$out"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  printf '%s' "$out"
  return 1
}

register_and_login_user() {
  local email="$1"
  local name="$2"
  call_gateway_json POST "/v1/auth/register" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"user\"}" >/dev/null || true
  local login
  login=$(login_user "$email" 8 || true)
  local body
  body=$(echo "$login" | sed '1d')
  extract_access_token "$body"
}

is_number_node() {
  local value="$1"
  node -e "const v=Number(process.argv[1]);process.exit(Number.isFinite(v)?0:1)" "$value"
}

is_between_node() {
  local value="$1"
  local min="$2"
  local max="$3"
  node -e "const v=Number(process.argv[1]);const mn=Number(process.argv[2]);const mx=Number(process.argv[3]);process.exit(Number.isFinite(v)&&v>=mn&&v<=mx?0:1)" "$value" "$min" "$max"
}

p95_from_values() {
  local values="$1"
  node -e "const vals=process.argv[1].split(',').map(Number).filter(Number.isFinite).sort((a,b)=>a-b); if(!vals.length){process.stdout.write('NaN');process.exit(0)}; const idx=Math.max(0,Math.ceil(vals.length*0.95)-1); process.stdout.write(String(vals[idx]));" "$values"
}

echo "== Strict setup for Level 5 =="
wait_for_url "$BASE_URL/health" 60 || { echo "STOP: gateway is not ready at $BASE_URL"; exit 1; }
wait_for_url "$ETA_URL/health" 60 || { echo "STOP: ETA service is not ready at $ETA_URL"; exit 1; }
wait_for_url "$AI_URL/health" 60 || { echo "STOP: AI service is not ready at $AI_URL"; exit 1; }
wait_for_url "$PRICING_URL/health" 60 || { echo "STOP: Pricing service is not ready at $PRICING_URL"; exit 1; }

USER_TOKEN="$(register_and_login_user "$USER_EMAIL" "$USER_NAME")"
if [[ -n "$USER_TOKEN" ]]; then
  echo "Auth ready: strict script will use gateway where possible."
else
  echo "WARN: cannot get token; strict script will fallback for protected route."
fi

# Case 41
C41=$(call_json_url POST "$ETA_URL/v1/eta/estimate" "" '{"distance_km":5,"traffic_level":0.5}')
C41_STATUS=$(echo "$C41" | sed -n '1p')
C41_BODY=$(echo "$C41" | sed '1d')
C41_ETA=$(echo "$C41_BODY" | json_get "data.eta_minutes")
C41_DISTANCE=$(echo "$C41_BODY" | json_get "data.distance_km")
print_case "Case 41 - ETA range (strict)" "200 + eta > 0 and < 60 + distance positive" "$C41_STATUS" "$C41_BODY"
if [[ "$C41_STATUS" == "200" ]] && is_number_node "$C41_ETA" && node -e "const e=Number(process.argv[1]);const d=Number(process.argv[2]);process.exit(Number.isFinite(e)&&e>0&&e<60&&Number.isFinite(d)&&d>0?0:1)" "$C41_ETA" "$C41_DISTANCE"; then
  mark_result 1 "41"
else
  mark_result 0 "41"
fi

# Case 42
if [[ -n "$USER_TOKEN" ]]; then
  C42=$(call_gateway_json POST "/v1/pricing/estimate" "$USER_TOKEN" '{"distance_km":5,"demand_index":2}')
else
  C42=$(call_json_url POST "$PRICING_URL/v1/pricing/estimate" "" '{"distance_km":5,"demand_index":2}' "x-internal-key" "$INTERNAL_API_KEY")
fi
C42_STATUS=$(echo "$C42" | sed -n '1p')
C42_BODY=$(echo "$C42" | sed '1d')
C42_SURGE=$(echo "$C42_BODY" | json_get "data.surge")
print_case "Case 42 - Surge strict" "200 + surge > 1 when demand is high" "$C42_STATUS" "$C42_BODY"
if [[ "$C42_STATUS" == "200" ]] && node -e "const s=Number(process.argv[1]);process.exit(Number.isFinite(s)&&s>1?0:1)" "$C42_SURGE"; then
  mark_result 1 "42"
else
  mark_result 0 "42"
fi

# Case 43
C43=$(call_json_url POST "$AI_URL/v1/ai/fraud-score" "" '{"user_id":"u1","driver_id":"d1","booking_id":"b1","amount":350000,"route_risk":0.9}')
C43_STATUS=$(echo "$C43" | sed -n '1p')
C43_BODY=$(echo "$C43" | sed '1d')
C43_SCORE=$(echo "$C43_BODY" | json_get "data.fraud_score")
C43_THRESHOLD=$(echo "$C43_BODY" | json_get "data.threshold")
C43_FLAGGED=$(echo "$C43_BODY" | json_get "data.flagged")
C43_MODEL=$(echo "$C43_BODY" | json_get "data.model_version")
print_case "Case 43 - Fraud strict" "200 + score>threshold + flagged=true + model_version" "$C43_STATUS" "$C43_BODY"
if [[ "$C43_STATUS" == "200" ]] && [[ "$C43_FLAGGED" == "true" ]] && [[ -n "$C43_MODEL" ]] && node -e "const s=Number(process.argv[1]);const t=Number(process.argv[2]);process.exit(Number.isFinite(s)&&Number.isFinite(t)&&s>t?0:1)" "$C43_SCORE" "$C43_THRESHOLD"; then
  mark_result 1 "43"
else
  mark_result 0 "43"
fi

# Case 44
C44=$(call_json_url POST "$AI_URL/v1/ai/recommend-drivers" "" '{"pickup":{"lat":10.76,"lng":106.66},"vehicle_type":"CAR","candidates":[{"driver_id":"d1","distance_m":500,"rating":4.8,"eta_min":3,"price_score":0.9,"online":true},{"driver_id":"d2","distance_m":1200,"rating":4.6,"eta_min":8,"price_score":0.8,"online":true},{"driver_id":"d3","distance_m":300,"rating":4.7,"eta_min":2,"price_score":0.95,"online":true},{"driver_id":"d4","distance_m":100,"rating":4.9,"eta_min":1,"price_score":0.9,"online":false}]}')
C44_STATUS=$(echo "$C44" | sed -n '1p')
C44_BODY=$(echo "$C44" | sed '1d')
print_case "Case 44 - Recommendation strict" "200 + top_3 returns 3 drivers" "$C44_STATUS" "$C44_BODY"
if [[ "$C44_STATUS" == "200" ]] && node - <<'NODE' "$C44_BODY"
const j = JSON.parse(process.argv[2]);
const d = j?.data || {};
const top = Array.isArray(d.top_3) ? d.top_3 : [];
const ids = top.map((it) => it?.driver_id || it?.driverId).filter(Boolean);
const ok = top.length === 3 && ids.length === 3;
process.exit(ok ? 0 : 1);
NODE
then
  mark_result 1 "44"
else
  mark_result 0 "44"
fi

# Case 45 + 46
C45_REQ_TS="2026-04-08T10:00:00Z"
C45=$(call_json_url POST "$AI_URL/v1/ai/forecast-demand" "" "{\"zone_id\":\"HCM_Q1\",\"horizon_min\":30,\"timestamp\":\"$C45_REQ_TS\"}")
C45_STATUS=$(echo "$C45" | sed -n '1p')
C45_BODY=$(echo "$C45" | sed '1d')
C45_ZONE=$(echo "$C45_BODY" | json_get "data.zone_id")
C45_HORIZON=$(echo "$C45_BODY" | json_get "data.horizon_min")
C45_D=$(echo "$C45_BODY" | json_get "data.predicted_demand_index")
C45_S=$(echo "$C45_BODY" | json_get "data.predicted_supply_index")
C45_CONF=$(echo "$C45_BODY" | json_get "data.confidence")
C45_MODEL=$(echo "$C45_BODY" | json_get "data.model_version")
C45_TS=$(echo "$C45_BODY" | json_get "data.timestamp")
C45_VAL=$(echo "$C45_BODY" | json_get "data.value")
print_case "Case 45 - Forecast strict format" "200 + output schema valid (zone_id,horizon_min,timestamp,value,model_version,confidence)" "$C45_STATUS" "$C45_BODY"
if [[ "$C45_STATUS" == "200" ]] && node - <<'NODE' "$C45_BODY"
const body = JSON.parse(process.argv[2]);
const d = body?.data || {};
const ts = Date.parse(String(d.timestamp || ''));
const ok = typeof d.zone_id === 'string'
  && d.zone_id.length > 0
  && Number.isFinite(Number(d.horizon_min))
  && Number(d.horizon_min) > 0
  && Number.isFinite(Number(ts))
  && Number.isFinite(Number(d.value))
  && Number.isFinite(Number(d.predicted_demand_index))
  && Number.isFinite(Number(d.predicted_supply_index))
  && Number.isFinite(Number(d.confidence))
  && Number(d.confidence) >= 0
  && Number(d.confidence) <= 1
  && typeof d.model_version === 'string'
  && d.model_version.length > 0;
process.exit(ok ? 0 : 1);
NODE
then
  mark_result 1 "45"
else
  mark_result 0 "45"
fi

C46_V1=$(call_json_url POST "$AI_URL/v1/ai/forecast-demand" "" "{\"zone_id\":\"HCM_Q1\",\"horizon_min\":30,\"timestamp\":\"$C45_REQ_TS\",\"model_version\":\"forecast-v1\"}")
C46_V1_STATUS=$(echo "$C46_V1" | sed -n '1p')
C46_V1_BODY=$(echo "$C46_V1" | sed '1d')
C46_V1_MODEL=$(echo "$C46_V1_BODY" | json_get "data.model_version")

C46_V2=$(call_json_url POST "$AI_URL/v1/ai/forecast-demand" "" "{\"zone_id\":\"HCM_Q1\",\"horizon_min\":30,\"timestamp\":\"$C45_REQ_TS\",\"model_version\":\"forecast-v2\"}")
C46_V2_STATUS=$(echo "$C46_V2" | sed -n '1p')
C46_V2_BODY=$(echo "$C46_V2" | sed '1d')
C46_V2_MODEL=$(echo "$C46_V2_BODY" | json_get "data.model_version")

C46_OUT=$(node - <<'NODE' "$C46_V1_STATUS" "$C46_V1_MODEL" "$C46_V2_STATUS" "$C46_V2_MODEL"
const s1 = process.argv[2];
const m1 = process.argv[3] || '';
const s2 = process.argv[4];
const m2 = process.argv[5] || '';
const ok = s1 === '200'
  && s2 === '200'
  && m1 === 'forecast-v1'
  && m2 === 'forecast-v2';
process.stdout.write(JSON.stringify({
  status_v1: s1,
  model_v1: m1,
  status_v2: s2,
  model_v2: m2,
  distinct_versions: m1 !== m2,
  ok
}));
NODE
)
print_case "Case 46 - Model version strict" "200 + model_version returned correctly and not mixed" "local-check" "$C46_OUT"
if [[ "$(echo "$C46_OUT" | json_get "ok")" == "true" ]]; then
  mark_result 1 "46"
else
  mark_result 0 "46"
fi

# Case 47 strict p95 latency
LAT_VALUES=""
C47_TIMEOUTS=0
for i in $(seq 1 "$LATENCY_SAMPLES"); do
  SAMPLE_RAW=$(curl -s -X POST "$AI_URL/v1/ai/forecast-demand" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    -H "Content-Type: application/json" \
    -d '{"zone_id":"HCM_Q1","horizon_min":30,"timestamp":"2026-04-08T10:00:00Z"}' \
    -w "\nHTTP_STATUS:%{http_code}\nTIME_TOTAL:%{time_total}" || true)
  SAMPLE_STATUS=$(echo "$SAMPLE_RAW" | sed -n 's/^HTTP_STATUS://p' | tail -n1)
  SAMPLE_TIME_TOTAL=$(echo "$SAMPLE_RAW" | sed -n 's/^TIME_TOTAL://p' | tail -n1)
  if [[ -z "$SAMPLE_STATUS" ]]; then SAMPLE_STATUS="000"; fi
  if [[ "$SAMPLE_STATUS" == "000" ]]; then
    C47_TIMEOUTS=$((C47_TIMEOUTS + 1))
  fi
  if [[ "$SAMPLE_STATUS" == "200" ]]; then
    SAMPLE_LAT=$(node -e "const s=Number(process.argv[1]); if(Number.isFinite(s)&&s>=0){process.stdout.write(String(Math.round(s*1000)))}else{process.stdout.write('NaN')}" "$SAMPLE_TIME_TOTAL")
  else
    SAMPLE_LAT="NaN"
  fi
  if [[ "$SAMPLE_STATUS" == "200" ]] && is_number_node "$SAMPLE_LAT" && node -e "const v=Number(process.argv[1]);process.exit(Number.isFinite(v)&&v>=0?0:1)" "$SAMPLE_LAT"; then
    if [[ -z "$LAT_VALUES" ]]; then
      LAT_VALUES="$SAMPLE_LAT"
    else
      LAT_VALUES="$LAT_VALUES,$SAMPLE_LAT"
    fi
  fi
done
P95_LAT=$(p95_from_values "$LAT_VALUES")
print_case "Case 47 - AI latency strict" "p95 latency < ${LATENCY_LIMIT_MS}ms + no timeout" "200" "{\"p95_latency_ms\":$P95_LAT,\"samples\":$LATENCY_SAMPLES,\"timeouts\":$C47_TIMEOUTS}"
if is_number_node "$P95_LAT" && [[ "$C47_TIMEOUTS" == "0" ]] && node -e "const p=Number(process.argv[1]); const lim=Number(process.argv[2]); process.exit(Number.isFinite(p)&&p<lim?0:1)" "$P95_LAT" "$LATENCY_LIMIT_MS"; then
  mark_result 1 "47"
else
  mark_result 0 "47"
fi

# Case 48
C48=$(call_json_url POST "$AI_URL/v1/ai/drift/check" "" '{"model":"forecast-v1","features":{"hour":23,"rain":1,"demand_index":3}}')
C48_STATUS=$(echo "$C48" | sed -n '1p')
C48_BODY=$(echo "$C48" | sed '1d')
C48_DRIFT=$(echo "$C48_BODY" | json_get "data.drift_detected")
C48_SCORE=$(echo "$C48_BODY" | json_get "data.drift_score")
C48_THRESHOLD=$(echo "$C48_BODY" | json_get "data.threshold")
C48_ALERT=$(echo "$C48_BODY" | json_get "data.alert_triggered")
if [[ -z "$C48_ALERT" ]]; then C48_ALERT=$(echo "$C48_BODY" | json_get "data.alert.triggered"); fi
print_case "Case 48 - Drift strict" "200 + drift=true + score>threshold + alert triggered" "$C48_STATUS" "$C48_BODY"
if [[ "$C48_STATUS" == "200" ]] && [[ "$C48_DRIFT" == "true" ]] && [[ "$C48_ALERT" == "true" ]] && node -e "const s=Number(process.argv[1]);const t=Number(process.argv[2]);process.exit(Number.isFinite(s)&&Number.isFinite(t)&&s>t?0:1)" "$C48_SCORE" "$C48_THRESHOLD"; then
  mark_result 1 "48"
else
  mark_result 0 "48"
fi

# Case 49
C49=$(call_json_url POST "$AI_URL/v1/ai/recommend-drivers" "" '{"simulate_model_error":true,"pickup":{"lat":10.76,"lng":106.66},"vehicle_type":"CAR","candidates":[{"driver_id":"d1","distance_m":500,"rating":4.8,"eta_min":3,"price_score":0.9,"online":true}]}')
C49_STATUS=$(echo "$C49" | sed -n '1p')
C49_BODY=$(echo "$C49" | sed '1d')
C49_FALLBACK=$(echo "$C49_BODY" | json_get "data.fallback_used")
C49_REASON=$(echo "$C49_BODY" | json_get "data.decision_log.reason")
print_case "Case 49 - Fallback strict" "200 + fallback_used=true + fallback reason" "$C49_STATUS" "$C49_BODY"
if [[ "$C49_STATUS" == "200" ]] && [[ "$C49_FALLBACK" == "true" ]] && [[ "$C49_REASON" == fallback_* ]]; then
  mark_result 1 "49"
else
  mark_result 0 "49"
fi

# Case 50 (multiple abnormal payloads)
C50A=$(call_json_url POST "$ETA_URL/v1/eta/estimate" "" '{"distance_km":1000,"traffic_level":0.5}')
C50A_STATUS=$(echo "$C50A" | sed -n '1p')
C50A_BODY=$(echo "$C50A" | sed '1d')
C50A_ETA=$(echo "$C50A_BODY" | json_get "data.eta_minutes")

C50B=$(call_json_url POST "$PRICING_URL/v1/pricing/estimate" "" '{"distance_km":1000,"demand_index":1}' "x-internal-key" "$INTERNAL_API_KEY")
C50B_STATUS=$(echo "$C50B" | sed -n '1p')
C50B_BODY=$(echo "$C50B" | sed '1d')
C50B_PRICE=$(echo "$C50B_BODY" | json_get "data.price")

print_case "Case 50 - Abnormal input strict" "outlier distance=1000km: model does not crash, returns reasonable output or reject (no 5xx)" "$C50A_STATUS/$C50B_STATUS" "$C50A_BODY"$'\n'"$C50B_BODY"
if node -e "const s=process.argv.slice(1).map(Number); const ok=s.every(x=>x>=200&&x<500); process.exit(ok?0:1)" "$C50A_STATUS" "$C50B_STATUS" \
  && ( [[ "$C50A_STATUS" != "200" ]] || node -e "const v=Number(process.argv[1]);process.exit(Number.isFinite(v)&&v>=0?0:1)" "$C50A_ETA" ) \
  && ( [[ "$C50B_STATUS" != "200" ]] || node -e "const v=Number(process.argv[1]);process.exit(Number.isFinite(v)&&v>0?0:1)" "$C50B_PRICE" ); then
  mark_result 1 "50"
else
  mark_result 0 "50"
fi

echo "========== LEVEL 5 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
