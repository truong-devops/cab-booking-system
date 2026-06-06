#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
PAYMENT_URL="${PAYMENT_URL:-http://localhost:42107}"
AUTO_BOOTSTRAP_INFRA="${AUTO_BOOTSTRAP_INFRA:-0}"
UNIQ_TAG="$(date +%s)-$RANDOM"
USER_PASS="${USER_PASS:-123456}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@test.com}"
ADMIN_PASS="${ADMIN_PASS:-secret123}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
BOOKING_POLL_TIMEOUT_SEC="${BOOKING_POLL_TIMEOUT_SEC:-25}"
PAYMENT_PATCH_CONNECT_TIMEOUT="${PAYMENT_PATCH_CONNECT_TIMEOUT:-3}"
PAYMENT_PATCH_MAX_TIME="${PAYMENT_PATCH_MAX_TIME:-12}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

print_usage() {
  cat <<EOF
Usage:
  ./scripts/test-level4-31-40cases.sh [BASE_URL]

Examples:
  ./scripts/test-level4-31-40cases.sh
  ./scripts/test-level4-31-40cases.sh http://localhost:42100

Notes:
  - Default BASE_URL: $DEFAULT_BASE_URL
  - Default AUTO_BOOTSTRAP_INFRA: 0 (khong tu chay 'npm run dev:infra')
  - Set AUTO_BOOTSTRAP_INFRA=1 neu ban muon script tu bootstrap infra
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

wait_for_gateway() {
  local max_wait="${1:-60}"
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

bootstrap_infra_if_needed() {
  if wait_for_gateway 10; then
    return 0
  fi

  if [[ "$AUTO_BOOTSTRAP_INFRA" != "1" ]]; then
    return 1
  fi

  if ! command -v npm >/dev/null 2>&1; then
    return 1
  fi

  echo "Gateway not ready at $BASE_URL. Bootstrapping infra with 'npm run dev:infra'..."
  if ! npm run dev:infra; then
    return 1
  fi

  wait_for_gateway 180
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
  echo "$body" | sed -n '1,40p'
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
  local extra_header_key="${5:-}"
  local extra_header_value="${6:-}"

  local resp
  if [[ "$method" == "GET" ]]; then
    if [[ -n "$extra_header_key" ]]; then
      if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        -H "Authorization: Bearer $token" \
        -H "$extra_header_key: $extra_header_value" \
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
  else
    if [[ -n "$extra_header_key" ]]; then
      if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "$extra_header_key: $extra_header_value" \
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
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "\nHTTP_STATUS:%{http_code}"); then
        resp='{"error":"transport error"}'
        resp="$resp"$'\nHTTP_STATUS:000'
      fi
    fi
  fi

  local status="${resp##*HTTP_STATUS:}"
  local body="${resp%HTTP_STATUS:*}"
  printf '%s\n' "$status"
  printf '%s' "$body"
}

register_and_login_user() {
  local email="$1"
  local name="$2"
  local username_base
  username_base=$(echo "$email" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-40)
  local reg_resp=""
  local reg_status=""
  local reg_body=""
  for _attempt in 1 2 3 4; do
    local candidate_username="${username_base}_$RANDOM"
    reg_resp=$(curl -s -X POST "$BASE_URL/v1/auth/register" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"username\":\"$candidate_username\",\"password\":\"$USER_PASS\",\"name\":\"$name\"}" \
      -w "\nHTTP_STATUS:%{http_code}" || true)
    reg_status="${reg_resp##*HTTP_STATUS:}"
    reg_body="${reg_resp%HTTP_STATUS:*}"
    if [[ "$reg_status" == "201" || "$reg_status" == "200" || "$reg_status" == "409" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "$reg_status" != "201" && "$reg_status" != "409" && "$reg_status" != "200" ]]; then
    echo "[WARN] register failed for $email (status=$reg_status): $reg_body" >&2
  fi

  local login=""
  local login_status=""
  for _attempt in 1 2 3 4 5 6; do
    login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}" \
      -w "\nHTTP_STATUS:%{http_code}" || true)
    login_status="${login##*HTTP_STATUS:}"
    login="${login%HTTP_STATUS:*}"
    if [[ -n "$login" ]] && [[ "$login_status" == "200" ]]; then
      break
    fi

    # Fallback payload format (some auth gateways prefer email field).
    login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}" \
      -w "\nHTTP_STATUS:%{http_code}" || true)
    login_status="${login##*HTTP_STATUS:}"
    login="${login%HTTP_STATUS:*}"
    if [[ -n "$login" ]] && [[ "$login_status" == "200" ]]; then
      break
    fi

    sleep 1
  done
  local token
  token=$(echo "$login" | json_get "tokens.accessToken")
  if [[ -z "$token" ]]; then
    echo "[WARN] login failed for $email (status=${login_status:-unknown}): $login" >&2
  fi
  echo "$token"
}

new_case_user_token() {
  local case_label="$1"
  local email="l4-${case_label}-${UNIQ_TAG}-${RANDOM}@test.com"
  register_and_login_user "$email" "Level4 ${case_label}"
}

