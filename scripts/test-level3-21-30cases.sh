#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:42100}"
UNIQ_TAG="$(date +%s)-$RANDOM"
USER_EMAIL="${USER_EMAIL:-level3-${UNIQ_TAG}@test.com}"
USER_PASS="${USER_PASS:-123456}"
USER_NAME="${USER_NAME:-Level3 User ${UNIQ_TAG}}"
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
  local max_wait="${1:-45}"
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

json_get() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;if(/^\\d+$/.test(k)){v=Array.isArray(v)?v[Number(k)]:undefined}else{v=v?.[k]}}process.stdout.write(v==null?'':String(v))}catch(e){process.stdout.write('')}})"
}

json_bool() {
  local path="$1"
  local value
  value=$(json_get "$path")
  if [[ "$value" == "true" || "$value" == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
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
  echo "$body" | sed -n '1,30p'
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

  local resp
  if [[ "$method" == "GET" ]]; then
    if ! resp=$(curl -s -X "$method" "$BASE_URL$path" \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H "Authorization: Bearer $token" \
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

  local status="${resp##*HTTP_STATUS:}"
  local body="${resp%HTTP_STATUS:*}"

  printf '%s\n' "$status"
  printf '%s' "$body"
}

ensure_online_driver() {
  local admin_token="$1"
  local user_token="$2"
  local driver_id=""

  local list_json
  list_json=$(curl -s "$BASE_URL/v1/admin/drivers?status=APPROVED&online=ONLINE&limit=1" \
    -H "Authorization: Bearer $admin_token" || true)
  driver_id=$(echo "$list_json" | json_get "data.items.0.id")

  if [[ -z "$driver_id" ]]; then
    list_json=$(curl -s "$BASE_URL/v1/admin/drivers?status=APPROVED&limit=1" \
      -H "Authorization: Bearer $admin_token" || true)
    driver_id=$(echo "$list_json" | json_get "data.items.0.id")
  fi

  if [[ -z "$driver_id" ]]; then
    local drv_email="driver-${UNIQ_TAG}@test.com"
    local drv_pass="123456"

    curl -s -X POST "$BASE_URL/v1/auth/register" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$drv_email\",\"password\":\"$drv_pass\",\"name\":\"Driver $UNIQ_TAG\",\"role\":\"driver\"}" >/dev/null || true

    local drv_login
    drv_login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"identifier\":\"$drv_email\",\"password\":\"$drv_pass\"}" || true)

    local drv_user_id
    drv_user_id=$(echo "$drv_login" | json_get "data.id")

    if [[ -n "$drv_user_id" ]]; then
      local create_resp
      create_resp=$(curl -s -X POST "$BASE_URL/v1/admin/drivers" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"userId\":\"$drv_user_id\",\"fullName\":\"Driver $UNIQ_TAG\",\"phone\":\"0900000000\"}" || true)

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

  local status_resp
  status_resp=$(curl -s -X POST "$BASE_URL/v1/driver/status" \
    -H "Authorization: Bearer $admin_token" \
    -H "Content-Type: application/json" \
    -d "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}" \
    -w "\nHTTP_STATUS:%{http_code}" || true)

  local s_code="${status_resp##*HTTP_STATUS:}"
  if [[ "$s_code" != "200" && "$s_code" != "409" ]]; then
    # fallback: try with user token in case admin route policy differs
    curl -s -X POST "$BASE_URL/v1/driver/status" \
      -H "Authorization: Bearer $user_token" \
      -H "Content-Type: application/json" \
      -d "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}" >/dev/null || true
  fi

  echo "$driver_id"
}

get_available_driver_count() {
  local token="$1"
  local payload
  payload=$(curl -s -X GET "$BASE_URL/v1/driver/availability?lat=10.76&lng=106.66&limit=5" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    -H "Authorization: Bearer $token" || true)
  local count
  count=$(echo "$payload" | json_get "data.count")
  if [[ -z "$count" ]]; then
    echo "0"
    return
  fi
  echo "$count"
}

ensure_available_driver() {
  local admin_token="$1"
  local user_token="$2"
  local driver_id="$3"
  local attempts="${4:-8}"

  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    local available_count
    available_count=$(get_available_driver_count "$user_token")
    if [[ -n "$available_count" ]] && node -e "process.exit(Number('$available_count')>0?0:1)"; then
      return 0
    fi

    if [[ -n "$driver_id" ]]; then
      curl -s -X POST "$BASE_URL/v1/driver/status" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"driver_id\":\"$driver_id\",\"status\":\"OFFLINE\"}" >/dev/null || true

      curl -s -X POST "$BASE_URL/v1/driver/status" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}" >/dev/null || true
    fi

    i=$((i + 1))
    sleep 1
  done

  return 1
}

register_and_login_user() {
  local email="$1"
  local name="$2"

  curl -s -X POST "$BASE_URL/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"user\"}" >/dev/null || true

  local login=""
  local login_status=""
  for _attempt in 1 2 3 4 5 6 7 8; do
    login=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}" \
      -w "\nHTTP_STATUS:%{http_code}" || true)
    login_status="${login##*HTTP_STATUS:}"
    login="${login%HTTP_STATUS:*}"
    if [[ -n "$login" ]] && [[ "$login_status" == "200" ]]; then
      break
    fi

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
  echo "$token"
}

