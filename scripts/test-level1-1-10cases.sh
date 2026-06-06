#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
AUTO_BOOTSTRAP_INFRA="${AUTO_BOOTSTRAP_INFRA:-0}"
UNIQ_TAG="$(date +%s)-$RANDOM"
USER_PASS="${USER_PASS:-123456}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@test.com}"
ADMIN_PASS="${ADMIN_PASS:-secret123}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
CASE10_REVOKE_WAIT_SEC="${CASE10_REVOKE_WAIT_SEC:-25}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

print_usage() {
  cat <<USAGE
Usage:
  ./scripts/test-level1-10cases.sh [BASE_URL]

Examples:
  ./scripts/test-level1-10cases.sh
  ./scripts/test-level1-10cases.sh http://localhost:42100

Notes:
  - Default BASE_URL: $DEFAULT_BASE_URL
  - Default AUTO_BOOTSTRAP_INFRA: 0 (khong tu chay 'npm run dev:infra')
  - Set AUTO_BOOTSTRAP_INFRA=1 neu ban muon script tu bootstrap infra
USAGE
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

contains_text() {
  local needle="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -q --fixed-strings "$needle"
  else
    grep -Fq "$needle"
  fi
}

decode_jwt_payload() {
  local token="$1"
  node -e "const t=process.argv[1]||'';const p=t.split('.')[1]||'';const b=p.replace(/-/g,'+').replace(/_/g,'/');const pad='='.repeat((4-b.length%4)%4);try{process.stdout.write(Buffer.from(b+pad,'base64').toString('utf8'))}catch{process.stdout.write('')}" "$token"
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
  local token="${3:-}"
  local payload="${4:-}"
  local extra_header_key="${5:-}"
  local extra_header_value="${6:-}"

  local -a args
  args=(
    -s -X "$method" "$BASE_URL$path"
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

register_user() {
  local email="$1"
  local name="$2"
  local username_base
  username_base=$(echo "$email" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-40)
  local out='000
{"error":"register_not_attempted"}'
  local attempt=1
  while [[ "$attempt" -le 4 ]]; do
    local candidate_username="${username_base}_$RANDOM"
    out=$(call_json POST "/v1/auth/register" "" "{\"email\":\"$email\",\"username\":\"$candidate_username\",\"password\":\"$USER_PASS\",\"name\":\"$name\"}")
    local status
    status=$(echo "$out" | sed -n '1p')
    if [[ "$status" == "201" || "$status" == "200" || "$status" == "409" ]]; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  printf '%s' "$out"
}

login_user() {
  local email="$1"
  local attempt=1
  local max_attempts="${2:-6}"
  local out='000
{"error":"login_not_attempted"}'

  while [[ "$attempt" -le "$max_attempts" ]]; do
    out=$(call_json POST "/v1/auth/login" "" "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}")
    local status
    status=$(echo "$out" | sed -n '1p')
    if [[ "$status" == "200" ]]; then
      printf '%s' "$out"
      return 0
    fi

    out=$(call_json POST "/v1/auth/login" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}")
    status=$(echo "$out" | sed -n '1p')
    if [[ "$status" == "200" ]]; then
      printf '%s' "$out"
      return 0
    fi

    sleep 1
    attempt=$((attempt + 1))
  done

  printf '%s' "$out"
  return 1
}

extract_access_token() {
  local body="$1"
  echo "$body" | json_get "tokens.accessToken"
}

register_and_login_user() {
  local email="$1"
  local name="$2"

  register_user "$email" "$name" >/dev/null || true
  local login
  login=$(login_user "$email" 8)
  local body
  body=$(echo "$login" | sed '1d')
  extract_access_token "$body"
}

ensure_online_driver() {
  local admin_token="$1"
  local _fallback_user_token="${2:-}"
  local driver_id=""
  local drv_email="l1-driver-${UNIQ_TAG}-${RANDOM}@test.com"
  local drv_name="Level1 Driver ${UNIQ_TAG}"
  local drv_login=""
  local drv_login_body=""
  local drv_token=""
  local drv_user_id=""
  local create_resp=""
  local plate_number="L1-${UNIQ_TAG}-${RANDOM}"

  # Always bootstrap a dedicated driver for this run:
  # register -> create/approve driver profile -> attach vehicle -> go ONLINE.
  call_json POST "/v1/auth/register" "" "{\"email\":\"$drv_email\",\"password\":\"$USER_PASS\",\"name\":\"$drv_name\",\"role\":\"driver\"}" >/dev/null || true

  drv_login=$(login_user "$drv_email" 8)
  drv_login_body=$(echo "$drv_login" | sed '1d')
  drv_token=$(extract_access_token "$drv_login_body")

  drv_user_id=$(echo "$drv_login_body" | json_get "data.id")
  if [[ -z "$drv_user_id" ]]; then drv_user_id=$(echo "$drv_login_body" | json_get "user.id"); fi
  if [[ -z "$drv_user_id" ]]; then drv_user_id=$(echo "$drv_login_body" | json_get "id"); fi
  if [[ -z "$drv_user_id" ]]; then drv_user_id=$(echo "$drv_login_body" | json_get "sub"); fi

  if [[ -n "$drv_user_id" ]]; then
    create_resp=$(curl -s -X POST "$BASE_URL/v1/admin/drivers" \
      -H "Authorization: Bearer $admin_token" \
      -H "Content-Type: application/json" \
      -d "{\"userId\":\"$drv_user_id\",\"fullName\":\"$drv_name\",\"phone\":\"0900000000\"}" || true)
    driver_id=$(echo "$create_resp" | json_get "data.driver.id")
    if [[ -z "$driver_id" ]]; then driver_id=$(echo "$create_resp" | json_get "data.id"); fi
    if [[ -n "$driver_id" ]]; then
      curl -s -X PATCH "$BASE_URL/v1/admin/drivers/$driver_id/approve" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null || true
    fi
  fi

  if [[ -z "$driver_id" ]]; then
    echo ""
    return
  fi

  if [[ -n "$drv_token" ]]; then
    # Enforce production prerequisite before ONLINE.
    call_json PUT "/v1/driver/me/vehicle" "$drv_token" "{\"vehicleType\":\"CAR\",\"plateNumber\":\"$plate_number\"}" >/dev/null || true
  fi

  local online_resp
  online_resp=$(call_json POST "/v1/driver/status" "$admin_token" "{\"driver_id\":\"$driver_id\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}")
  local online_status
  online_status=$(echo "$online_resp" | sed -n '1p')

  echo "$driver_id"
}

new_case_user_token() {
  local case_label="$1"
  local email="l1-${case_label}-${UNIQ_TAG}-${RANDOM}@test.com"
  register_and_login_user "$email" "Level1 ${case_label} ${UNIQ_TAG} ${RANDOM}"
}

echo "== Setup tokens and baseline users for Level 1 =="
if ! bootstrap_infra_if_needed; then
  echo "STOP: gateway is not ready at $BASE_URL"
  echo "Manual steps:"
  echo "1) npm run dev:infra"
  echo "2) ./scripts/test-level1-10cases.sh"
  exit 1
fi

# Ensure admin account exists
call_json POST "/v1/auth/register" "" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Admin\",\"role\":\"admin\"}" >/dev/null || true

ADMIN_LOGIN=$(call_json POST "/v1/auth/login" "" "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
ADMIN_LOGIN_STATUS=$(echo "$ADMIN_LOGIN" | sed -n '1p')
ADMIN_LOGIN_BODY=$(echo "$ADMIN_LOGIN" | sed '1d')
if [[ "$ADMIN_LOGIN_STATUS" != "200" ]]; then
  ADMIN_LOGIN=$(call_json POST "/v1/auth/login" "" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
  ADMIN_LOGIN_STATUS=$(echo "$ADMIN_LOGIN" | sed -n '1p')
  ADMIN_LOGIN_BODY=$(echo "$ADMIN_LOGIN" | sed '1d')
fi

ADMIN_TOKEN=$(extract_access_token "$ADMIN_LOGIN_BODY")
if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "STOP: cannot get admin token"
  echo "$ADMIN_LOGIN_BODY"
  exit 1
fi

# Case 1 + 2 uses same user
L1_USER_EMAIL="level1-user-${UNIQ_TAG}@test.com"
L1_USER_NAME="Level1 User ${UNIQ_TAG}"

# Case 1: Register success
# Expected: 201 + user saved + user_id returned + no validation error
echo "-- Running Case 1"
C1=$(register_user "$L1_USER_EMAIL" "$L1_USER_NAME")
C1_STATUS=$(echo "$C1" | sed -n '1p')
C1_BODY=$(echo "$C1" | sed '1d')
C1_USER_ID=$(echo "$C1_BODY" | json_get "data.user_id")
if [[ -z "$C1_USER_ID" ]]; then C1_USER_ID=$(echo "$C1_BODY" | json_get "data.id"); fi
C1_LOGIN_VERIFY=$(login_user "$L1_USER_EMAIL" 3 || true)
C1_LOGIN_VERIFY_STATUS=$(echo "$C1_LOGIN_VERIFY" | sed -n '1p')
print_case "Case 1 - Đăng ký user thành công" "HTTP 201 Created; User được lưu DB; Trả về user_id; Không có lỗi validation" "$C1_STATUS/$C1_LOGIN_VERIFY_STATUS" "$C1_BODY"
if [[ "$C1_STATUS" == "201" ]] && [[ -n "$C1_USER_ID" ]] && [[ "$C1_LOGIN_VERIFY_STATUS" == "200" ]] && ! echo "$C1_BODY" | contains_text 'VALIDATION_ERROR'; then
  mark_result 1 "1"
else
  mark_result 0 "1"
fi

# Case 2: Login returns valid JWT
echo "-- Running Case 2"
C2=$(login_user "$L1_USER_EMAIL" 8)
C2_STATUS=$(echo "$C2" | sed -n '1p')
C2_BODY=$(echo "$C2" | sed '1d')
C2_TOKEN=$(extract_access_token "$C2_BODY")
C2_PAYLOAD_RAW=""
C2_SUB=""
C2_EXP=""
C2_EXP_VALID=0
if [[ -n "$C2_TOKEN" ]]; then
  C2_PAYLOAD_RAW=$(decode_jwt_payload "$C2_TOKEN")
  C2_SUB=$(echo "$C2_PAYLOAD_RAW" | json_get "sub")
  C2_EXP=$(echo "$C2_PAYLOAD_RAW" | json_get "exp")
  if [[ -n "$C2_EXP" ]] && [[ "$C2_EXP" =~ ^[0-9]+$ ]]; then
    NOW_TS=$(date +%s)
    if (( C2_EXP > NOW_TS )); then
      C2_EXP_VALID=1
    fi
  fi
fi
print_case "Case 2 - Đăng nhập trả JWT hợp lệ" "HTTP 200 OK; Trả về tokens.accessToken (JWT); Token decode hợp lệ (exp, sub)" "$C2_STATUS" "$C2_BODY"
if [[ "$C2_STATUS" == "200" ]] && [[ -n "$C2_TOKEN" ]] && [[ -n "$C2_SUB" ]] && [[ "$C2_EXP_VALID" == "1" ]]; then
  mark_result 1 "2"
else
  echo "Case 2 decoded payload: ${C2_PAYLOAD_RAW:-<empty>}"
  mark_result 0 "2"
fi

if [[ -z "$C2_TOKEN" ]]; then
  echo "STOP: case 2 cannot get token, subsequent auth cases would be invalid"
  exit 1
fi

DRIVER_ID=$(ensure_online_driver "$ADMIN_TOKEN" "$C2_TOKEN")
if [[ -z "$DRIVER_ID" ]]; then
  echo "WARN: cannot ensure ONLINE driver, booking happy-path cases may fail"
fi

# Case 3: Create booking valid input
# Expected: 200/201 + REQUESTED/CONFIRMED + booking_id + eta/pricing success
echo "-- Running Case 3"
C3=$(call_json POST "/v1/bookings" "$C2_TOKEN" '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"distance_km":5}')
C3_STATUS=$(echo "$C3" | sed -n '1p')
C3_BODY=$(echo "$C3" | sed '1d')
C3_BOOKING_ID=$(echo "$C3_BODY" | json_get "booking.booking_id")
if [[ -z "$C3_BOOKING_ID" ]]; then C3_BOOKING_ID=$(echo "$C3_BODY" | json_get "booking.bookingId"); fi
C3_BOOKING_STATUS=$(echo "$C3_BODY" | json_get "booking.status")
C3_ETA=$(echo "$C3_BODY" | json_get "booking.eta_minutes")
if [[ -z "$C3_ETA" ]]; then C3_ETA=$(echo "$C3_BODY" | json_get "booking.etaMinutes"); fi
C3_FARE=$(echo "$C3_BODY" | json_get "booking.priceSnapshot.estimatedFare")
C3_INTEGRATION_OK=0
if [[ -n "$C3_ETA" ]] && [[ -n "$C3_FARE" ]] \
  && node -e "const eta=Number(process.argv[1]);const fare=Number(process.argv[2]);process.exit(Number.isFinite(eta)&&eta>0&&Number.isFinite(fare)&&fare>0?0:1)" "$C3_ETA" "$C3_FARE"; then
  C3_INTEGRATION_OK=1
fi
print_case "Case 3 - Tạo booking với input hợp lệ" "HTTP 200 hoặc 201; status = REQUESTED hoặc CONFIRMED; Có booking_id; Gọi ETA + Pricing thành công" "$C3_STATUS" "$C3_BODY"
if [[ "$C3_STATUS" == "200" || "$C3_STATUS" == "201" ]] && [[ -n "$C3_BOOKING_ID" ]] && ([[ "$C3_BOOKING_STATUS" == "REQUESTED" ]] || [[ "$C3_BOOKING_STATUS" == "CONFIRMED" ]]) && [[ "$C3_INTEGRATION_OK" == "1" ]]; then
  mark_result 1 "3"
else
  mark_result 0 "3"
fi

# Case 4: List bookings by user_id
# Expected: 200 + list with booking_id/status
echo "-- Running Case 4"
C4=$(call_json GET "/v1/bookings?user_id=$C1_USER_ID" "$C2_TOKEN")
C4_STATUS=$(echo "$C4" | sed -n '1p')
C4_BODY=$(echo "$C4" | sed '1d')
C4_COUNT=$(echo "$C4_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const arr=Array.isArray(j.data)?j.data:[];process.stdout.write(String(arr.length));}catch(e){process.stdout.write('0')}})")
C4_ITEM_BOOKING_ID=$(echo "$C4_BODY" | json_get "data.0.booking_id")
if [[ -z "$C4_ITEM_BOOKING_ID" ]]; then C4_ITEM_BOOKING_ID=$(echo "$C4_BODY" | json_get "data.0.bookingId"); fi
C4_ITEM_STATUS=$(echo "$C4_BODY" | json_get "data.0.status")
print_case "Case 4 - Lấy danh sách booking của user" "HTTP 200; Trả về list booking; Mỗi item có booking_id, status" "$C4_STATUS" "$C4_BODY"
if [[ "$C4_STATUS" == "200" ]] && [[ "$C4_COUNT" =~ ^[0-9]+$ ]] && (( C4_COUNT >= 1 )) && [[ -n "$C4_ITEM_BOOKING_ID" ]] && [[ -n "$C4_ITEM_STATUS" ]]; then
  mark_result 1 "4"
else
  mark_result 0 "4"
fi

# Case 5: Driver online status update
# Expected: 200 + status ONLINE
echo "-- Running Case 5"
C5_STATUS="000"
C5_BODY='{"error":"no_driver_id"}'
if [[ -n "$DRIVER_ID" ]]; then
  call_json POST "/v1/driver/status" "$ADMIN_TOKEN" "{\"driver_id\":\"$DRIVER_ID\",\"status\":\"OFFLINE\"}" >/dev/null || true
  C5=$(call_json POST "/v1/driver/status" "$ADMIN_TOKEN" "{\"driver_id\":\"$DRIVER_ID\",\"status\":\"ONLINE\",\"initial_location\":{\"lat\":10.76,\"lng\":106.66}}")
  C5_STATUS=$(echo "$C5" | sed -n '1p')
  C5_BODY=$(echo "$C5" | sed '1d')
fi
C5_DRIVER_STATUS=$(echo "$C5_BODY" | json_get "status")
C5_CAN_RECEIVE=0
C5_AVAIL_STATUS="000"
C5_AVAIL_BODY='{}'
if [[ -n "$C2_TOKEN" ]]; then
  C5_AVAIL=$(call_json GET "/v1/driver/availability?lat=10.76&lng=106.66&limit=5" "$C2_TOKEN")
  C5_AVAIL_STATUS=$(echo "$C5_AVAIL" | sed -n '1p')
  C5_AVAIL_BODY=$(echo "$C5_AVAIL" | sed '1d')
  C5_AVAIL_COUNT=$(echo "$C5_AVAIL_BODY" | json_get "data.count")
  if [[ -z "$C5_AVAIL_COUNT" ]]; then
    C5_AVAIL_COUNT=$(echo "$C5_AVAIL_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const arr=Array.isArray(j?.data?.items)?j.data.items:(Array.isArray(j?.data)?j.data:[]);process.stdout.write(String(arr.length));}catch{process.stdout.write('0')}})")
  fi
  if [[ "$C5_AVAIL_STATUS" == "200" ]] && [[ "$C5_AVAIL_COUNT" =~ ^[0-9]+$ ]] && (( C5_AVAIL_COUNT >= 1 )); then
    C5_CAN_RECEIVE=1
  fi
fi
print_case "Case 5 - Driver chuyển trạng thái online" "HTTP 200; Driver status updated = ONLINE; Có thể nhận booking" "$C5_STATUS/$C5_AVAIL_STATUS" "$C5_BODY"$'\n'"$C5_AVAIL_BODY"
if [[ "$C5_STATUS" == "200" ]] && [[ "$C5_DRIVER_STATUS" == "ONLINE" ]] && [[ "$C5_CAN_RECEIVE" == "1" ]]; then
  mark_result 1 "5"
else
  mark_result 0 "5"
fi

# Case 6: Booking created with REQUESTED + created_at
echo "-- Running Case 6"
C6_TOKEN="$(new_case_user_token "case6")"
if [[ -z "$C6_TOKEN" ]]; then
  C6_STATUS="000"
  C6_BODY='{"error":"cannot_get_case6_token"}'
else
  # Re-check driver readiness right before strict REQUESTED assertion.
  ensure_online_driver "$ADMIN_TOKEN" "$C6_TOKEN" >/dev/null || true
  C6=$(call_json POST "/v1/bookings" "$C6_TOKEN" '{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7702,"lng":106.7002},"distance_km":5}')
  C6_STATUS=$(echo "$C6" | sed -n '1p')
  C6_BODY=$(echo "$C6" | sed '1d')
fi
C6_BOOKING_ID=$(echo "$C6_BODY" | json_get "booking.booking_id")
if [[ -z "$C6_BOOKING_ID" ]]; then C6_BOOKING_ID=$(echo "$C6_BODY" | json_get "booking.bookingId"); fi
C6_BOOKING_STATUS=$(echo "$C6_BODY" | json_get "booking.status")
C6_CREATED_AT=$(echo "$C6_BODY" | json_get "booking.created_at")
if [[ -z "$C6_CREATED_AT" ]]; then C6_CREATED_AT=$(echo "$C6_BODY" | json_get "booking.createdAt"); fi
C6_READ1_STATUS="000"
C6_READ1_BODY='{"error":"booking_id_missing"}'
C6_READ1_BOOKING_STATUS=""
C6_READ2_STATUS="000"
C6_READ2_BODY='{"error":"booking_id_missing"}'
C6_READ2_BOOKING_STATUS=""
if [[ -n "$C6_BOOKING_ID" ]]; then
  C6_READ1=$(call_json GET "/v1/bookings/$C6_BOOKING_ID" "$C6_TOKEN")
  C6_READ1_STATUS=$(echo "$C6_READ1" | sed -n '1p')
  C6_READ1_BODY=$(echo "$C6_READ1" | sed '1d')
  C6_READ1_BOOKING_STATUS=$(echo "$C6_READ1_BODY" | json_get "data.status")
  sleep 1
  C6_READ2=$(call_json GET "/v1/bookings/$C6_BOOKING_ID" "$C6_TOKEN")
  C6_READ2_STATUS=$(echo "$C6_READ2" | sed -n '1p')
  C6_READ2_BODY=$(echo "$C6_READ2" | sed '1d')
  C6_READ2_BOOKING_STATUS=$(echo "$C6_READ2_BODY" | json_get "data.status")
fi
print_case "Case 6 - Booking được tạo với status = REQUESTED" "status ban đầu = REQUESTED; Không bị skip sang trạng thái khác (2 lần read-after-write đều REQUESTED); Có timestamp created_at" "$C6_STATUS/$C6_READ1_STATUS/$C6_READ2_STATUS" "$C6_BODY"$'\n'"$C6_READ1_BODY"$'\n'"$C6_READ2_BODY"
if [[ "$C6_STATUS" == "200" || "$C6_STATUS" == "201" ]] \
  && [[ -n "$C6_BOOKING_ID" ]] \
  && [[ "$C6_BOOKING_STATUS" == "REQUESTED" ]] \
  && [[ -n "$C6_CREATED_AT" ]] \
  && [[ "$C6_READ1_STATUS" == "200" ]] \
  && [[ "$C6_READ2_STATUS" == "200" ]] \
  && [[ "$C6_READ1_BOOKING_STATUS" == "REQUESTED" ]] \
  && [[ "$C6_READ2_BOOKING_STATUS" == "REQUESTED" ]]; then
  mark_result 1 "6"
else
  mark_result 0 "6"
fi

# Case 7: ETA returns >0 and <60
echo "-- Running Case 7"
C7=$(call_json POST "/v1/eta/estimate" "$C2_TOKEN" '{"distance_km":5,"traffic_level":0.5}')
C7_STATUS=$(echo "$C7" | sed -n '1p')
C7_BODY=$(echo "$C7" | sed '1d')
C7_ETA=$(echo "$C7_BODY" | json_get "data.eta_minutes")
C7_ETA_VALID=0
if [[ -n "$C7_ETA" ]] && [[ "$C7_ETA" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  if node -e "const v=Number(process.argv[1]);process.exit(v>0&&v<60?0:1)" "$C7_ETA"; then
    C7_ETA_VALID=1
  fi
fi
print_case "Case 7 - Gọi API ETA trả về giá trị > 0" "HTTP 200; eta > 0; eta hợp lý (ví dụ < 60 phút)" "$C7_STATUS" "$C7_BODY"
if [[ "$C7_STATUS" == "200" ]] && [[ "$C7_ETA_VALID" == "1" ]]; then
  mark_result 1 "7"
else
  mark_result 0 "7"
fi

# Case 8: Pricing returns valid price/surge
echo "-- Running Case 8"
C8=$(call_json POST "/v1/pricing/estimate" "$C2_TOKEN" '{"distance_km":5,"demand_index":1.0}')
C8_STATUS=$(echo "$C8" | sed -n '1p')
C8_BODY=$(echo "$C8" | sed '1d')
C8_PRICE=$(echo "$C8_BODY" | json_get "data.price")
C8_BASE=$(echo "$C8_BODY" | json_get "data.base_fare")
C8_SURGE=$(echo "$C8_BODY" | json_get "data.surge")
C8_VALID=0
if [[ -n "$C8_PRICE" ]] && [[ -n "$C8_BASE" ]] && [[ -n "$C8_SURGE" ]]; then
  if node -e "const p=Number(process.argv[1]);const b=Number(process.argv[2]);const s=Number(process.argv[3]);process.exit(p>b&&s>=1?0:1)" "$C8_PRICE" "$C8_BASE" "$C8_SURGE"; then
    C8_VALID=1
  fi
fi
print_case "Case 8 - Pricing API trả về giá hợp lệ" "HTTP 200; price > base fare; surge >= 1" "$C8_STATUS" "$C8_BODY"
if [[ "$C8_STATUS" == "200" ]] && [[ "$C8_VALID" == "1" ]]; then
  mark_result 1 "8"
else
  mark_result 0 "8"
fi

# Case 9: Notification send success
echo "-- Running Case 9"
C9=$(call_json POST "/v1/notifications" "$C2_TOKEN" "{\"user_id\":\"$C1_USER_ID\",\"message\":\"Your ride is confirmed\"}")
C9_STATUS=$(echo "$C9" | sed -n '1p')
C9_BODY=$(echo "$C9" | sed '1d')
C9_NOTI_ID=$(echo "$C9_BODY" | json_get "id")
C9_NOTI_STATUS=$(echo "$C9_BODY" | json_get "status")
C9_CREATED=$(echo "$C9_BODY" | json_get "created")
C9_CHANNEL_STATUS=$(echo "$C9_BODY" | json_get "perChannelStatus.IN_APP.status")
C9_QUEUE_SIGNAL=0
if [[ -n "$C9_NOTI_ID" || -n "$C9_NOTI_STATUS" || -n "$C9_CHANNEL_STATUS" || "$C9_CREATED" == "true" ]] || echo "$C9_BODY" | grep -Eiq '"perChannelStatus"|"queued"|"PENDING"|"SENT"'; then
  C9_QUEUE_SIGNAL=1
fi
print_case "Case 9 - Notification gửi thành công" "HTTP 200; Notification được gửi (log hoặc queue); Không lỗi timeout" "$C9_STATUS" "$C9_BODY"
if [[ "$C9_STATUS" == "200" ]] && [[ "$C9_QUEUE_SIGNAL" == "1" ]]; then
  mark_result 1 "9"
else
  mark_result 0 "9"
fi

# Case 10: Logout invalidates token
echo "-- Running Case 10"
C10_LOGOUT=$(call_json POST "/v1/auth/logout" "$C2_TOKEN" '{}')
C10_LOGOUT_STATUS=$(echo "$C10_LOGOUT" | sed -n '1p')
C10_LOGOUT_BODY=$(echo "$C10_LOGOUT" | sed '1d')
C10_VERIFY_STATUS="000"
C10_VERIFY_BODY='{"error":"verify_not_attempted"}'
C10_ATTEMPTS=0
C10_REVOKED=0
while [[ "$C10_ATTEMPTS" -lt "$CASE10_REVOKE_WAIT_SEC" ]]; do
  C10_VERIFY=$(call_json GET "/v1/bookings?user_id=$C1_USER_ID" "$C2_TOKEN")
  C10_VERIFY_STATUS=$(echo "$C10_VERIFY" | sed -n '1p')
  C10_VERIFY_BODY=$(echo "$C10_VERIFY" | sed '1d')
  C10_ATTEMPTS=$((C10_ATTEMPTS + 1))
  if [[ "$C10_VERIFY_STATUS" == "401" ]]; then
    C10_REVOKED=1
    break
  fi
  sleep 1
done
print_case "Case 10 - Logout invalidate token" "HTTP 200; Token bị invalidate; Gọi lại API với token cũ -> 401 (trong cửa sổ chờ cache verify)" "$C10_LOGOUT_STATUS/$C10_VERIFY_STATUS" "$C10_LOGOUT_BODY"$'\n'"{\"attempts\":$C10_ATTEMPTS,\"wait_sec\":$CASE10_REVOKE_WAIT_SEC}"$'\n'"$C10_VERIFY_BODY"
if [[ "$C10_LOGOUT_STATUS" == "200" ]] && [[ "$C10_REVOKED" == "1" ]]; then
  mark_result 1 "10"
else
  mark_result 0 "10"
fi

echo "========== LEVEL 1 SUMMARY =========="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "====================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