ensure_online_driver() {
  local admin_token="$1"
  local fallback_user_token="$2"
  local driver_id=""
  local list_json=""

  list_json=$(curl -s "$BASE_URL/v1/admin/drivers?status=APPROVED&online=ONLINE&limit=1" \
    -H "Authorization: Bearer $admin_token" || true)
  driver_id=$(echo "$list_json" | json_get "data.items.0.id")

  if [[ -z "$driver_id" ]]; then
    list_json=$(curl -s "$BASE_URL/v1/admin/drivers?status=APPROVED&limit=1" \
      -H "Authorization: Bearer $admin_token" || true)
    driver_id=$(echo "$list_json" | json_get "data.items.0.id")
  fi

  if [[ -z "$driver_id" ]]; then
    local drv_email="l4-driver-${UNIQ_TAG}@test.com"
    local drv_name="Level4 Driver ${UNIQ_TAG}"
    local drv_pass="$USER_PASS"

    curl -s -X POST "$BASE_URL/v1/auth/register" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$drv_email\",\"password\":\"$drv_pass\",\"name\":\"$drv_name\",\"role\":\"driver\"}" >/dev/null || true

    local drv_login=""
    drv_login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"identifier\":\"$drv_email\",\"password\":\"$drv_pass\"}" || true)
    if [[ -z "$drv_login" ]]; then
      drv_login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$drv_email\",\"password\":\"$drv_pass\"}" || true)
    fi

    local drv_user_id=""
    drv_user_id=$(echo "$drv_login" | json_get "data.id")
    if [[ -z "$drv_user_id" ]]; then
      drv_user_id=$(echo "$drv_login" | json_get "user.id")
    fi
    if [[ -z "$drv_user_id" ]]; then
      drv_user_id=$(echo "$drv_login" | json_get "id")
    fi

    if [[ -n "$drv_user_id" ]]; then
      local create_resp=""
      create_resp=$(curl -s -X POST "$BASE_URL/v1/admin/drivers" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"userId\":\"$drv_user_id\",\"fullName\":\"$drv_name\",\"phone\":\"0900000000\"}" || true)
      driver_id=$(echo "$create_resp" | json_get "data.driver.id")

      if [[ -n "$driver_id" ]]; then
        curl -s -X PATCH "$BASE_URL/v1/admin/drivers/$driver_id/approve" \
          -H "Authorization: Bearer $admin_token" \
          -H "Content-Type: application/json" \
          -d '{}' >/dev/null || true
      fi
    fi
  fi

  if [[ -z "$driver_id" ]]; then
    echo ""
    return
  fi

  local status_resp=""
  status_resp=$(curl -s -X POST "$BASE_URL/v1/driver/status" \
    -H "Authorization: Bearer $admin_token" \
    -H "Content-Type: application/json" \
    -d "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}" \
    -w "\nHTTP_STATUS:%{http_code}" || true)
  local status_code="${status_resp##*HTTP_STATUS:}"
  if [[ "$status_code" != "200" && "$status_code" != "409" ]]; then
    curl -s -X POST "$BASE_URL/v1/driver/status" \
      -H "Authorization: Bearer $fallback_user_token" \
      -H "Content-Type: application/json" \
      -d "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}" >/dev/null || true
  fi

  echo "$driver_id"
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/level4_saga_helpers.sh"

echo "== Setup tokens and users for Level 4 =="
if ! bootstrap_infra_if_needed; then
  echo "STOP: gateway is not ready at $BASE_URL"
  echo "Manual steps:"
  echo "1) npm run dev:infra"
  echo "2) ./scripts/test-level4-31-40cases.sh"
  exit 1
fi

curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Admin\",\"role\":\"admin\"}" >/dev/null || true

ADMIN_LOGIN=""
ADMIN_LOGIN_STATUS=""
for _attempt in 1 2 3 4 5 6; do
  ADMIN_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
    -w "\nHTTP_STATUS:%{http_code}" || true)
  ADMIN_LOGIN_STATUS="${ADMIN_LOGIN##*HTTP_STATUS:}"
  ADMIN_LOGIN="${ADMIN_LOGIN%HTTP_STATUS:*}"
  if [[ -n "$ADMIN_LOGIN" ]] && [[ "$ADMIN_LOGIN_STATUS" == "200" ]]; then
    break
  fi
  ADMIN_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
    -w "\nHTTP_STATUS:%{http_code}" || true)
  ADMIN_LOGIN_STATUS="${ADMIN_LOGIN##*HTTP_STATUS:}"
  ADMIN_LOGIN="${ADMIN_LOGIN%HTTP_STATUS:*}"
  if [[ -n "$ADMIN_LOGIN" ]] && [[ "$ADMIN_LOGIN_STATUS" == "200" ]]; then
    break
  fi
  sleep 1
done
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | json_get "tokens.accessToken")
if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "STOP: cannot get admin token (status=${ADMIN_LOGIN_STATUS:-unknown})"
  echo "admin login response: $ADMIN_LOGIN"
  exit 1
fi

USER_A_EMAIL="l4-user-a-${UNIQ_TAG}@test.com"
USER_B_EMAIL="l4-user-b-${UNIQ_TAG}@test.com"
USER_A_TOKEN=$(register_and_login_user "$USER_A_EMAIL" "Level4 User A")
USER_B_TOKEN=$(register_and_login_user "$USER_B_EMAIL" "Level4 User B")

if [[ -z "$USER_A_TOKEN" || -z "$USER_B_TOKEN" ]]; then
  echo "STOP: cannot get user tokens"
  echo "USER_A_EMAIL=$USER_A_EMAIL"
  echo "USER_B_EMAIL=$USER_B_EMAIL"
  exit 1
fi

DRIVER_ID=$(ensure_online_driver "$ADMIN_TOKEN" "$USER_A_TOKEN")
if [[ -z "$DRIVER_ID" ]]; then
  echo "WARN: cannot provision ONLINE driver; saga-related cases may fail"
fi

C33_ATOMIC_OK=0
C37_ATOMIC_OK=0