new_case_user_token() {
  local case_label="$1"
  local email="level3-${case_label}-${UNIQ_TAG}-${RANDOM}@test.com"
  register_and_login_user "$email" "Level3 ${case_label}"
}

cancel_booking_if_exists() {
  local token="$1"
  local booking_id="${2:-}"
  if [[ -z "$booking_id" ]]; then
    return 0
  fi
  call_json POST "/v1/bookings/$booking_id/cancel" "$token" '{}' >/dev/null || true
  sleep 1
  return 0
}

wait_notification_record_for_user() {
  local token="$1"
  local user_id="$2"
  local notification_id="$3"
  local max_wait="${4:-8}"
  local i=0
  while [[ "$i" -lt "$max_wait" ]]; do
    local resp status body
    resp=$(call_json GET "/v1/notifications/users/$user_id/notifications?limit=20" "$token")
    status=$(echo "$resp" | sed -n '1p')
    body=$(echo "$resp" | sed '1d')
    if [[ "$status" == "200" ]] && node - <<'NODE' "$body" "$notification_id"
const body = process.argv[2];
const notificationId = process.argv[3];
try {
  const j = JSON.parse(body);
  const items = Array.isArray(j?.data) ? j.data : Array.isArray(j?.data?.items) ? j.data.items : [];
  const ok = items.some((item) => String(item?.id || '') === notificationId);
  process.exit(ok ? 0 : 1);
} catch (_e) {
  process.exit(1);
}
NODE
    then
      echo "$body"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo ""
  return 1
}

echo "== Setup tokens and test data for Level 3 =="
if ! wait_for_gateway 60; then
  echo "STOP: gateway is not ready at $BASE_URL"
  exit 1
fi

curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\",\"name\":\"$USER_NAME\",\"role\":\"user\"}" >/dev/null || true

curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Admin\",\"role\":\"admin\"}" >/dev/null || true

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

ADMIN_LOGIN=""
for _attempt in 1 2 3 4 5 6; do
  ADMIN_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" || true)
  if [[ -n "$ADMIN_LOGIN" ]]; then
    break
  fi
  sleep 1
done
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | json_get "tokens.accessToken")

if [[ -z "$USER_TOKEN" || -z "$ADMIN_TOKEN" ]]; then
  echo "STOP: cannot get user/admin token"
  echo "USER_LOGIN: $USER_LOGIN"
  echo "ADMIN_LOGIN: $ADMIN_LOGIN"
  exit 1
fi

DRIVER_ID=$(ensure_online_driver "$ADMIN_TOKEN" "$USER_TOKEN")
if [[ -z "$DRIVER_ID" ]]; then
  echo "WARN: Could not provision an online driver. Some cases may fail."
fi
if ! ensure_available_driver "$ADMIN_TOKEN" "$USER_TOKEN" "$DRIVER_ID" 10; then
  echo "WARN: Could not ensure available driver inventory near pickup. AI selection cases may fail."
fi

ACTIVE_BOOKING_ID=""

# Case 21
echo "-- Running Case 21"
C21=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicleType":"CAR"}')
C21_STATUS=$(echo "$C21" | sed -n '1p')
C21_BODY=$(echo "$C21" | sed '1d')
C21_ETA=$(echo "$C21_BODY" | json_get "booking.eta_minutes")
if [[ -z "$C21_ETA" ]]; then C21_ETA=$(echo "$C21_BODY" | json_get "booking.etaMinutes"); fi
C21_BOOKING_ID=$(echo "$C21_BODY" | json_get "booking.booking_id")
if [[ -z "$C21_BOOKING_ID" ]]; then C21_BOOKING_ID=$(echo "$C21_BODY" | json_get "booking.bookingId"); fi
C21_ETA_SIGNAL=0
if [[ -n "$C21_ETA" ]] || echo "$C21_BODY" | grep -Eiq '"integration_flow"[[:space:]]*:[[:space:]]*{[^}]*"eta"|"tool_calls"[[:space:]]*:.*"eta"|"agent_tool_calls"[[:space:]]*:.*"eta"|"eta(_minutes|Minutes)"'; then
  C21_ETA_SIGNAL=1
