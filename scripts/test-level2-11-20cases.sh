#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:42100}"
UNIQ_TAG="$(date +%s)-$RANDOM"
USER_EMAIL="${USER_EMAIL:-level2-${UNIQ_TAG}@test.com}"
USER_PASS="${USER_PASS:-123456}"
USER_NAME="${USER_NAME:-Level2 User ${UNIQ_TAG}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@test.com}"
ADMIN_PASS="${ADMIN_PASS:-secret123}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-25}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

wait_for_gateway() {
  local max_wait="${1:-30}"
  local i=0
  while [[ "$i" -lt "$max_wait" ]]; do
    if curl -s "$BASE_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_for_bookings_upstream() {
  local token="$1"
  local max_wait="${2:-90}"
  local i=0
  while [[ "$i" -lt "$max_wait" ]]; do
    local resp
    if ! resp=$(curl -s -X POST "$BASE_URL/v1/bookings" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d '{"drop":{"lat":10.77,"lng":106.70}}' \
      -w "\nHTTP_STATUS:%{http_code}"); then
      resp='{"error":"transport error"}'
      resp="$resp"$'\nHTTP_STATUS:000'
    fi

    local status="${resp##*HTTP_STATUS:}"
    if [[ "$status" != "502" ]] && [[ "$status" != "000" ]]; then
      return 0
    fi

    i=$((i + 1))
    sleep 1
  done
  return 1
}

json_get() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;v=v?.[k]}process.stdout.write(v==null?'':String(v))}catch(e){process.stdout.write('')}})"
}

json_arr_len() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;v=v?.[k]}process.stdout.write(Array.isArray(v)?String(v.length):'0')}catch(e){process.stdout.write('0')}})"
}

get_booking_count_for_user() {
  local token="$1"
  local resp
  if ! resp=$(curl -s -X GET "$BASE_URL/v1/bookings" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    -H "Authorization: Bearer $token" \
    -w "\nHTTP_STATUS:%{http_code}"); then
    echo "-1"
    return
  fi
  local status="${resp##*HTTP_STATUS:}"
  local body="${resp%HTTP_STATUS:*}"
  if [[ "$status" != "200" ]]; then
    echo "-1"
    return
  fi
  local cnt
  cnt=$(echo "$body" | json_arr_len "data")
  echo "${cnt:-0}"
}

contains_text() {
  local needle="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -q --fixed-strings "$needle"
  else
    grep -Fq "$needle"
  fi
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
  echo "$body" | sed -n '1,25p'
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

call_json() {
  local method="$1"
  local path="$2"
  local token="$3"
  local payload="${4:-}"
  local idem_key="${5:-}"

  local is_body_method=1
  if [[ "$method" == "GET" || "$method" == "HEAD" ]]; then
    is_body_method=0
  fi

  local resp
  if [[ "$is_body_method" == "1" && -n "$idem_key" ]]; then
    if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -H "Idempotency-Key: $idem_key" \
      -d "$payload" \
      -w "\nHTTP_STATUS:%{http_code}"); then
      resp='{"error":"transport error"}'
      resp="$resp"$'\nHTTP_STATUS:000'
    fi
  elif [[ "$is_body_method" == "1" ]]; then
    if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w "\nHTTP_STATUS:%{http_code}"); then
      resp='{"error":"transport error"}'
      resp="$resp"$'\nHTTP_STATUS:000'
    fi
  else
    if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Authorization: Bearer $token" \
      -w "\nHTTP_STATUS:%{http_code}"); then
      resp='{"error":"transport error"}'
      resp="$resp"$'\nHTTP_STATUS:000'
    fi
  fi

  local status="${resp##*HTTP_STATUS:}"
  local body="${resp%HTTP_STATUS:*}"

  printf '%s\n' "$status"
  printf '%s' "$body"
}

echo "== Setup user token =="
if ! wait_for_gateway 45; then
  echo "STOP: gateway is not ready at $BASE_URL"
  exit 1
fi

curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\",\"name\":\"$USER_NAME\"}" >/dev/null || true

USER_LOGIN=""
for _attempt in 1 2 3 4 5 6 7 8; do
  USER_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\"}" || true)
  if [[ -n "$USER_LOGIN" ]]; then
    break
  fi
  sleep 1