# Case 31: Transaction create booking success
echo "-- Running Case 31"
C31=$(call_json POST "/v1/bookings" "$USER_A_TOKEN" '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}')
C31_STATUS=$(echo "$C31" | sed -n '1p')
C31_BODY=$(echo "$C31" | sed '1d')
C31_BOOKING_STATUS=$(echo "$C31_BODY" | json_get "booking.status")
C31_COMP_APPLIED=$(echo "$C31_BODY" | json_get "integration_flow.compensation.applied")
C31_BOOKING_ID=$(echo "$C31_BODY" | json_get "booking.booking_id")
if [[ -z "$C31_BOOKING_ID" ]]; then
  C31_BOOKING_ID=$(echo "$C31_BODY" | json_get "booking.bookingId")
fi
C31_COMMITTED_STATUS=""
if [[ -n "$C31_BOOKING_ID" ]]; then
  C31_COMMITTED_STATUS=$(get_booking_status "$USER_A_TOKEN" "$C31_BOOKING_ID")
fi
print_case "Case 31 - transaction create success" "201 + status REQUESTED + booking_id exists + DB commit read-after-write + no partial compensation" "$C31_STATUS" "$C31_BODY"
if [[ "$C31_STATUS" == "201" ]] && [[ "$C31_BOOKING_STATUS" == "REQUESTED" ]] && [[ -n "$C31_BOOKING_ID" ]] \
  && [[ "$C31_COMMITTED_STATUS" == "REQUESTED" ]] && [[ "$C31_COMP_APPLIED" != "true" ]]; then
  mark_result 1 "31"
else
  mark_result 0 "31"
fi

# Case 32: Rollback when failure after insert
echo "-- Running Case 32"
C32_BEFORE=$(call_json GET "/v1/bookings" "$USER_B_TOKEN")
C32_BEFORE_STATUS=$(echo "$C32_BEFORE" | sed -n '1p')
C32_BEFORE_BODY=$(echo "$C32_BEFORE" | sed '1d')
C32_BEFORE_COUNT=$(echo "$C32_BEFORE_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const arr=Array.isArray(j.data)?j.data:[];process.stdout.write(String(arr.length));}catch(e){process.stdout.write('0')}})")

C32=$(call_json POST "/v1/bookings" "$USER_B_TOKEN" '{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7702,"lng":106.7002},"vehicleType":"CAR","simulate_tx_failure_after_insert":true}')
C32_STATUS=$(echo "$C32" | sed -n '1p')
C32_BODY=$(echo "$C32" | sed '1d')

C32_AFTER=$(call_json GET "/v1/bookings" "$USER_B_TOKEN")
C32_AFTER_BODY=$(echo "$C32_AFTER" | sed '1d')
C32_AFTER_COUNT=$(echo "$C32_AFTER_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const arr=Array.isArray(j.data)?j.data:[];process.stdout.write(String(arr.length));}catch(e){process.stdout.write('0')}})")

print_case "Case 32 - rollback mid-transaction" "500 + booking count unchanged" "$C32_STATUS" "$C32_BODY"
if [[ "$C32_STATUS" =~ ^5[0-9][0-9]$ ]] && [[ "$C32_BEFORE_COUNT" == "$C32_AFTER_COUNT" ]]; then
  mark_result 1 "32"
else
  mark_result 0 "32"
fi

# Case 33: Payment failure => booking rollback/cancel
echo "-- Running Case 33"
C33_TOKEN=$(new_case_user_token "case33")
if [[ -z "$C33_TOKEN" ]]; then
  print_case "Case 33 - payment failed -> booking cancelled" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "33"
else
  C33_CREATE=$(create_booking_with_payment_init_retry "$C33_TOKEN" '{"pickup":{"lat":10.7603,"lng":106.6603},"drop":{"lat":10.7703,"lng":106.7003},"vehicleType":"CAR","payment_method":"CASH","simulate_payment_timeout":true}' 4 2 || true)
  C33_CREATE_STATUS=$(echo "$C33_CREATE" | sed -n '1p')
  C33_CREATE_BODY=$(echo "$C33_CREATE" | sed '1d')
  C33_BOOKING_ID=$(echo "$C33_CREATE_BODY" | json_get "booking.booking_id")
  if [[ -z "$C33_BOOKING_ID" ]]; then
    C33_BOOKING_ID=$(echo "$C33_CREATE_BODY" | json_get "booking.bookingId")
  fi
  C33_PAYMENT_ID=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.payment.data.data.id")
  C33_FLOW=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.flow")
  C33_COMP_APPLIED=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.compensation.applied")
  C33_COMP_EVENT_TOPIC=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.compensation.published_event.topic")
  C33_PAYMENT_OK=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.payment.ok")
  C33_PAYMENT_HTTP=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.payment.statusCode")
  C33_PAYMENT_ERR=$(echo "$C33_CREATE_BODY" | json_get "integration_flow.payment.error.error")
  C33_BOOKING_STATUS=$(echo "$C33_CREATE_BODY" | json_get "booking.status")

  if [[ -n "$C33_BOOKING_ID" ]]; then
    for _poll in $(seq 1 25); do
      C33_BOOKING_STATUS=$(get_booking_status "$C33_TOKEN" "$C33_BOOKING_ID")
      if [[ "$C33_BOOKING_STATUS" == "CANCELLED" || "$C33_BOOKING_STATUS" == "FAILED" ]]; then
        break
      fi
      sleep 1
    done
  fi

  C33_PAYMENT_STATUS=""
  if [[ -n "$C33_PAYMENT_ID" ]]; then
    C33_PAYMENT_STATUS=$(get_payment_status "$C33_PAYMENT_ID")
  fi

  C33_NO_CHARGE_EVIDENCE=0
  if [[ -n "$C33_PAYMENT_ID" ]]; then
    if [[ "$C33_PAYMENT_STATUS" == "FAILED" || "$C33_PAYMENT_STATUS" == "CANCELLED" || "$C33_PAYMENT_STATUS" == "REFUNDED" ]]; then
      C33_NO_CHARGE_EVIDENCE=1
    fi
  else
    if [[ "$C33_PAYMENT_OK" == "false" ]] && [[ "$C33_PAYMENT_HTTP" =~ ^5[0-9][0-9]$ ]] && [[ -n "$C33_PAYMENT_ERR" ]]; then
      C33_NO_CHARGE_EVIDENCE=1
    fi
  fi

  print_case "Case 33 - payment failed -> booking rollback" "201 + flow partial + compensation applied + booking CANCELLED/FAILED + no charge evidence" "$C33_CREATE_STATUS" "$C33_CREATE_BODY"
  if [[ "$C33_CREATE_STATUS" == "201" ]] \
    && [[ -n "$C33_BOOKING_ID" ]] \
    && [[ "$C33_FLOW" == "partial" ]] \
    && [[ "$C33_COMP_APPLIED" == "true" ]] \
    && [[ "$C33_COMP_EVENT_TOPIC" == "ride.cancelled" ]] \
    && ([[ "$C33_BOOKING_STATUS" == "FAILED" ]] || [[ "$C33_BOOKING_STATUS" == "CANCELLED" ]]) \
    && [[ "$C33_NO_CHARGE_EVIDENCE" == "1" ]]; then
    C33_ATOMIC_OK=1
    mark_result 1 "33"
  else
    echo "Case 33 debug: flow=${C33_FLOW:-} comp=${C33_COMP_APPLIED:-} comp_topic=${C33_COMP_EVENT_TOPIC:-} booking_status=${C33_BOOKING_STATUS:-} payment_id=${C33_PAYMENT_ID:-} payment_ok=${C33_PAYMENT_OK:-} payment_http=${C33_PAYMENT_HTTP:-} payment_status=${C33_PAYMENT_STATUS:-}"
    mark_result 0 "33"
  fi