fi
if [[ -n "$C21_BOOKING_ID" ]]; then ACTIVE_BOOKING_ID="$C21_BOOKING_ID"; fi
print_case "Case 21 - booking calls ETA" "200/201 + booking flow shows ETA service result + eta > 0 + no timeout" "$C21_STATUS" "$C21_BODY"
if [[ "$C21_STATUS" == "200" || "$C21_STATUS" == "201" ]] && [[ -n "$C21_BOOKING_ID" ]] && [[ "$C21_ETA_SIGNAL" == "1" ]] && [[ -n "$C21_ETA" ]] && node -e "process.exit(Number('$C21_ETA')>0?0:1)"; then
  mark_result 1 "21"
else
  mark_result 0 "21"
fi

# Case 22
echo "-- Running Case 22"
cancel_booking_if_exists "$USER_TOKEN" "$ACTIVE_BOOKING_ID"
C22=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7702,"lng":106.7002},"vehicleType":"CAR"}')
C22_STATUS=$(echo "$C22" | sed -n '1p')
C22_BODY=$(echo "$C22" | sed '1d')
C22_BOOKING_ID=$(echo "$C22_BODY" | json_get "booking.booking_id")
if [[ -z "$C22_BOOKING_ID" ]]; then C22_BOOKING_ID=$(echo "$C22_BODY" | json_get "booking.bookingId"); fi
if [[ -n "$C22_BOOKING_ID" ]]; then ACTIVE_BOOKING_ID="$C22_BOOKING_ID"; fi
C22_PRICE=$(echo "$C22_BODY" | json_get "booking.priceSnapshot.estimatedFare")
if [[ -z "$C22_PRICE" ]]; then C22_PRICE=$(echo "$C22_BODY" | json_get "booking.price_snapshot.estimatedFare"); fi
C22_SURGE=$(echo "$C22_BODY" | json_get "booking.priceSnapshot.surge")
if [[ -z "$C22_SURGE" ]]; then C22_SURGE=$(echo "$C22_BODY" | json_get "booking.price_snapshot.surge"); fi
C22_PRICING_SIGNAL=0
if [[ -n "$C22_PRICE" ]] || echo "$C22_BODY" | grep -Eiq '"integration_flow"[[:space:]]*:[[:space:]]*{[^}]*"pricing"|"tool_calls"[[:space:]]*:.*"pricing"|"agent_tool_calls"[[:space:]]*:.*"pricing"|"priceSnapshot"|"price_snapshot"'; then
  C22_PRICING_SIGNAL=1
fi
print_case "Case 22 - booking calls pricing" "200/201 + booking flow shows Pricing service result + price > 0 + surge >= 1" "$C22_STATUS" "$C22_BODY"
if [[ "$C22_STATUS" == "200" || "$C22_STATUS" == "201" ]] && [[ -n "$C22_BOOKING_ID" ]] && [[ "$C22_PRICING_SIGNAL" == "1" ]] && [[ -n "$C22_PRICE" ]] && [[ -n "$C22_SURGE" ]] \
  && node -e "process.exit(Number('$C22_PRICE')>0 && Number('$C22_SURGE')>=1 ? 0:1)"; then
  mark_result 1 "22"
else
  mark_result 0 "22"
fi