done
USER_TOKEN=$(echo "$USER_LOGIN" | json_get "tokens.accessToken")

if [[ -z "$USER_TOKEN" ]]; then
  echo "STOP: cannot get user token"
  echo "$USER_LOGIN"
  exit 1
fi

if ! wait_for_bookings_upstream "$USER_TOKEN" 120; then
  echo "STOP: booking upstream is not ready behind gateway (still returning 502)"
  exit 1
fi

ADMIN_LOGIN=""
for _attempt in 1 2 3 4 5; do
  ADMIN_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" || true)
  if [[ -n "$ADMIN_LOGIN" ]] && [[ -n "$(echo "$ADMIN_LOGIN" | json_get "tokens.accessToken")" ]]; then
    break
  fi
  sleep 1
done
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | json_get "tokens.accessToken")

# Case 11
echo "-- Running Case 11"
C11=$(call_json POST /v1/bookings "$USER_TOKEN" '{"drop":{"lat":10.77,"lng":106.70}}')
C11_STATUS=$(echo "$C11" | sed -n '1p')
C11_BODY=$(echo "$C11" | sed '1d')
C11_BOOKING_ID=$(echo "$C11_BODY" | json_get "booking.booking_id")
if [[ -z "$C11_BOOKING_ID" ]]; then C11_BOOKING_ID=$(echo "$C11_BODY" | json_get "booking.bookingId"); fi
print_case "Case 11 - missing pickup" "400 + message 'pickup is required' + no booking created" "$C11_STATUS" "$C11_BODY"
if [[ "$C11_STATUS" == "400" ]] && echo "$C11_BODY" | contains_text 'pickup is required' && [[ -z "$C11_BOOKING_ID" ]]; then
  mark_result 1 "11"
else
  mark_result 0 "11"
fi

# Case 12
echo "-- Running Case 12"
C12=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":"abc","lng":106.66},"drop":{"lat":10.77,"lng":106.70}}')
C12_STATUS=$(echo "$C12" | sed -n '1p')
C12_BODY=$(echo "$C12" | sed '1d')
C12_BOOKING_ID=$(echo "$C12_BODY" | json_get "booking.booking_id")
if [[ -z "$C12_BOOKING_ID" ]]; then C12_BOOKING_ID=$(echo "$C12_BODY" | json_get "booking.bookingId"); fi
C12_HAS_AI_SIGNALS=0
if echo "$C12_BODY" | grep -Eiq '"ai_driver_decision"|"eta(_minutes)?"|"price(Snapshot)?"|"integration_flow"|"publishedEvent"|"selected_driver"'; then
  C12_HAS_AI_SIGNALS=1
fi
print_case "Case 12 - invalid lat/lng type" "422 + Validation error from schema" "$C12_STATUS" "$C12_BODY"
if [[ "$C12_STATUS" == "422" ]] \
  && echo "$C12_BODY" | contains_text 'Validation error from schema' \
  && [[ -z "$C12_BOOKING_ID" ]] \
  && [[ "$C12_HAS_AI_SIGNALS" == "0" ]]; then
  mark_result 1 "12"
else
  mark_result 0 "12"
fi

# Case 13
echo "-- Running Case 13"
C13=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":21.0278,"lng":105.8342},"drop":{"lat":21.0285,"lng":105.8350},"vehicleType":"CAR"}')
C13_STATUS=$(echo "$C13" | sed -n '1p')
C13_BODY=$(echo "$C13" | sed '1d')
C13_BOOKING_ID=$(echo "$C13_BODY" | json_get "booking.booking_id")
if [[ -z "$C13_BOOKING_ID" ]]; then C13_BOOKING_ID=$(echo "$C13_BODY" | json_get "booking.bookingId"); fi
print_case "Case 13 - no drivers online" "booking status PENDING/FAILED + no assigned driver + message No drivers available" "$C13_STATUS" "$C13_BODY"
C13_BOOKING_STATUS=$(echo "$C13_BODY" | json_get "booking.status")
C13_SELECTED_DRIVER_ID=$(echo "$C13_BODY" | json_get "ai_driver_decision.selected_driver.id")
if [[ -z "$C13_SELECTED_DRIVER_ID" ]]; then C13_SELECTED_DRIVER_ID=$(echo "$C13_BODY" | json_get "ai_driver_decision.selected_driver.driver_id"); fi
if echo "$C13_BODY" | contains_text 'No drivers available' \
  && ([[ "$C13_BOOKING_STATUS" == "PENDING" ]] || [[ "$C13_BOOKING_STATUS" == "FAILED" ]]) \
  && [[ -z "$C13_SELECTED_DRIVER_ID" ]]; then
  mark_result 1 "13"