fi

# Case 34: Idempotent duplicate request
echo "-- Running Case 34"
C34_TOKEN=$(new_case_user_token "case34")
if [[ -z "$C34_TOKEN" ]]; then
  print_case "Case 34 - idempotent duplicate request" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "34"
else
IDEM_KEY_34="idem-l4-34-${UNIQ_TAG}"
C34_1=$(call_json POST "/v1/bookings" "$C34_TOKEN" '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR","payment_method":"CASH"}' "Idempotency-Key" "$IDEM_KEY_34")
C34_2=$(call_json POST "/v1/bookings" "$C34_TOKEN" '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR","payment_method":"CASH"}' "Idempotency-Key" "$IDEM_KEY_34")
C34_1_STATUS=$(echo "$C34_1" | sed -n '1p')
C34_1_BODY=$(echo "$C34_1" | sed '1d')
C34_2_STATUS=$(echo "$C34_2" | sed -n '1p')
C34_2_BODY=$(echo "$C34_2" | sed '1d')
C34_B1=$(echo "$C34_1_BODY" | json_get "booking.booking_id")
if [[ -z "$C34_B1" ]]; then C34_B1=$(echo "$C34_1_BODY" | json_get "booking.bookingId"); fi
C34_B2=$(echo "$C34_2_BODY" | json_get "booking.booking_id")
if [[ -z "$C34_B2" ]]; then C34_B2=$(echo "$C34_2_BODY" | json_get "booking.bookingId"); fi
C34_P1=$(echo "$C34_1_BODY" | json_get "integration_flow.payment.data.data.id")
C34_P2=$(echo "$C34_2_BODY" | json_get "integration_flow.payment.data.data.id")
print_case "Case 34 - idempotent duplicate request" "same booking_id replayed; no duplicate transaction/double charge" "$C34_2_STATUS" "$C34_2_BODY"
if [[ "$C34_1_STATUS" == "201" ]] \
  && ([[ "$C34_2_STATUS" == "200" ]] || [[ "$C34_2_STATUS" == "201" ]]) \
  && [[ -n "$C34_B1" ]] && [[ "$C34_B1" == "$C34_B2" ]] \
  && ([[ -z "$C34_P1" ]] || [[ -z "$C34_P2" ]] || [[ "$C34_P1" == "$C34_P2" ]]); then
  mark_result 1 "34"
else
  mark_result 0 "34"
fi
fi

# Case 35: Concurrent booking race condition
echo "-- Running Case 35"
C35_ISOLATED_RESULT=0
USER_C_EMAIL="l4-user-c-${UNIQ_TAG}@test.com"
USER_C_TOKEN=$(register_and_login_user "$USER_C_EMAIL" "Level4 User C")
if [[ -z "$USER_C_TOKEN" ]]; then
  print_case "Case 35 - concurrent booking race" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "35"