# Case 23
echo "-- Running Case 23"
C23=$(call_json POST /v1/bookings/ai/select-driver "$USER_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"vehicleType":"CAR"}')
C23_STATUS=$(echo "$C23" | sed -n '1p')
C23_BODY=$(echo "$C23" | sed '1d')
C23_SELECTED=$(echo "$C23_BODY" | json_get "data.selected_driver.driverId")
if [[ -z "$C23_SELECTED" ]]; then C23_SELECTED=$(echo "$C23_BODY" | json_get "data.selected_driver.id"); fi
if [[ -z "$C23_SELECTED" ]]; then C23_SELECTED=$(echo "$C23_BODY" | json_get "data.selected_driver.driver_id"); fi
C23_DECISION_VALID=$(echo "$C23_BODY" | json_bool "data.decision_valid")
C23_IN_LIST_AND_ONLINE=$(echo "$C23_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const s=j?.data?.selected_driver||{};const selected=s.driverId||s.id||s.driver_id||'';const list=Array.isArray(j?.data?.available_drivers)?j.data.available_drivers:[];const found=list.find(it=>((it?.driverId||it?.id||it?.driver_id||''))===selected);if(!selected||!found){process.stdout.write('0');return;}const online=((found.onlineStatus||found.online_status||'ONLINE')+'').toUpperCase();process.stdout.write(online==='ONLINE'?'1':'0')}catch(e){process.stdout.write('0')}})")
print_case "Case 23 - AI selects valid driver" "200 + selected_driver exists, belongs to driver list, and is online" "$C23_STATUS" "$C23_BODY"
if [[ "$C23_STATUS" == "200" ]] && [[ "$C23_DECISION_VALID" == "1" ]] && [[ -n "$C23_SELECTED" ]] && [[ "$C23_IN_LIST_AND_ONLINE" == "1" ]]; then
  mark_result 1 "23"
else
  mark_result 0 "23"
fi

SELECTED_DRIVER_ID="$C23_SELECTED"
if [[ -z "$SELECTED_DRIVER_ID" ]]; then
  SELECTED_DRIVER_ID="$DRIVER_ID"
fi

# Case 24
echo "-- Running Case 24"
cancel_booking_if_exists "$USER_TOKEN" "$ACTIVE_BOOKING_ID"
C24_STATUS="000"
C24_BODY='{"error":"case24_not_attempted"}'
C24_BOOKING_ID=""
C24_PAYMENT_OK="0"
C24_NOTI_OK="0"
C24_FLOW=""
for _attempt in 1 2 3 4; do
  C24=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.7603,"lng":106.6603},"drop":{"lat":10.7703,"lng":106.7003},"vehicleType":"CAR","payment_method":"CASH"}')
  C24_STATUS=$(echo "$C24" | sed -n '1p')
  C24_BODY=$(echo "$C24" | sed '1d')
  C24_BOOKING_ID=$(echo "$C24_BODY" | json_get "booking.booking_id")
  if [[ -z "$C24_BOOKING_ID" ]]; then C24_BOOKING_ID=$(echo "$C24_BODY" | json_get "booking.bookingId"); fi
  C24_PAYMENT_OK=$(echo "$C24_BODY" | json_bool "integration_flow.payment.ok")
  C24_NOTI_OK=$(echo "$C24_BODY" | json_bool "integration_flow.notification.ok")
  C24_FLOW=$(echo "$C24_BODY" | json_get "integration_flow.flow")
  C24_COMP_APPLIED_LOOP=$(echo "$C24_BODY" | json_bool "integration_flow.compensation.applied")
  C24_BOOKING_STATUS_LOOP=$(echo "$C24_BODY" | json_get "booking.status")

  if [[ "$C24_STATUS" == "201" ]] && [[ -n "$C24_BOOKING_ID" ]] && [[ "$C24_PAYMENT_OK" == "1" ]] && [[ "$C24_NOTI_OK" == "1" ]] && [[ "$C24_FLOW" == "success" ]]; then
    ACTIVE_BOOKING_ID="$C24_BOOKING_ID"
    break
  fi
  # Break early when timeout/failure was compensated correctly; no need to retry more.
  if [[ "$C24_STATUS" == "201" ]] && [[ -n "$C24_BOOKING_ID" ]] && [[ "$C24_FLOW" == "partial" ]] && [[ "$C24_NOTI_OK" == "1" ]] && [[ "$C24_COMP_APPLIED_LOOP" == "1" ]] && [[ "$C24_BOOKING_STATUS_LOOP" == "CANCELLED" ]]; then
    ACTIVE_BOOKING_ID="$C24_BOOKING_ID"
    break
  fi
  cancel_booking_if_exists "$USER_TOKEN" "$C24_BOOKING_ID"
  sleep "$_attempt"
done
print_case "Case 24 - Booking -> Payment -> Notification" "201 + flow success" "$C24_STATUS" "$C24_BODY"
if [[ "$C24_STATUS" == "201" ]] && [[ -n "$C24_BOOKING_ID" ]] \
  && [[ "$C24_PAYMENT_OK" == "1" ]] && [[ "$C24_NOTI_OK" == "1" ]] && [[ "$C24_FLOW" == "success" ]]; then
  mark_result 1 "24"
else
  mark_result 0 "24"
fi