else
  mark_result 0 "13"
fi

# Case 14
echo "-- Running Case 14"
C14_BOOKINGS_BEFORE=$(get_booking_count_for_user "$USER_TOKEN")
C14=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"payment_method":"invalid_card"}')
C14_STATUS=$(echo "$C14" | sed -n '1p')
C14_BODY=$(echo "$C14" | sed '1d')
C14_BOOKING_ID=$(echo "$C14_BODY" | json_get "booking.booking_id")
if [[ -z "$C14_BOOKING_ID" ]]; then C14_BOOKING_ID=$(echo "$C14_BODY" | json_get "booking.bookingId"); fi
C14_PAYMENT_ID=$(echo "$C14_BODY" | json_get "integration_flow.payment.data.data.id")
if [[ -z "$C14_PAYMENT_ID" ]]; then C14_PAYMENT_ID=$(echo "$C14_BODY" | json_get "payment.id"); fi
C14_BOOKINGS_AFTER=$(get_booking_count_for_user "$USER_TOKEN")
C14_HAS_PAYMENT_SIGNALS=0
if echo "$C14_BODY" | grep -Eiq '"integration_flow"[[:space:]]*:[[:space:]]*{[^}]*"payment"|"payment(_status|Id|_id)?"'; then
  C14_HAS_PAYMENT_SIGNALS=1
fi
C14_BOOKING_UNCHANGED=0
if [[ "$C14_BOOKINGS_BEFORE" =~ ^-?[0-9]+$ ]] && [[ "$C14_BOOKINGS_AFTER" =~ ^-?[0-9]+$ ]] \
  && [[ "$C14_BOOKINGS_BEFORE" != "-1" ]] && [[ "$C14_BOOKINGS_AFTER" != "-1" ]] \
  && [[ "$C14_BOOKINGS_BEFORE" == "$C14_BOOKINGS_AFTER" ]]; then
  C14_BOOKING_UNCHANGED=1
fi
print_case "Case 14 - invalid payment method" "400 + Invalid payment method + Payment Service not called" "$C14_STATUS" "$C14_BODY"
if [[ "$C14_STATUS" == "400" ]] \
  && echo "$C14_BODY" | contains_text 'Invalid payment method' \
  && [[ -z "$C14_BOOKING_ID" ]] \
  && [[ -z "$C14_PAYMENT_ID" ]] \
  && [[ "$C14_HAS_PAYMENT_SIGNALS" == "0" ]] \
  && [[ "$C14_BOOKING_UNCHANGED" == "1" ]]; then
  mark_result 1 "14"
else
  echo "Case 14 debug: before_bookings=$C14_BOOKINGS_BEFORE after_bookings=$C14_BOOKINGS_AFTER booking_id=${C14_BOOKING_ID:-<empty>} payment_id=${C14_PAYMENT_ID:-<empty>} payment_signals=$C14_HAS_PAYMENT_SIGNALS"
  mark_result 0 "14"
fi

# Case 15
echo "-- Running Case 15"
C15=$(call_json POST /v1/eta/estimate "$USER_TOKEN" '{"distance_km":0}')
C15_STATUS=$(echo "$C15" | sed -n '1p')
C15_BODY=$(echo "$C15" | sed '1d')
print_case "Case 15 - ETA distance=0" "200 + eta_minutes >= 0 and very small (prefer 0)" "$C15_STATUS" "$C15_BODY"
ETA_VAL=$(echo "$C15_BODY" | json_get "data.eta_minutes")
if [[ "$C15_STATUS" == "200" ]] && [[ -n "$ETA_VAL" ]] && node -e "const v=Number(process.argv[1]);process.exit(Number.isFinite(v)&&v>=0&&v<=1?0:1)" "$ETA_VAL"; then
  mark_result 1 "15"