else
  TMP1="/tmp/l4_case35_1_${UNIQ_TAG}.json"
  TMP2="/tmp/l4_case35_2_${UNIQ_TAG}.json"
  (
    call_json POST "/v1/bookings" "$USER_C_TOKEN" '{"pickup":{"lat":10.7605,"lng":106.6605},"drop":{"lat":10.7705,"lng":106.7005},"vehicleType":"CAR"}' > "$TMP1"
  ) &
  P1=$!
  (
    call_json POST "/v1/bookings" "$USER_C_TOKEN" '{"pickup":{"lat":10.7605,"lng":106.6605},"drop":{"lat":10.7705,"lng":106.7005},"vehicleType":"CAR"}' > "$TMP2"
  ) &
  P2=$!
  wait "$P1" || true
  wait "$P2" || true

  R35_1=$(cat "$TMP1")
  R35_2=$(cat "$TMP2")
  R35_1_STATUS=$(echo "$R35_1" | sed -n '1p')
  R35_2_STATUS=$(echo "$R35_2" | sed -n '1p')
  R35_1_BODY=$(echo "$R35_1" | sed '1d')
  R35_2_BODY=$(echo "$R35_2" | sed '1d')
  R35_1_BID=$(echo "$R35_1_BODY" | json_get "booking.booking_id")
  if [[ -z "$R35_1_BID" ]]; then R35_1_BID=$(echo "$R35_1_BODY" | json_get "booking.bookingId"); fi
  R35_2_BID=$(echo "$R35_2_BODY" | json_get "booking.booking_id")
  if [[ -z "$R35_2_BID" ]]; then R35_2_BID=$(echo "$R35_2_BODY" | json_get "booking.bookingId"); fi

  SUCCESS_COUNT=0
  CONFLICT_COUNT=0
  if [[ "$R35_1_STATUS" == "201" ]]; then SUCCESS_COUNT=$((SUCCESS_COUNT + 1)); fi
  if [[ "$R35_2_STATUS" == "201" ]]; then SUCCESS_COUNT=$((SUCCESS_COUNT + 1)); fi
  if [[ "$R35_1_STATUS" == "409" ]]; then CONFLICT_COUNT=$((CONFLICT_COUNT + 1)); fi
  if [[ "$R35_2_STATUS" == "409" ]]; then CONFLICT_COUNT=$((CONFLICT_COUNT + 1)); fi

  print_case "Case 35 - concurrent race condition" "no duplicate booking; conflict/lock resolved or replay same booking" "$R35_1_STATUS/$R35_2_STATUS" "$R35_1_BODY"$'\n'"$R35_2_BODY"
  if ([[ "$SUCCESS_COUNT" -eq 1 ]] && [[ "$CONFLICT_COUNT" -ge 1 ]]) \
    || ([[ "$SUCCESS_COUNT" -eq 2 ]] && [[ -n "$R35_1_BID" ]] && [[ "$R35_1_BID" == "$R35_2_BID" ]]); then
    C35_ISOLATED_RESULT=1
    mark_result 1 "35"
  else
    mark_result 0 "35"
  fi
fi

# Case 36: Saga success flow
echo "-- Running Case 36"
C36_STATUS="000"
C36_BODY='{"error":"case36_not_attempted"}'
C36_FLOW=""
C36_COMP_APPLIED=""
C36_BOOKING_STATUS=""
C36_SUCCESS=0
for _attempt in $(seq 1 6); do
  C36_TOKEN=$(new_case_user_token "case36-a${_attempt}")
  if [[ -z "$C36_TOKEN" ]]; then
    continue
  fi
  C36=$(create_booking_with_payment_init_retry "$C36_TOKEN" '{"pickup":{"lat":10.7606,"lng":106.6606},"drop":{"lat":10.7706,"lng":106.7006},"vehicleType":"CAR","payment_method":"CASH"}' 4 2 || true)
  C36_STATUS=$(echo "$C36" | sed -n '1p')
  C36_BODY=$(echo "$C36" | sed '1d')
  C36_FLOW=$(echo "$C36_BODY" | json_get "integration_flow.flow")
  C36_COMP_APPLIED=$(echo "$C36_BODY" | json_get "integration_flow.compensation.applied")
  C36_BOOKING_STATUS=$(echo "$C36_BODY" | json_get "booking.status")

  C36_BOOKING_ID=$(echo "$C36_BODY" | json_get "booking.booking_id")
  if [[ -z "$C36_BOOKING_ID" ]]; then
    C36_BOOKING_ID=$(echo "$C36_BODY" | json_get "booking.bookingId")
  fi

  C36_PAYMENT_OK=$(echo "$C36_BODY" | json_get "integration_flow.payment.ok")
  C36_NOTI_OK=$(echo "$C36_BODY" | json_get "integration_flow.notification.ok")
  if [[ "$C36_STATUS" == "201" ]] && [[ -n "$C36_BOOKING_ID" ]] && [[ "$C36_BOOKING_STATUS" == "REQUESTED" ]] \
    && [[ "$C36_FLOW" == "success" ]] && [[ "$C36_PAYMENT_OK" == "true" ]] && [[ "$C36_NOTI_OK" == "true" ]] \
    && [[ "$C36_COMP_APPLIED" != "true" ]]; then
    C36_SUCCESS=1
    break
  fi
done
print_case "Case 36 - saga success flow" "201 + booking REQUESTED + flow success + payment ok + notification ok + no compensation" "$C36_STATUS" "$C36_BODY"
if [[ "$C36_SUCCESS" == "1" ]]; then
  mark_result 1 "36"
else
  mark_result 0 "36"
fi

# Case 37: Saga failure + compensation
echo "-- Running Case 37"
C37_TOKEN=$(new_case_user_token "case37")
if [[ -z "$C37_TOKEN" ]]; then
  print_case "Case 37 - saga failure compensation" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "37"