# Case 25
echo "-- Running Case 25"
cancel_booking_if_exists "$USER_TOKEN" "$ACTIVE_BOOKING_ID"
C25_TOKEN="$USER_TOKEN"
C25=$(call_json POST /v1/bookings "$C25_TOKEN" '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR"}')
C25_STATUS=$(echo "$C25" | sed -n '1p')
C25_BODY=$(echo "$C25" | sed '1d')
C25_BOOKING_ID=$(echo "$C25_BODY" | json_get "booking.booking_id")
if [[ -z "$C25_BOOKING_ID" ]]; then C25_BOOKING_ID=$(echo "$C25_BODY" | json_get "booking.bookingId"); fi
if [[ -n "$C25_BOOKING_ID" ]]; then ACTIVE_BOOKING_ID="$C25_BOOKING_ID"; fi
C25_TOPIC=$(echo "$C25_BODY" | json_get "additionalEvents.0.topic")
C25_EVENT=$(echo "$C25_BODY" | json_get "additionalEvents.0.eventType")
C25_QUEUED=$(echo "$C25_BODY" | json_bool "additionalEvents.0.queued")
C25_STATUS_VALUE=$(echo "$C25_BODY" | json_get "booking.status")
C25_RIDE_ID=$(echo "$C25_BODY" | json_get "booking.ride_id")
if [[ -z "$C25_RIDE_ID" ]]; then C25_RIDE_ID=$(echo "$C25_BODY" | json_get "booking.rideId"); fi
C25_USER_ID=$(echo "$C25_BODY" | json_get "booking.user_id")
if [[ -z "$C25_USER_ID" ]]; then C25_USER_ID=$(echo "$C25_BODY" | json_get "booking.userId"); fi
C25_PICKUP_LAT=$(echo "$C25_BODY" | json_get "booking.pickup.lat")
if [[ -z "$C25_PICKUP_LAT" ]]; then C25_PICKUP_LAT=$(echo "$C25_BODY" | json_get "booking.pickup_lat"); fi
C25_PICKUP_LNG=$(echo "$C25_BODY" | json_get "booking.pickup.lng")
if [[ -z "$C25_PICKUP_LNG" ]]; then C25_PICKUP_LNG=$(echo "$C25_BODY" | json_get "booking.pickup_lng"); fi
C25_CREATED_AT=$(echo "$C25_BODY" | json_get "booking.created_at")
if [[ -z "$C25_CREATED_AT" ]]; then C25_CREATED_AT=$(echo "$C25_BODY" | json_get "booking.createdAt"); fi
C25_EVENT_ID=$(echo "$C25_BODY" | json_get "additionalEvents.0.eventId")
C25_COORD_TIME_OK=0
if node -e "const lat=Number('$C25_PICKUP_LAT');const lng=Number('$C25_PICKUP_LNG');const ts=Date.parse('$C25_CREATED_AT');process.exit(Number.isFinite(lat)&&Number.isFinite(lng)&&Number.isFinite(ts)?0:1)"; then
  C25_COORD_TIME_OK=1
fi
C25_EVENT_ID_UUID=0
if node -e "const s='$C25_EVENT_ID';process.exit(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)?0:1)"; then
  C25_EVENT_ID_UUID=1
fi
print_case "Case 25 - publish ride_requested" "201 + booking REQUESTED + ride_requested queued on ride_events + payload evidence (booking/ride/user/pickup/timestamp/eventId-uuid)" "$C25_STATUS" "$C25_BODY"
if [[ "$C25_STATUS" == "201" ]] && [[ -n "$C25_BOOKING_ID" ]] && [[ "$C25_STATUS_VALUE" == "REQUESTED" ]] \
  && [[ -n "$C25_RIDE_ID" ]] && [[ -n "$C25_USER_ID" ]] \
  && [[ "$C25_TOPIC" == "ride_events" ]] && [[ "$C25_EVENT" == "ride_requested" ]] && [[ "$C25_QUEUED" == "1" ]] \
  && [[ "$C25_COORD_TIME_OK" == "1" ]] && [[ "$C25_EVENT_ID_UUID" == "1" ]]; then
  mark_result 1 "25"
else
  mark_result 0 "25"
fi

# Case 26 + 27
echo "-- Running Case 26 and Case 27"
if [[ -z "$C25_BOOKING_ID" ]]; then
  C26_STATUS="000"
  C26_BODY='{"error":"missing booking id from case 25"}'
  C27_BEFORE_HTTP="000"
  C27_BEFORE_BODY='{"error":"missing booking id from case 25"}'
  C27_AFTER_HTTP="000"
  C27_AFTER_BODY='{"error":"missing booking id from case 25"}'