else
  mark_result 0 "15"
fi

# Case 16
echo "-- Running Case 16"
C16=$(call_json POST /v1/pricing/estimate "$USER_TOKEN" '{"distance_km":5,"demand_index":0,"supply_index":1}')
C16_STATUS=$(echo "$C16" | sed -n '1p')
C16_BODY=$(echo "$C16" | sed '1d')
print_case "Case 16 - pricing demand=0" "200 + surge >= 1 + valid price > 0 (no divide-by-zero behavior)" "$C16_STATUS" "$C16_BODY"
SURGE_VAL=$(echo "$C16_BODY" | json_get "data.surge")
PRICE_VAL=$(echo "$C16_BODY" | json_get "data.price")
if [[ "$C16_STATUS" == "200" ]] && [[ -n "$SURGE_VAL" ]] && [[ -n "$PRICE_VAL" ]] \
  && node -e "const s=Number(process.argv[1]);const p=Number(process.argv[2]);process.exit(Number.isFinite(s)&&s>=1&&Number.isFinite(p)&&p>0?0:1)" "$SURGE_VAL" "$PRICE_VAL"; then
  mark_result 1 "16"
else
  mark_result 0 "16"
fi

# Case 17
echo "-- Running Case 17"
C17=$(call_json POST /v1/fraud/check "$USER_TOKEN" '{"user_id":"USR123"}')
C17_STATUS=$(echo "$C17" | sed -n '1p')
C17_BODY=$(echo "$C17" | sed '1d')
C17_SCORE=$(echo "$C17_BODY" | json_get "data.score")
if [[ -z "$C17_SCORE" ]]; then C17_SCORE=$(echo "$C17_BODY" | json_get "data.risk_score"); fi
C17_FLAGGED=$(echo "$C17_BODY" | json_get "data.flagged")
C17_MODEL_VERSION=$(echo "$C17_BODY" | json_get "data.model_version")
C17_HAS_MODEL_SIGNALS=0
if echo "$C17_BODY" | grep -Eiq '"(score|risk_score|flagged|model_version|modelVersion|decision_log|tool_calls|latency_ms)"'; then
  C17_HAS_MODEL_SIGNALS=1
fi
print_case "Case 17 - fraud missing fields" "400 + missing required fields + model not run" "$C17_STATUS" "$C17_BODY"
if [[ "$C17_STATUS" == "400" ]] \
  && echo "$C17_BODY" | contains_text 'missing required fields' \
  && [[ -z "$C17_SCORE" ]] \
  && [[ -z "$C17_FLAGGED" ]] \
  && [[ -z "$C17_MODEL_VERSION" ]] \
  && [[ "$C17_HAS_MODEL_SIGNALS" == "0" ]]; then
  mark_result 1 "17"
else
  mark_result 0 "17"
fi

# Case 18
echo "-- Running Case 18"
JWT_SECRET_VAL=$(grep -E '^JWT_SECRET=' .env | head -n1 | cut -d'=' -f2- || true)
if [[ -z "$JWT_SECRET_VAL" ]]; then
  JWT_SECRET_VAL="dev-secret"