else
  C37_READY=0
  C37_CREATE_STATUS="000"
  C37_CREATE_BODY='{"error":"case37_not_started"}'
  C37_BOOKING_ID=""
  C37_PAYMENT_ID=""
  C37_CREATE_PAYMENT_OK=""
  C37_CREATE_BOOKING_STATUS=""
  for _attempt in $(seq 1 8); do
    C37_CREATE=$(create_booking_with_payment_init_retry "$C37_TOKEN" '{"pickup":{"lat":10.7607,"lng":106.6607},"drop":{"lat":10.7707,"lng":106.7007},"vehicleType":"CAR","payment_method":"CASH"}' 4 2 || true)
    C37_CREATE_STATUS=$(echo "$C37_CREATE" | sed -n '1p')
    C37_CREATE_BODY=$(echo "$C37_CREATE" | sed '1d')
    C37_BOOKING_ID=$(echo "$C37_CREATE_BODY" | json_get "booking.booking_id")
    if [[ -z "$C37_BOOKING_ID" ]]; then
      C37_BOOKING_ID=$(echo "$C37_CREATE_BODY" | json_get "booking.bookingId")
    fi
    C37_PAYMENT_ID=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.data.data.id")
    C37_CREATE_PAYMENT_OK=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.ok")
    C37_CREATE_BOOKING_STATUS=$(echo "$C37_CREATE_BODY" | json_get "booking.status")
    if [[ "$C37_CREATE_STATUS" == "201" ]] \
      && [[ "$C37_CREATE_PAYMENT_OK" == "true" ]] \
      && [[ "$C37_CREATE_BOOKING_STATUS" == "REQUESTED" ]] \
      && [[ -n "$C37_BOOKING_ID" ]] \
      && [[ -n "$C37_PAYMENT_ID" ]]; then
      C37_READY=1
      break
    fi
    sleep 1
  done

  C37_PASS=0
  C37_MODE=""
  C37_RESULT_STATUS="$C37_CREATE_STATUS"
  C37_RESULT_BODY="$C37_CREATE_BODY"

  if [[ "$C37_READY" == "1" ]]; then
    C37_MODE="forced_failure_patch"
    C37_PATCH_STATUS="000"
    C37_PATCH_BODY='{"error":"patch_not_attempted"}'
    C37_PATCH=$(patch_payment_failed_with_retry "$C37_PAYMENT_ID" "simulate_case_37" 6 || true)
    C37_PATCH_STATUS=$(echo "$C37_PATCH" | sed -n '1p')
    C37_PATCH_BODY=$(echo "$C37_PATCH" | sed '1d')
    C37_RESULT_STATUS="$C37_PATCH_STATUS"
    C37_RESULT_BODY="$C37_CREATE_BODY"$'\n'"$C37_PATCH_BODY"

    C37_BOOKING_STATUS=""
    if [[ -n "$C37_BOOKING_ID" ]]; then
      for _poll in $(seq 1 25); do
        C37_BOOKING_STATUS=$(get_booking_status "$C37_TOKEN" "$C37_BOOKING_ID")
        if [[ "$C37_BOOKING_STATUS" == "CANCELLED" || "$C37_BOOKING_STATUS" == "FAILED" ]]; then
          break
        fi
        sleep 1
      done
    fi

    C37_PAYMENT_STATUS=""
    if [[ -n "$C37_PAYMENT_ID" ]]; then
      C37_PAYMENT_STATUS=$(get_payment_status "$C37_PAYMENT_ID")
    fi

    if [[ "$C37_PATCH_STATUS" == "200" ]] \
      && [[ -n "$C37_BOOKING_ID" ]] \
      && ([[ "$C37_BOOKING_STATUS" == "CANCELLED" ]] || [[ "$C37_BOOKING_STATUS" == "FAILED" ]]) \
      && ([[ "$C37_PAYMENT_STATUS" == "FAILED" ]] || [[ "$C37_PAYMENT_STATUS" == "CANCELLED" ]] || [[ "$C37_PAYMENT_STATUS" == "REFUNDED" ]]); then
      C37_PASS=1
    fi
  else
    C37_MODE="simulate_timeout_compensation"
    C37_CREATE=$(create_booking_with_payment_init_retry "$C37_TOKEN" '{"pickup":{"lat":10.76071,"lng":106.66071},"drop":{"lat":10.77071,"lng":106.70071},"vehicleType":"CAR","payment_method":"CASH","simulate_payment_timeout":true}' 4 2 || true)
    C37_CREATE_STATUS=$(echo "$C37_CREATE" | sed -n '1p')
    C37_CREATE_BODY=$(echo "$C37_CREATE" | sed '1d')
    C37_RESULT_STATUS="$C37_CREATE_STATUS"
    C37_RESULT_BODY="$C37_CREATE_BODY"

    C37_BOOKING_ID=$(echo "$C37_CREATE_BODY" | json_get "booking.booking_id")
    if [[ -z "$C37_BOOKING_ID" ]]; then
      C37_BOOKING_ID=$(echo "$C37_CREATE_BODY" | json_get "booking.bookingId")
    fi
    C37_PAYMENT_ID=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.data.data.id")
    C37_FLOW=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.flow")
    C37_PAYMENT_OK=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.ok")
    C37_PAYMENT_HTTP=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.statusCode")
    C37_PAYMENT_ERR=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.payment.error.error")
    C37_COMP_APPLIED=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.compensation.applied")
    C37_COMP_EVENT_TOPIC=$(echo "$C37_CREATE_BODY" | json_get "integration_flow.compensation.published_event.topic")
    C37_BOOKING_STATUS=$(echo "$C37_CREATE_BODY" | json_get "booking.status")

    if [[ -n "$C37_BOOKING_ID" ]]; then
      for _poll in $(seq 1 25); do
        C37_BOOKING_STATUS=$(get_booking_status "$C37_TOKEN" "$C37_BOOKING_ID")
        if [[ "$C37_BOOKING_STATUS" == "CANCELLED" || "$C37_BOOKING_STATUS" == "FAILED" ]]; then
          break
        fi
        sleep 1
      done
    fi

    C37_PAYMENT_STATUS=""
    if [[ -n "$C37_PAYMENT_ID" ]]; then
      C37_PAYMENT_STATUS=$(get_payment_status "$C37_PAYMENT_ID")
    fi

    C37_NO_CHARGE_EVIDENCE=0
    if [[ -n "$C37_PAYMENT_ID" ]]; then
      if [[ "$C37_PAYMENT_STATUS" == "FAILED" || "$C37_PAYMENT_STATUS" == "CANCELLED" || "$C37_PAYMENT_STATUS" == "REFUNDED" ]]; then
        C37_NO_CHARGE_EVIDENCE=1
      fi
    else
      if [[ "$C37_PAYMENT_OK" == "false" ]] && [[ "$C37_PAYMENT_HTTP" =~ ^5[0-9][0-9]$ ]] && [[ -n "$C37_PAYMENT_ERR" ]]; then
        C37_NO_CHARGE_EVIDENCE=1
      fi
    fi

    if [[ "$C37_CREATE_STATUS" == "201" ]] \
      && [[ -n "$C37_BOOKING_ID" ]] \
      && [[ "$C37_FLOW" == "partial" ]] \
      && [[ "$C37_PAYMENT_OK" == "false" ]] \
      && [[ "$C37_COMP_APPLIED" == "true" ]] \
      && [[ "$C37_COMP_EVENT_TOPIC" == "ride.cancelled" ]] \
      && ([[ "$C37_BOOKING_STATUS" == "CANCELLED" ]] || [[ "$C37_BOOKING_STATUS" == "FAILED" ]]) \
      && [[ "$C37_NO_CHARGE_EVIDENCE" == "1" ]]; then
      C37_PASS=1
    fi
  fi

  print_case "Case 37 - saga failure compensation" "payment fail after booking -> compensation applied -> booking CANCELLED/FAILED + refund/no-charge evidence" "$C37_RESULT_STATUS" "$C37_RESULT_BODY"
  if [[ "$C37_PASS" == "1" ]]; then
    C37_ATOMIC_OK=1
    mark_result 1 "37"
  else
    echo "Case 37 debug: mode=${C37_MODE:-} ready=${C37_READY:-0} create_status=${C37_CREATE_STATUS:-} payment_ok=${C37_CREATE_PAYMENT_OK:-} booking_status=${C37_CREATE_BOOKING_STATUS:-} result_status=${C37_RESULT_STATUS:-}"
    mark_result 0 "37"
  fi