else
  C27_BEFORE=$(call_json GET "/v1/bookings/$C25_BOOKING_ID" "$C25_TOKEN")
  C27_BEFORE_HTTP=$(echo "$C27_BEFORE" | sed -n '1p')
  C27_BEFORE_BODY=$(echo "$C27_BEFORE" | sed '1d')
  if [[ "$C27_BEFORE_HTTP" != "200" ]]; then
    C27_BEFORE=$(call_json GET "/v1/bookings/$C25_BOOKING_ID" "$ADMIN_TOKEN")
    C27_BEFORE_HTTP=$(echo "$C27_BEFORE" | sed -n '1p')
    C27_BEFORE_BODY=$(echo "$C27_BEFORE" | sed '1d')
  fi
  # Status transition REQUESTED -> ACCEPTED is privileged in production
  # (driver/admin/service). Use admin token in this integration test.
  C26_TOKEN="$ADMIN_TOKEN"
  START_MS=$(node -e 'process.stdout.write(String(Date.now()))')
  C26=$(call_json PATCH "/v1/bookings/$C25_BOOKING_ID/status" "$C26_TOKEN" "{\"booking_id\":\"$C25_BOOKING_ID\",\"status\":\"ACCEPTED\",\"driver_id\":\"${SELECTED_DRIVER_ID:-driver_fallback}\"}")
  END_MS=$(node -e 'process.stdout.write(String(Date.now()))')
  C26_STATUS=$(echo "$C26" | sed -n '1p')
  C26_BODY=$(echo "$C26" | sed '1d')
  C26_LATENCY_MS=$((END_MS - START_MS))
  C27_AFTER=$(call_json GET "/v1/bookings/$C25_BOOKING_ID" "$C25_TOKEN")
  C27_AFTER_HTTP=$(echo "$C27_AFTER" | sed -n '1p')
  C27_AFTER_BODY=$(echo "$C27_AFTER" | sed '1d')
  if [[ "$C27_AFTER_HTTP" != "200" ]]; then
    C27_AFTER=$(call_json GET "/v1/bookings/$C25_BOOKING_ID" "$ADMIN_TOKEN")
    C27_AFTER_HTTP=$(echo "$C27_AFTER" | sed -n '1p')
    C27_AFTER_BODY=$(echo "$C27_AFTER" | sed '1d')
  fi
fi

C26_NOTI_OK=$(echo "$C26_BODY" | json_bool "notification.ok")
C26_NOTI_STATUS_CODE=$(echo "$C26_BODY" | json_get "notification.statusCode")
C26_NOTI_ID=$(echo "$C26_BODY" | json_get "notification.data.id")
C26_NOTI_USER_ID=$(echo "$C26_BODY" | json_get "notification.data.user_id")
C26_LIST_BODY=""
C26_NOTI_FOUND=0
if [[ -n "$C26_NOTI_ID" ]] && [[ -n "${SELECTED_DRIVER_ID:-}" ]]; then
  C26_LIST_BODY=$(wait_notification_record_for_user "$ADMIN_TOKEN" "$SELECTED_DRIVER_ID" "$C26_NOTI_ID" 8 || true)
  if [[ -n "$C26_LIST_BODY" ]]; then
    C26_NOTI_FOUND=1
  fi