fi
EXPIRED_TOKEN="expired_token"
if [[ -n "$JWT_SECRET_VAL" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    EXPIRED_TOKEN=$(JWT_SECRET="$JWT_SECRET_VAL" python3 - <<'PY'
import base64
import hashlib
import hmac
import json
import os
import time

secret = os.environ.get("JWT_SECRET", "")
now = int(time.time())
header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "sub": "expired-user",
    "role": "user",
    "roles": ["user"],
    "iat": now - 7200,
    "exp": now - 3600,
}

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

header_b64 = b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
payload_b64 = b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
unsigned = f"{header_b64}.{payload_b64}"
signature = hmac.new(secret.encode("utf-8"), unsigned.encode("utf-8"), hashlib.sha256).digest()
print(f"{unsigned}.{b64url(signature)}", end="")
PY
)
  fi
fi
C18=$(call_json POST /v1/bookings "$EXPIRED_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70}}')
C18_STATUS=$(echo "$C18" | sed -n '1p')
C18_BODY=$(echo "$C18" | sed '1d')
print_case "Case 18 - expired token" "401 + Token expired" "$C18_STATUS" "$C18_BODY"
if [[ "$C18_STATUS" == "401" ]] && echo "$C18_BODY" | contains_text 'Token expired'; then mark_result 1 "18"; else mark_result 0 "18"; fi

# Case 19
echo "-- Running Case 19"
IDEM_KEY="idem-${UNIQ_TAG}"
if [[ -n "${C13_BOOKING_ID:-}" ]]; then
  call_json POST "/v1/bookings/$C13_BOOKING_ID/cancel" "$USER_TOKEN" '{}' >/dev/null || true
  sleep 1
fi
C19A=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}' "$IDEM_KEY")
C19A_STATUS=$(echo "$C19A" | sed -n '1p')
C19A_BODY=$(echo "$C19A" | sed '1d')
C19B=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}' "$IDEM_KEY")
C19B_STATUS=$(echo "$C19B" | sed -n '1p')
C19B_BODY=$(echo "$C19B" | sed '1d')
C19A_ID=$(echo "$C19A_BODY" | json_get "booking.booking_id")
if [[ -z "$C19A_ID" ]]; then C19A_ID=$(echo "$C19A_BODY" | json_get "booking.bookingId"); fi
C19B_ID=$(echo "$C19B_BODY" | json_get "booking.booking_id")
if [[ -z "$C19B_ID" ]]; then C19B_ID=$(echo "$C19B_BODY" | json_get "booking.bookingId"); fi

C19_DETAIL=$(cat <<EOF
First status: $C19A_STATUS booking_id: $C19A_ID
Second status: $C19B_STATUS booking_id: $C19B_ID
EOF
)
print_case "Case 19 - duplicate booking/idempotency" "Only 1 booking is created; second request returns replayed result; no duplicate" "$C19A_STATUS/$C19B_STATUS" "$C19_DETAIL"
if [[ "$C19A_STATUS" == "201" ]] \
  && ([[ "$C19B_STATUS" == "200" ]] || [[ "$C19B_STATUS" == "201" ]]) \
  && [[ -n "$C19A_ID" ]] && [[ "$C19A_ID" == "$C19B_ID" ]]; then
  mark_result 1 "19"
else
  mark_result 0 "19"
fi

# Case 20
echo "-- Running Case 20"
C20_BEFORE_COUNT=$(get_booking_count_for_user "$USER_TOKEN")
TMP_CASE20_DIR="${TMPDIR:-./tmp}"
mkdir -p "$TMP_CASE20_DIR"
TMP_CASE20_FILE="$TMP_CASE20_DIR/level2_case20_${UNIQ_TAG}.json"
node -e 'const fs=require("fs");const payload={pickup:{lat:10.76,lng:106.66},drop:{lat:10.77,lng:106.70},huge:"x".repeat(1200000)};fs.writeFileSync(process.argv[1],JSON.stringify(payload));' "$TMP_CASE20_FILE"
RESP20=$(curl -s -X POST "$BASE_URL/v1/bookings" \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_MAX_TIME" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @"$TMP_CASE20_FILE" \
  -w "\nHTTP_STATUS:%{http_code}")
rm -f "$TMP_CASE20_FILE"
C20_STATUS="${RESP20##*HTTP_STATUS:}"
C20_BODY="${RESP20%HTTP_STATUS:*}"
C20_AFTER_COUNT=$(get_booking_count_for_user "$USER_TOKEN")
C20_BOOKING_ID=$(echo "$C20_BODY" | json_get "booking.booking_id")
if [[ -z "$C20_BOOKING_ID" ]]; then C20_BOOKING_ID=$(echo "$C20_BODY" | json_get "booking.bookingId"); fi
print_case "Case 20 - payload too large" "413 Payload Too Large" "$C20_STATUS" "$C20_BODY"
if [[ "$C20_STATUS" == "413" ]] \
  && [[ -z "$C20_BOOKING_ID" ]] \
  && [[ "$C20_BEFORE_COUNT" != "-1" ]] \
  && [[ "$C20_AFTER_COUNT" != "-1" ]] \
  && [[ "$C20_BEFORE_COUNT" == "$C20_AFTER_COUNT" ]]; then
  mark_result 1 "20"
else
  mark_result 0 "20"
fi

echo "========== LEVEL 2 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