fi

# Case 38: Outbox consistency signal
echo "-- Running Case 38"
C38_TOKEN=$(new_case_user_token "case38")
if [[ -z "$C38_TOKEN" ]]; then
  print_case "Case 38 - outbox consistency" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "38"
else
  C38=$(call_json POST "/v1/bookings" "$C38_TOKEN" '{"pickup":{"lat":10.7608,"lng":106.6608},"drop":{"lat":10.7708,"lng":106.7008},"vehicleType":"CAR"}')
  C38_STATUS=$(echo "$C38" | sed -n '1p')
  C38_BODY=$(echo "$C38" | sed '1d')
  C38_BOOKING_ID=$(echo "$C38_BODY" | json_get "booking.booking_id")
  if [[ -z "$C38_BOOKING_ID" ]]; then C38_BOOKING_ID=$(echo "$C38_BODY" | json_get "booking.bookingId"); fi
  C38_BOOKING_STATUS=$(echo "$C38_BODY" | json_get "booking.status")
  C38_COMMITTED_STATUS=""
  if [[ -n "$C38_BOOKING_ID" ]]; then
    C38_COMMITTED_STATUS=$(get_booking_status "$C38_TOKEN" "$C38_BOOKING_ID")
  fi
  C38_MAIN_TOPIC=$(echo "$C38_BODY" | json_get "publishedEvent.topic")
  C38_MAIN_QUEUED=$(echo "$C38_BODY" | json_get "publishedEvent.queued")
  C38_ADD_QUEUED=$(echo "$C38_BODY" | json_get "additionalEvents.0.queued")
  C38_ADD_TOPIC=$(echo "$C38_BODY" | json_get "additionalEvents.0.topic")
  C38_ADD_EVENT=$(echo "$C38_BODY" | json_get "additionalEvents.0.eventType")
  C38_MAIN_EVENT_ID=$(echo "$C38_BODY" | json_get "publishedEvent.eventId")
  C38_ADD_EVENT_ID=$(echo "$C38_BODY" | json_get "additionalEvents.0.eventId")
  C38_MAIN_EVENT_ID_UUID=0
  if node -e "const s='$C38_MAIN_EVENT_ID';process.exit(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)?0:1)"; then
    C38_MAIN_EVENT_ID_UUID=1
  fi
  C38_ADD_EVENT_ID_UUID=0
  if node -e "const s='$C38_ADD_EVENT_ID';process.exit(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)?0:1)"; then
    C38_ADD_EVENT_ID_UUID=1
  fi
  print_case "Case 38 - outbox consistency" "201 + booking REQUESTED persisted + publishedEvent ride.created + additional ride_requested on ride_events + distinct UUID eventIds" "$C38_STATUS" "$C38_BODY"
  if [[ "$C38_STATUS" == "201" ]] && [[ -n "$C38_BOOKING_ID" ]] && [[ "$C38_BOOKING_STATUS" == "REQUESTED" ]] \
    && [[ "$C38_COMMITTED_STATUS" == "REQUESTED" ]] \
    && [[ "$C38_MAIN_TOPIC" == "ride.created" ]] \
    && [[ "$C38_MAIN_QUEUED" == "true" ]] && [[ "$C38_ADD_QUEUED" == "true" ]] \
    && [[ "$C38_ADD_TOPIC" == "ride_events" ]] && [[ "$C38_ADD_EVENT" == "ride_requested" ]] \
    && [[ -n "$C38_MAIN_EVENT_ID" ]] && [[ -n "$C38_ADD_EVENT_ID" ]] \
    && [[ "$C38_MAIN_EVENT_ID" != "$C38_ADD_EVENT_ID" ]] \
    && [[ "$C38_MAIN_EVENT_ID_UUID" == "1" ]] && [[ "$C38_ADD_EVENT_ID_UUID" == "1" ]]; then
    mark_result 1 "38"
  else
    mark_result 0 "38"
  fi
fi