fi
C27_BOOKING_STATUS=$(echo "$C26_BODY" | json_get "booking.status")
C27_EVENT=$(echo "$C26_BODY" | json_get "publishedEvent.eventType")
C27_BEFORE_STATUS=$(echo "$C27_BEFORE_BODY" | json_get "booking.status")
if [[ -z "$C27_BEFORE_STATUS" ]]; then C27_BEFORE_STATUS=$(echo "$C27_BEFORE_BODY" | json_get "data.booking.status"); fi
if [[ -z "$C27_BEFORE_STATUS" ]]; then C27_BEFORE_STATUS=$(echo "$C27_BEFORE_BODY" | json_get "data.status"); fi
if [[ -z "$C27_BEFORE_STATUS" ]]; then C27_BEFORE_STATUS=$(echo "$C27_BEFORE_BODY" | json_get "status"); fi
C27_AFTER_STATUS=$(echo "$C27_AFTER_BODY" | json_get "booking.status")
if [[ -z "$C27_AFTER_STATUS" ]]; then C27_AFTER_STATUS=$(echo "$C27_AFTER_BODY" | json_get "data.booking.status"); fi
if [[ -z "$C27_AFTER_STATUS" ]]; then C27_AFTER_STATUS=$(echo "$C27_AFTER_BODY" | json_get "data.status"); fi
if [[ -z "$C27_AFTER_STATUS" ]]; then C27_AFTER_STATUS=$(echo "$C27_AFTER_BODY" | json_get "status"); fi
print_case "Case 26 - driver notification on assign" "200 + Notification Service stores message for assigned driver + no large delay" "$C26_STATUS" "$C26_BODY"
if [[ "$C26_STATUS" == "200" ]] \
  && [[ "$C26_NOTI_OK" == "1" ]] \
  && [[ "$C26_NOTI_STATUS_CODE" == "200" ]] \
  && [[ -n "$C26_NOTI_ID" ]] \
  && [[ -n "$C26_NOTI_USER_ID" ]] \
  && [[ -n "${SELECTED_DRIVER_ID:-}" ]] \
  && [[ "$C26_NOTI_USER_ID" == "$SELECTED_DRIVER_ID" ]] \
  && [[ "$C26_NOTI_FOUND" == "1" ]] \
  && [[ "${C26_LATENCY_MS:-999999}" -le 5000 ]]; then
  mark_result 1 "26"
else
  mark_result 0 "26"
fi

print_case "Case 27 - status REQUESTED -> ACCEPTED" "200 + pre-check REQUESTED + patch response ACCEPTED + read-back ACCEPTED + ride_accepted" "$C26_STATUS" "$C26_BODY"
if [[ "$C26_STATUS" == "200" ]] \
  && [[ "$C27_BEFORE_HTTP" == "200" ]] && [[ "$C27_AFTER_HTTP" == "200" ]] \
  && [[ "$C27_BEFORE_STATUS" == "REQUESTED" ]] \
  && [[ "$C27_BOOKING_STATUS" == "ACCEPTED" ]] \
  && [[ "$C27_AFTER_STATUS" == "ACCEPTED" ]] \
  && [[ "$C27_EVENT" == "ride_accepted" ]]; then
  mark_result 1 "27"
else
  mark_result 0 "27"
fi

# Case 28
echo "-- Running Case 28"
if [[ -z "$C25_BOOKING_ID" ]]; then
  C28_STATUS="000"
  C28_BODY='{"error":"missing booking id from case 25"}'
else
  C28=$(call_json GET "/v1/bookings/$C25_BOOKING_ID/mcp-context" "$C25_TOKEN")
  C28_STATUS=$(echo "$C28" | sed -n '1p')
  C28_BODY=$(echo "$C28" | sed '1d')
fi
C28_PERMISSION=$(echo "$C28_BODY" | json_bool "data.permission_ok")
C28_ETA=$(echo "$C28_BODY" | json_get "data.eta_minutes")
C28_PRICE=$(echo "$C28_BODY" | json_get "data.pricing.price")
C28_SURGE=$(echo "$C28_BODY" | json_get "data.pricing.surge")
C28_SELECTED=$(echo "$C28_BODY" | json_get "data.selected_driver.driverId")
if [[ -z "$C28_SELECTED" ]]; then C28_SELECTED=$(echo "$C28_BODY" | json_get "data.selected_driver.id"); fi
if [[ -z "$C28_SELECTED" ]]; then C28_SELECTED=$(echo "$C28_BODY" | json_get "data.selected_driver.driver_id"); fi
print_case "Case 28 - MCP context fetch" "200 + context ETA/pricing/driver + permission_ok" "$C28_STATUS" "$C28_BODY"
if [[ "$C28_STATUS" == "200" ]] && [[ "$C28_PERMISSION" == "1" ]] && [[ -n "$C28_SELECTED" ]] \
  && node -e "process.exit(Number('$C28_ETA')>=0 && Number('$C28_PRICE')>0 && Number('$C28_SURGE')>=1 ? 0:1)"; then
  mark_result 1 "28"
else
  mark_result 0 "28"
fi