# Case 39: Partial failure network issue with retry/fallback
echo "-- Running Case 39"
C39_TOKEN=$(new_case_user_token "case39")
if [[ -z "$C39_TOKEN" ]]; then
  print_case "Case 39 - partial failure payment timeout" "need user token" "000" '{"error":"no token"}'
  mark_result 0 "39"
else
  C39=$(call_json POST "/v1/bookings" "$C39_TOKEN" '{"pickup":{"lat":10.7609,"lng":106.6609},"drop":{"lat":10.7709,"lng":106.7009},"vehicleType":"CAR","payment_method":"CASH","simulate_payment_timeout":true}')
  C39_STATUS=$(echo "$C39" | sed -n '1p')
  C39_BODY=$(echo "$C39" | sed '1d')
  C39_BOOKING_ID=$(echo "$C39_BODY" | json_get "booking.booking_id")
  if [[ -z "$C39_BOOKING_ID" ]]; then C39_BOOKING_ID=$(echo "$C39_BODY" | json_get "booking.bookingId"); fi
  C39_BOOKING_STATUS=$(echo "$C39_BODY" | json_get "booking.status")
  C39_FLOW=$(echo "$C39_BODY" | json_get "integration_flow.flow")
  C39_PAYMENT_OK=$(echo "$C39_BODY" | json_get "integration_flow.payment.ok")
  C39_PAYMENT_HTTP=$(echo "$C39_BODY" | json_get "integration_flow.payment.statusCode")
  C39_COMP_APPLIED=$(echo "$C39_BODY" | json_get "integration_flow.compensation.applied")
  if [[ "$C39_FLOW" == "partial" ]] && [[ -n "$C39_BOOKING_ID" ]]; then
    for _poll in $(seq 1 25); do
      C39_BOOKING_STATUS=$(get_booking_status "$C39_TOKEN" "$C39_BOOKING_ID")
      if [[ "$C39_BOOKING_STATUS" == "CANCELLED" || "$C39_BOOKING_STATUS" == "FAILED" ]]; then
        break
      fi
      sleep 1
    done
  fi
  print_case "Case 39 - partial failure payment timeout" "201 + terminal consistent state (success REQUESTED or compensated CANCELLED/FAILED, khong bi ket state)" "$C39_STATUS" "$C39_BODY"
  if [[ "$C39_STATUS" == "201" ]] && (
    ([[ "$C39_FLOW" == "success" ]] && [[ "$C39_PAYMENT_OK" == "true" ]] && [[ "$C39_BOOKING_STATUS" == "REQUESTED" ]]) \
    || ([[ "$C39_FLOW" == "partial" ]] && [[ "$C39_PAYMENT_OK" == "false" ]] && [[ "$C39_PAYMENT_HTTP" =~ ^5[0-9][0-9]$ ]] \
      && [[ "$C39_COMP_APPLIED" == "true" ]] && ([[ "$C39_BOOKING_STATUS" == "CANCELLED" ]] || [[ "$C39_BOOKING_STATUS" == "FAILED" ]]))
  ); then
    mark_result 1 "39"
  else
    mark_result 0 "39"
  fi
fi

# Case 40: ACID summary check
echo "-- Running Case 40"
C40_ATOMIC=0
if [[ "${C33_ATOMIC_OK:-0}" -eq 1 || "${C37_ATOMIC_OK:-0}" -eq 1 ]]; then
  C40_ATOMIC=1
fi

C40_CONSISTENT=0
C40_TOKEN=$(new_case_user_token "case40")
if [[ -z "$C40_TOKEN" ]]; then
  C40_INVALID_STATUS="000"
else
  C40_INVALID=$(call_json POST "/v1/bookings" "$C40_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"distance_km":-1}')
  C40_INVALID_STATUS=$(echo "$C40_INVALID" | sed -n '1p')
fi
if [[ "$C40_INVALID_STATUS" == "400" || "$C40_INVALID_STATUS" == "422" ]]; then
  C40_CONSISTENT=1
fi

C40_ISOLATED=0
if [[ "${C35_ISOLATED_RESULT:-0}" -eq 1 ]]; then
  C40_ISOLATED=1
fi

C40_DURABLE=0
C40_DURABLE_STATUS=""
if [[ -n "$C31_BOOKING_ID" ]]; then
  C40_DURABLE_STATUS=$(get_booking_status "$USER_A_TOKEN" "$C31_BOOKING_ID")
  if [[ "$C40_DURABLE_STATUS" == "REQUESTED" ]]; then
    C40_DURABLE=1
  fi
fi

ACID_BODY="{\"atomic\":{\"ok\":$C40_ATOMIC,\"scenario\":\"payment fail -> booking rollback/no dangling record (from case33/37)\"},\"consistent\":{\"ok\":$C40_CONSISTENT,\"scenario\":\"invalid data rejected and not committed\"},\"isolated\":{\"ok\":$C40_ISOLATED,\"scenario\":\"concurrent requests do not create duplicate booking\"},\"durable\":{\"ok\":$C40_DURABLE,\"scenario\":\"committed booking can be read back and keep REQUESTED state\",\"status\":\"$C40_DURABLE_STATUS\"}}"
print_case "Case 40 - ACID scenarios" "Atomic(payment fail rollback) + Consistent(invalid data rejected) + Isolated(concurrent no duplicate) + Durable(committed data persists)" "200" "$ACID_BODY"
if [[ "$C40_ATOMIC" == "1" ]] && [[ "$C40_CONSISTENT" == "1" ]] && [[ "$C40_ISOLATED" == "1" ]] && [[ "$C40_DURABLE" == "1" ]]; then
  mark_result 1 "40"
else
  mark_result 0 "40"
fi

echo "========== LEVEL 4 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "====================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