# Case 29
echo "-- Running Case 29"
cancel_booking_if_exists "$USER_TOKEN" "$ACTIVE_BOOKING_ID"
C29_TOKEN="$USER_TOKEN"
C29=$(call_json POST "/v1/bookings" "$C29_TOKEN" '{"pickup":{"lat":10.7606,"lng":106.6606},"drop":{"lat":10.7706,"lng":106.7006},"vehicleType":"CAR"}')
C29_STATUS=$(echo "$C29" | sed -n '1p')
C29_BODY=$(echo "$C29" | sed '1d')
C29_BOOKING_ID=$(echo "$C29_BODY" | json_get "booking.booking_id")
if [[ -z "$C29_BOOKING_ID" ]]; then C29_BOOKING_ID=$(echo "$C29_BODY" | json_get "booking.bookingId"); fi
if [[ -n "$C29_BOOKING_ID" ]]; then ACTIVE_BOOKING_ID="$C29_BOOKING_ID"; fi
C29_BOOKING_STATUS=$(echo "$C29_BODY" | json_get "booking.status")
C29_PUB_TOPIC=$(echo "$C29_BODY" | json_get "publishedEvent.topic")
C29_PUB_EVENT_ID=$(echo "$C29_BODY" | json_get "publishedEvent.eventId")
C29_PUB_QUEUED=$(echo "$C29_BODY" | json_bool "publishedEvent.queued")
C29_ADD_TOPIC=$(echo "$C29_BODY" | json_get "additionalEvents.0.topic")
C29_ADD_EVENT=$(echo "$C29_BODY" | json_get "additionalEvents.0.eventType")
C29_ADD_QUEUED=$(echo "$C29_BODY" | json_bool "additionalEvents.0.queued")
print_case "Case 29 - API Gateway routes booking correctly" "201 + booking service contract (publishedEvent ride.created + additional ride_requested on ride_events)" "$C29_STATUS" "$C29_BODY"
if [[ "$C29_STATUS" == "201" ]] && [[ -n "$C29_BOOKING_ID" ]] \
  && [[ "$C29_BOOKING_STATUS" == "REQUESTED" ]] \
  && [[ "$C29_PUB_TOPIC" == "ride.created" ]] && [[ -n "$C29_PUB_EVENT_ID" ]] && [[ "$C29_PUB_QUEUED" == "1" ]] \
  && [[ "$C29_ADD_TOPIC" == "ride_events" ]] && [[ "$C29_ADD_EVENT" == "ride_requested" ]] && [[ "$C29_ADD_QUEUED" == "1" ]]; then
  mark_result 1 "29"
else
  mark_result 0 "29"
fi

# Case 30
echo "-- Running Case 30"
cancel_booking_if_exists "$USER_TOKEN" "$ACTIVE_BOOKING_ID"
C30=$(call_json POST /v1/bookings "$USER_TOKEN" '{"pickup":{"lat":10.7605,"lng":106.6605},"drop":{"lat":10.7705,"lng":106.7005},"vehicleType":"CAR","simulate_pricing_timeout":true}')
C30_STATUS=$(echo "$C30" | sed -n '1p')
C30_BODY=$(echo "$C30" | sed '1d')
C30_PRICE=$(echo "$C30_BODY" | json_get "booking.priceSnapshot.estimatedFare")
if [[ -z "$C30_PRICE" ]]; then C30_PRICE=$(echo "$C30_BODY" | json_get "booking.price_snapshot.estimatedFare"); fi
C30_SURGE=$(echo "$C30_BODY" | json_get "booking.priceSnapshot.surge")
if [[ -z "$C30_SURGE" ]]; then C30_SURGE=$(echo "$C30_BODY" | json_get "booking.price_snapshot.surge"); fi
C30_QUOTE_ID=$(echo "$C30_BODY" | json_get "booking.priceSnapshot.quoteId")
if [[ -z "$C30_QUOTE_ID" ]]; then C30_QUOTE_ID=$(echo "$C30_BODY" | json_get "booking.price_snapshot.quoteId"); fi
if [[ -z "$C30_QUOTE_ID" ]]; then C30_QUOTE_ID=$(echo "$C30_BODY" | json_get "booking.price_snapshot.quote_id"); fi
C30_FALLBACK_QUOTE=0
if [[ "$C30_QUOTE_ID" == quote_local_fallback_* ]]; then
  C30_FALLBACK_QUOTE=1
fi
print_case "Case 30 - pricing timeout retry/fallback" "201 + no crash + price > 0 + surge >= 1 + fallback quoteId evidence" "$C30_STATUS" "$C30_BODY"
if [[ "$C30_STATUS" == "201" ]] && [[ -n "$C30_PRICE" ]] && [[ -n "$C30_SURGE" ]] \
  && [[ "$C30_FALLBACK_QUOTE" == "1" ]] \
  && node -e "process.exit(Number('$C30_PRICE')>0 && Number('$C30_SURGE')>=1 ? 0:1)"; then
  mark_result 1 "30"
else
  mark_result 0 "30"
fi

echo "========== LEVEL 3 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
