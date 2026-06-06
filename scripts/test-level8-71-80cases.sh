#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
BOOKING_URL="${BOOKING_URL:-http://localhost:42104}"
DRIVER_URL="${DRIVER_URL:-http://localhost:42110}"
PRICING_URL="${PRICING_URL:-http://localhost:42106}"
ETA_URL="${ETA_URL:-http://localhost:42111}"
COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.dev.yml}"
INTERNAL_API_KEY="${INTERNAL_API_KEY:-dev-internal-key}"
USER_PASS="${USER_PASS:-123456}"
UNIQ_TAG="$(date +%s)-$RANDOM"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
FAULT_SETTLE_SEC="${FAULT_SETTLE_SEC:-3}"

CASE74_RECOVERY_TIMEOUT_SEC="${CASE74_RECOVERY_TIMEOUT_SEC:-120}"
CASE74_ENABLE="${CASE74_ENABLE:-1}"
CASE75_FAIL_FAST_MS="${CASE75_FAIL_FAST_MS:-5000}"
CASE77_BASE_MS="${CASE77_BASE_MS:-1000}"
CASE77_MAX_MS="${CASE77_MAX_MS:-8000}"
CASE79_RECOVERY_WAIT_SEC="${CASE79_RECOVERY_WAIT_SEC:-45}"
AUTH_BOOTSTRAP_ATTEMPTS="${AUTH_BOOTSTRAP_ATTEMPTS:-20}"
AUTH_BOOTSTRAP_RETRY_DELAY_SEC="${AUTH_BOOTSTRAP_RETRY_DELAY_SEC:-3}"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

COMPOSE_AVAILABLE=0
COMPOSE_MODE="none"

print_usage() {
  cat <<USAGE
Usage:
  ./scripts/test-level8-71-80cases.sh [BASE_URL]

Examples:
  ./scripts/test-level8-71-80cases.sh
  ./scripts/test-level8-71-80cases.sh http://localhost:42100

Notes:
  - Default BASE_URL: $DEFAULT_BASE_URL
  - Case 74 is strict by default (enabled). If disabled or missing evidence, it fails.
  - Infra fault injection cases require Docker Compose and $COMPOSE_FILE.
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

http_status() {
  local url="$1"
  curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" || echo "000"
}

json_get() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for(const k of '$path'.split('.')){if(!k)continue;if(/^\\d+$/.test(k)){v=Array.isArray(v)?v[Number(k)]:v?.[k]}else{v=v?.[k]}}process.stdout.write(v==null?'':String(v))}catch(e){process.stdout.write('')}})"
}

now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
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
  echo "$input" | sed -n '1,140p'
  echo "Expected: $expected"
  echo "Actual status: $status"
  echo "Actual body:"
  echo "$body" | sed -n '1,180p'
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

mark_no_evidence_fail() {
  local case_id="$1"
  local reason="$2"
  echo "[$case_id] NO_EVIDENCE - $reason"
  mark_result 0 "$case_id"
}

call_json_url() {
  local method="$1"
  local url="$2"
  local token="${3:-}"
  local payload="${4:-}"
  local h1k="${5:-}"
  local h1v="${6:-}"
  local h2k="${7:-}"
  local h2v="${8:-}"

  local -a args
  args=(
    -s -X "$method" "$url"
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
  )

  if [[ -n "$token" ]]; then
    args+=( -H "Authorization: Bearer $token" )
  fi
  if [[ -n "$h1k" ]]; then
    args+=( -H "$h1k: $h1v" )
  fi
  if [[ -n "$h2k" ]]; then
    args+=( -H "$h2k: $h2v" )
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

call_gateway_json() {
  local method="$1"
  local path="$2"
  local token="${3:-}"
  local payload="${4:-}"
  local h1k="${5:-}"
  local h1v="${6:-}"
  local h2k="${7:-}"
  local h2v="${8:-}"
  call_json_url "$method" "$BASE_URL$path" "$token" "$payload" "$h1k" "$h1v" "$h2k" "$h2v"
}

extract_access_token() {
  local body="$1"
  echo "$body" | json_get "tokens.accessToken"
}

register_and_login_user() {
  local email="$1"
  local name="$2"

  call_gateway_json POST "/v1/auth/register" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"user\"}" >/dev/null || true

  local attempts="$AUTH_BOOTSTRAP_ATTEMPTS"
  local i=1
  while [[ "$i" -le "$attempts" ]]; do
    local login
    local status
    local body

    login=$(call_gateway_json POST "/v1/auth/login" "" "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
    status=$(echo "$login" | sed -n '1p')
    body=$(echo "$login" | sed '1d')
    if [[ "$status" == "429" ]]; then
      sleep "$AUTH_BOOTSTRAP_RETRY_DELAY_SEC"
      i=$((i + 1))
      continue
    fi
    if [[ "$status" != "200" ]]; then
      login=$(call_gateway_json POST "/v1/auth/login" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
      status=$(echo "$login" | sed -n '1p')
      body=$(echo "$login" | sed '1d')
      if [[ "$status" == "429" ]]; then
        sleep "$AUTH_BOOTSTRAP_RETRY_DELAY_SEC"
        i=$((i + 1))
        continue
      fi
    fi

    local token
    token=$(extract_access_token "$body")
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi

    sleep "$AUTH_BOOTSTRAP_RETRY_DELAY_SEC"
    i=$((i + 1))
  done

  echo ""
}

new_user_token() {
  local case_id="$1"
  local email="level8-${case_id}-${UNIQ_TAG}-${RANDOM}@test.com"
  local name="Level8 Case ${case_id} ${UNIQ_TAG}"
  register_and_login_user "$email" "$name"
}

has_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_AVAILABLE=1
    COMPOSE_MODE="docker-compose-v2"
    return 0
  fi
  if docker-compose version >/dev/null 2>&1; then
    COMPOSE_AVAILABLE=1
    COMPOSE_MODE="docker-compose"
    return 0
  fi
  COMPOSE_AVAILABLE=0
  COMPOSE_MODE="none"
  return 1
}

compose_cmd() {
  if [[ "$COMPOSE_MODE" == "docker-compose" ]]; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

stop_services() {
  local services="$1"
  local s
  for s in $services; do
    compose_cmd stop "$s" >/dev/null 2>&1 || true
  done
  sleep "$FAULT_SETTLE_SEC"
}

start_services() {
  local services="$1"
  local s
  for s in $services; do
    compose_cmd start "$s" >/dev/null 2>&1 || true
  done
}

pause_services() {
  local services="$1"
  local s
  for s in $services; do
    compose_cmd pause "$s" >/dev/null 2>&1 || return 1
  done
  sleep "$FAULT_SETTLE_SEC"
  return 0
}

unpause_services() {
  local services="$1"
  local s
  for s in $services; do
    compose_cmd unpause "$s" >/dev/null 2>&1 || true
  done
}

ensure_core_ready() {
  local max_wait="${1:-90}"
  local i=0

  while [[ "$i" -lt "$max_wait" ]]; do
    local gateway_ok="0"
    local booking_ok="0"
    local auth_ok="0"

    if wait_for_url "$BASE_URL/health" 1; then gateway_ok="1"; fi
    if wait_for_url "$BOOKING_URL/health" 1; then booking_ok="1"; fi

    local auth_status
    local auth_probe
    auth_status=$(http_status "$BASE_URL/v1/auth/health")
    if [[ "$auth_status" != "200" ]]; then
      auth_status=$(http_status "$BASE_URL/v1/auth/healthz")
    fi
    if [[ "$auth_status" != "200" ]]; then
      auth_status=$(http_status "$BASE_URL/v1/auth/readyz")
    fi
    if [[ "$auth_status" != "200" ]]; then
      auth_probe=$(call_gateway_json POST "/v1/auth/login" "" '{"identifier":"readiness_probe","password":"invalid"}' || true)
      auth_status=$(echo "$auth_probe" | sed -n '1p')
    fi
    if [[ "$auth_status" == "200" || "$auth_status" == "400" || "$auth_status" == "401" || "$auth_status" == "429" ]]; then
      auth_ok="1"
    fi

    if [[ "$gateway_ok" == "1" && "$booking_ok" == "1" && "$auth_ok" == "1" ]]; then
      return 0
    fi

    i=$((i + 1))
    sleep 1
  done

  return 1
}

recover_core_stack() {
  if [[ "$COMPOSE_AVAILABLE" != "1" ]]; then
    return 1
  fi

  start_services "api-gateway booking-service auth-service postgres redis pricing-service eta-service driver-service kafka"
  ensure_core_ready 120
}

require_compose_or_skip() {
  local case_id="$1"
  local reason="$2"
  if [[ "$COMPOSE_AVAILABLE" != "1" ]]; then
    if [[ "$case_id" =~ ^[0-9]+$ ]]; then
      mark_no_evidence_fail "$case_id" "$reason"
    fi
    return 1
  fi
  return 0
}

ensure_ready_or_skip() {
  local case_id="$1"
  local reason="$2"
  if ensure_core_ready 30; then
    return 0
  fi
  if recover_core_stack; then
    return 0
  fi
  if [[ "$case_id" =~ ^[0-9]+$ ]]; then
    mark_no_evidence_fail "$case_id" "$reason"
  fi
  return 1
}

cleanup() {
  if [[ "$COMPOSE_AVAILABLE" == "1" ]]; then
    unpause_services "driver-service eta-service pricing-service kafka" || true
    start_services "driver-service eta-service pricing-service kafka auth-service booking-service api-gateway postgres redis" || true
  fi
}
trap cleanup EXIT

create_booking_payload='{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","distance_km":5,"traffic_level":0.5}'

echo "== Setup for Level 8 failure & resilience =="
has_docker_compose || true
if [[ "$COMPOSE_AVAILABLE" == "1" ]]; then
  echo "Docker Compose detected ($COMPOSE_MODE). Fault injection cases are enabled."
else
  echo "WARN: Docker Compose not found. Infra fault injection cases will fail as NO_EVIDENCE (strict mode)."
fi

if ! ensure_ready_or_skip "setup" "core services not healthy before test run"; then
  echo "STOP: cannot ensure core stack readiness"
  exit 1
fi

# Case 71: Driver service down -> fallback
if require_compose_or_skip "71" "requires docker compose fault injection" && ensure_ready_or_skip "71" "core services unhealthy before case 71"; then
  C71_TOKEN="$(new_user_token 71)"
  if [[ -z "$C71_TOKEN" ]]; then
    mark_no_evidence_fail "71" "cannot get auth token while testing driver fallback"
  else
    stop_services "driver-service"

    C71=$(call_gateway_json POST "/v1/bookings" "$C71_TOKEN" "$create_booking_payload")
    C71_STATUS=$(echo "$C71" | sed -n '1p')
    C71_BODY=$(echo "$C71" | sed '1d')
    C71_BOOKING_ID=$(echo "$C71_BODY" | json_get "booking.booking_id")
    if [[ -z "$C71_BOOKING_ID" ]]; then C71_BOOKING_ID=$(echo "$C71_BODY" | json_get "booking.bookingId"); fi
    C71_BOOKING_STATUS=$(echo "$C71_BODY" | json_get "booking.status")

    print_case "Case 71 - Driver service down -> fallback" \
      "Fault: stop driver-service; Payload: $create_booking_payload" \
      "booking flow does not crash: status in {200,201} + booking_id exists + booking status still valid (REQUESTED/PENDING/CONFIRMED)" \
      "$C71_STATUS" "$C71_BODY"

    if [[ "$C71_STATUS" == "200" || "$C71_STATUS" == "201" ]] && [[ -n "$C71_BOOKING_ID" ]] && [[ "$C71_BOOKING_STATUS" == "REQUESTED" || "$C71_BOOKING_STATUS" == "PENDING" || "$C71_BOOKING_STATUS" == "CONFIRMED" ]]; then
      mark_result 1 "71"
    else
      mark_result 0 "71"
    fi

    start_services "driver-service"
    ensure_ready_or_skip "71-post" "core services unhealthy after case 71" >/dev/null || true
  fi
fi

# Case 72: Pricing service timeout -> retry/fallback
if require_compose_or_skip "72" "requires docker compose fault injection" && ensure_ready_or_skip "72" "core services unhealthy before case 72"; then
  stop_services "pricing-service"

  C72_TOKEN="$(new_user_token 72)"
  if [[ -z "$C72_TOKEN" ]]; then
    mark_no_evidence_fail "72" "cannot get auth token while testing pricing fallback"
  else
    C72_T0=$(now_ms)
    C72=$(call_gateway_json POST "/v1/bookings" "$C72_TOKEN" "$create_booking_payload")
    C72_T1=$(now_ms)
    C72_STATUS=$(echo "$C72" | sed -n '1p')
    C72_BODY=$(echo "$C72" | sed '1d')
    C72_BOOKING_ID=$(echo "$C72_BODY" | json_get "booking.booking_id")
    if [[ -z "$C72_BOOKING_ID" ]]; then C72_BOOKING_ID=$(echo "$C72_BODY" | json_get "booking.bookingId"); fi
    C72_QUOTE_ID=$(echo "$C72_BODY" | json_get "booking.priceSnapshot.quoteId")
    C72_FALLBACK_USED=$(echo "$C72_BODY" | json_get "booking.priceSnapshot.fallbackUsed")
    C72_PRICE_TOTAL=$(echo "$C72_BODY" | json_get "booking.priceSnapshot.total")
    if [[ -z "$C72_PRICE_TOTAL" ]]; then C72_PRICE_TOTAL=$(echo "$C72_BODY" | json_get "booking.price.total"); fi
    C72_ELAPSED=$((C72_T1 - C72_T0))

    print_case "Case 72 - Pricing timeout -> retry + fallback" \
      "Fault: stop pricing-service; Payload: $create_booking_payload" \
      "booking flow still succeeds (no total failure): status in {200,201} + booking_id exists + pricing handled by retry OR fallback/default value" \
      "$C72_STATUS" "$C72_BODY"

    if [[ "$C72_STATUS" == "200" || "$C72_STATUS" == "201" ]] && [[ -n "$C72_BOOKING_ID" ]] \
      && ( [[ "$C72_QUOTE_ID" == quote_local_fallback_* ]] || [[ "$C72_FALLBACK_USED" == "true" ]] || node -e "const n=Number(process.argv[1]);process.exit(Number.isFinite(n)&&n>=0?0:1)" "${C72_PRICE_TOTAL:-NaN}" ); then
      mark_result 1 "72"
    else
      echo "[72] detail: elapsed_ms=$C72_ELAPSED quote_id=$C72_QUOTE_ID fallback_used=$C72_FALLBACK_USED price_total=$C72_PRICE_TOTAL"
      mark_result 0 "72"
    fi
  fi

  start_services "pricing-service"
  ensure_ready_or_skip "72-post" "core services unhealthy after case 72" >/dev/null || true
fi

# Case 73: Kafka down -> buffer event/outbox
if require_compose_or_skip "73" "requires docker compose fault injection" && ensure_ready_or_skip "73" "core services unhealthy before case 73"; then
  stop_services "kafka"

  C73_TOKEN="$(new_user_token 73)"
  if [[ -z "$C73_TOKEN" ]]; then
    mark_no_evidence_fail "73" "cannot get auth token while testing kafka outage"
  else
    C73=$(call_gateway_json POST "/v1/bookings" "$C73_TOKEN" "$create_booking_payload")
    C73_STATUS=$(echo "$C73" | sed -n '1p')
    C73_BODY=$(echo "$C73" | sed '1d')
    C73_BOOKING_ID=$(echo "$C73_BODY" | json_get "booking.booking_id")
    if [[ -z "$C73_BOOKING_ID" ]]; then C73_BOOKING_ID=$(echo "$C73_BODY" | json_get "booking.bookingId"); fi
    C73_QUEUED=$(echo "$C73_BODY" | json_get "publishedEvent.queued")
    if [[ -z "$C73_QUEUED" ]]; then C73_QUEUED=$(echo "$C73_BODY" | json_get "outbox.queued"); fi
    C73_EVENT_ID=$(echo "$C73_BODY" | json_get "publishedEvent.eventId")
    if [[ -z "$C73_EVENT_ID" ]]; then C73_EVENT_ID=$(echo "$C73_BODY" | json_get "outbox.eventId"); fi
    C73_EVENT_STATE=$(echo "$C73_BODY" | json_get "publishedEvent.status")
    if [[ -z "$C73_EVENT_STATE" ]]; then C73_EVENT_STATE=$(echo "$C73_BODY" | json_get "outbox.status"); fi

    print_case "Case 73 - Kafka down -> buffer event" \
      "Fault: stop kafka; Payload: $create_booking_payload" \
      "system does not crash + event is buffered/retryable (outbox/queued/pending marker exists)" \
      "$C73_STATUS" "$C73_BODY"

    if [[ "$C73_STATUS" == "200" || "$C73_STATUS" == "201" ]] && [[ -n "$C73_BOOKING_ID" ]] \
      && ( [[ "$C73_QUEUED" == "true" ]] || [[ -n "$C73_EVENT_ID" ]] || [[ "$C73_EVENT_STATE" == "QUEUED" || "$C73_EVENT_STATE" == "PENDING" ]] ); then
      mark_result 1 "73"
    else
      mark_result 0 "73"
    fi
  fi

  start_services "kafka"
  ensure_ready_or_skip "73-post" "core services unhealthy after case 73" >/dev/null || true
fi

# Case 74: DB failover / restart recovery
if [[ "$CASE74_ENABLE" != "1" ]]; then
  C74_STATUS="DISABLED"
  C74_BODY='{"error":"CASE74_ENABLE!=1; strict mode requires running case 74"}'
  print_case "Case 74 - DB restart recovery" \
    "Fault: restart postgres; Payload: $create_booking_payload" \
    "booking path recovers within ${CASE74_RECOVERY_TIMEOUT_SEC}s and remains consistent for subsequent request" \
    "$C74_STATUS" "$C74_BODY"
  mark_result 0 "74"
elif [[ "$COMPOSE_AVAILABLE" != "1" ]]; then
  C74_STATUS="NO_EVIDENCE"
  C74_BODY='{"error":"docker compose unavailable; cannot inject DB restart/failover fault"}'
  print_case "Case 74 - DB restart recovery" \
    "Fault: restart postgres; Payload: $create_booking_payload" \
    "booking path recovers within ${CASE74_RECOVERY_TIMEOUT_SEC}s and remains consistent for subsequent request" \
    "$C74_STATUS" "$C74_BODY"
  mark_result 0 "74"
else
  if ! ensure_core_ready 30 && ! recover_core_stack; then
    C74_STATUS="NO_EVIDENCE"
    C74_BODY='{"error":"core services unhealthy before case 74"}'
    print_case "Case 74 - DB restart recovery" \
      "Fault: restart postgres; Payload: $create_booking_payload" \
      "booking path recovers within ${CASE74_RECOVERY_TIMEOUT_SEC}s and remains consistent for subsequent request" \
      "$C74_STATUS" "$C74_BODY"
    mark_result 0 "74"
  else
    C74_TOKEN="$(new_user_token 74)"
    if [[ -z "$C74_TOKEN" ]]; then
      C74_STATUS="NO_EVIDENCE"
      C74_BODY='{"error":"cannot get auth token before DB restart scenario"}'
      print_case "Case 74 - DB restart recovery" \
        "Fault: restart postgres; Payload: $create_booking_payload" \
        "booking path recovers within ${CASE74_RECOVERY_TIMEOUT_SEC}s and remains consistent for subsequent request" \
        "$C74_STATUS" "$C74_BODY"
      mark_result 0 "74"
    else
      compose_cmd restart postgres >/dev/null 2>&1 || true
      sleep "$FAULT_SETTLE_SEC"

      C74_STATUS="000"
      C74_BODY='{"error":"not_attempted"}'
      C74_OK=0
      C74_FIRST_OK=0
      C74_SECOND_OK=0
      C74_SECOND_STATUS="000"
      C74_SECOND_BODY='{"error":"second request not attempted"}'
      C74_FIRST_DEADLINE=$(( $(now_ms) + CASE74_RECOVERY_TIMEOUT_SEC * 1000 ))

      while (( $(now_ms) < C74_FIRST_DEADLINE )); do
        C74=$(call_gateway_json POST "/v1/bookings" "$C74_TOKEN" "$create_booking_payload")
        C74_STATUS=$(echo "$C74" | sed -n '1p')
        C74_BODY=$(echo "$C74" | sed '1d')
        if [[ "$C74_STATUS" == "200" || "$C74_STATUS" == "201" ]]; then
          C74_FIRST_OK=1
          break
        fi
        if [[ "$C74_STATUS" != "000" && "$C74_STATUS" != "429" && "$C74_STATUS" != "500" && "$C74_STATUS" != "502" && "$C74_STATUS" != "503" && "$C74_STATUS" != "504" ]]; then
          break
        fi
        sleep 2
      done

      if [[ "$C74_FIRST_OK" == "1" ]]; then
        C74_SECOND_TOKEN="$(new_user_token 74b)"
        if [[ -z "$C74_SECOND_TOKEN" ]]; then
          sleep "$AUTH_BOOTSTRAP_RETRY_DELAY_SEC"
          C74_SECOND_TOKEN="$(new_user_token 74c)"
        fi
        if [[ -z "$C74_SECOND_TOKEN" ]]; then
          C74_SECOND_BODY='{"error":"cannot get auth token for follow-up request"}'
        else
          C74_SECOND_DEADLINE=$(( $(now_ms) + CASE74_RECOVERY_TIMEOUT_SEC * 1000 ))
          while (( $(now_ms) < C74_SECOND_DEADLINE )); do
            C74_SECOND=$(call_gateway_json POST "/v1/bookings" "$C74_SECOND_TOKEN" "$create_booking_payload")
            C74_SECOND_STATUS=$(echo "$C74_SECOND" | sed -n '1p')
            C74_SECOND_BODY=$(echo "$C74_SECOND" | sed '1d')
            if [[ "$C74_SECOND_STATUS" == "200" || "$C74_SECOND_STATUS" == "201" ]]; then
              C74_SECOND_OK=1
              break
            fi
            if [[ "$C74_SECOND_STATUS" != "000" && "$C74_SECOND_STATUS" != "429" && "$C74_SECOND_STATUS" != "500" && "$C74_SECOND_STATUS" != "502" && "$C74_SECOND_STATUS" != "503" && "$C74_SECOND_STATUS" != "504" ]]; then
              break
            fi
            sleep 2
          done
        fi
      fi

      if ! ensure_core_ready 30 && ! recover_core_stack; then
        C74_FIRST_OK=0
        C74_SECOND_OK=0
      fi

      if [[ "$C74_FIRST_OK" == "1" && "$C74_SECOND_OK" == "1" ]]; then
        C74_OK=1
      fi

      C74_BODY="$C74_BODY"$'\n'"follow_up_status=$C74_SECOND_STATUS; first_ok=$C74_FIRST_OK; second_ok=$C74_SECOND_OK"

      print_case "Case 74 - DB restart recovery" \
        "Fault: restart postgres; Payload: $create_booking_payload" \
        "booking path recovers within ${CASE74_RECOVERY_TIMEOUT_SEC}s and remains consistent for subsequent request" \
        "$C74_STATUS" "$C74_BODY"

      mark_result "$C74_OK" "74"
    fi
  fi
fi

# Case 75: Circuit breaker open -> fail fast
if require_compose_or_skip "75" "requires docker compose fault injection" && ensure_ready_or_skip "75" "core services unhealthy before case 75"; then
  stop_services "pricing-service"

  C75_TOKEN="$(new_user_token 75)"
  if [[ -z "$C75_TOKEN" ]]; then
    mark_no_evidence_fail "75" "cannot get auth token for gateway circuit-breaker assertion"
  else
    C75A_T0=$(now_ms)
    C75A=$(call_gateway_json GET "/v1/pricing/quotes/non-existing-quote" "$C75_TOKEN")
    C75A_T1=$(now_ms)
    C75A_STATUS=$(echo "$C75A" | sed -n '1p')
    C75A_BODY=$(echo "$C75A" | sed '1d')
    C75A_CODE=$(echo "$C75A_BODY" | json_get "error.code")
    C75A_LAT=$((C75A_T1 - C75A_T0))

    C75B_T0=$(now_ms)
    C75B=$(call_gateway_json GET "/v1/pricing/quotes/non-existing-quote" "$C75_TOKEN")
    C75B_T1=$(now_ms)
    C75B_STATUS=$(echo "$C75B" | sed -n '1p')
    C75B_BODY=$(echo "$C75B" | sed '1d')
    C75B_CODE=$(echo "$C75B_BODY" | json_get "error.code")
    C75B_LAT=$((C75B_T1 - C75B_T0))

    C75_MERGED="first={status:$C75A_STATUS,code:$C75A_CODE,lat_ms:$C75A_LAT}; second={status:$C75B_STATUS,code:$C75B_CODE,lat_ms:$C75B_LAT}"
    print_case "Case 75 - Circuit breaker fail-fast" \
      "Fault: stop pricing-service; Input: 2x GET /v1/pricing/quotes/non-existing-quote (with token)" \
      "upstream error is isolated + fail-fast behavior (avoid cascade): status in {502,503,504}, upstream error code, and second call not slower than first" \
      "local-check" "$C75_MERGED"

    C75_OK=0
    if [[ ("$C75A_STATUS" == "502" || "$C75A_STATUS" == "504" || "$C75A_STATUS" == "503") \
      && ("$C75B_STATUS" == "502" || "$C75B_STATUS" == "504" || "$C75B_STATUS" == "503") ]] \
      && [[ ("$C75A_CODE" == "UPSTREAM_UNAVAILABLE" || "$C75A_CODE" == "UPSTREAM_TIMEOUT" || "$C75A_CODE" == "UPSTREAM_CIRCUIT_OPEN") ]] \
      && [[ ("$C75B_CODE" == "UPSTREAM_UNAVAILABLE" || "$C75B_CODE" == "UPSTREAM_TIMEOUT" || "$C75B_CODE" == "UPSTREAM_CIRCUIT_OPEN") ]] \
      && (( C75A_LAT <= CASE75_FAIL_FAST_MS )) && (( C75B_LAT <= CASE75_FAIL_FAST_MS )) \
      && (( C75B_LAT <= C75A_LAT + 200 )); then
      C75_OK=1
    fi
    mark_result "$C75_OK" "75"
  fi

  start_services "pricing-service"
  ensure_ready_or_skip "75-post" "core services unhealthy after case 75" >/dev/null || true
fi

# Case 76: Partial system failure handling
if require_compose_or_skip "76" "requires docker compose fault injection" && ensure_ready_or_skip "76" "core services unhealthy before case 76"; then
  stop_services "driver-service eta-service"

  C76_TOKEN="$(new_user_token 76)"
  if [[ -z "$C76_TOKEN" ]]; then
    mark_no_evidence_fail "76" "cannot get auth token while testing partial failure handling"
  else
    C76=$(call_gateway_json POST "/v1/bookings" "$C76_TOKEN" "$create_booking_payload")
    C76_STATUS=$(echo "$C76" | sed -n '1p')
    C76_BODY=$(echo "$C76" | sed '1d')
    C76_BOOKING_ID=$(echo "$C76_BODY" | json_get "booking.booking_id")
    if [[ -z "$C76_BOOKING_ID" ]]; then C76_BOOKING_ID=$(echo "$C76_BODY" | json_get "booking.bookingId"); fi
    C76_STATUS_FIELD=$(echo "$C76_BODY" | json_get "booking.status")
    C76_ETA=$(echo "$C76_BODY" | json_get "booking.eta_minutes")
    C76_QUOTE=$(echo "$C76_BODY" | json_get "booking.priceSnapshot.quoteId")
    C76_FALLBACK=$(echo "$C76_BODY" | json_get "booking.priceSnapshot.fallbackUsed")

    print_case "Case 76 - Partial failure (driver + eta down)" \
      "Fault: stop driver-service + eta-service; Payload: $create_booking_payload" \
      "partial failure does not crash full flow: status in {200,201} + booking_id exists + core booking status valid" \
      "$C76_STATUS" "$C76_BODY"

    if [[ "$C76_STATUS" == "200" || "$C76_STATUS" == "201" ]] && [[ -n "$C76_BOOKING_ID" ]] \
      && [[ "$C76_STATUS_FIELD" == "REQUESTED" || "$C76_STATUS_FIELD" == "PENDING" || "$C76_STATUS_FIELD" == "CONFIRMED" ]] \
      && ( [[ -n "$C76_QUOTE" ]] || [[ "$C76_FALLBACK" == "true" ]] || node -e "const n=Number(process.argv[1]);process.exit(Number.isFinite(n)&&n>=0?0:1)" "${C76_ETA:-NaN}" ); then
      mark_result 1 "76"
    else
      mark_result 0 "76"
    fi
  fi

  start_services "driver-service eta-service"
  ensure_ready_or_skip "76-post" "core services unhealthy after case 76" >/dev/null || true
fi

# Case 77: Retry exponential backoff
C77_OUTPUT=$(node - <<'NODE' "$CASE77_BASE_MS" "$CASE77_MAX_MS"
const { computeRetryDelayMs } = require('./services/booking-service/src/repositories/outboxRepo');
const baseMs = Number(process.argv[2] || 1000);
const maxMs = Number(process.argv[3] || 8000);
const attempts = [1, 2, 3, 4];
const actual = attempts.map((a) => computeRetryDelayMs({ attemptCount: a, baseMs, maxMs }));
const expected = [baseMs, baseMs * 2, baseMs * 4, Math.min(baseMs * 8, maxMs)];
const increasing = actual.every((v, i) => i === 0 || v >= actual[i - 1]);
const has123 = actual[0] === expected[0] && actual[1] === expected[1] && actual[2] === expected[2];
const ok = actual.length === expected.length && increasing && has123;
process.stdout.write(JSON.stringify({ attempts, baseMs, maxMs, actual, expected, increasing, ok }));
NODE
)
C77_OK=$(echo "$C77_OUTPUT" | json_get "ok")
print_case "Case 77 - Exponential backoff policy" \
  "attempts=[1,2,3,4], base=${CASE77_BASE_MS}ms, max=${CASE77_MAX_MS}ms" \
  "retry delay follows 1s -> 2s -> 4s pattern (or equivalent base*2^n), monotonic (no spam)" \
  "local-check" "$C77_OUTPUT"
if [[ "$C77_OK" == "true" ]]; then
  mark_result 1 "77"
else
  mark_result 0 "77"
fi

# Case 78: Service mesh routing fail -> fallback route (simulated by pricing route outage)
if require_compose_or_skip "78" "requires docker compose pause/unpause" && ensure_ready_or_skip "78" "core services unhealthy before case 78"; then
  if pause_services "pricing-service"; then
    C78_TOKEN="$(new_user_token 78)"
    if [[ -z "$C78_TOKEN" ]]; then
      mark_no_evidence_fail "78" "cannot get auth token for routing fail simulation"
    else
      C78=$(call_gateway_json POST "/v1/bookings" "$C78_TOKEN" "$create_booking_payload")
      C78_STATUS=$(echo "$C78" | sed -n '1p')
      C78_BODY=$(echo "$C78" | sed '1d')
      C78_BOOKING_ID=$(echo "$C78_BODY" | json_get "booking.booking_id")
      if [[ -z "$C78_BOOKING_ID" ]]; then C78_BOOKING_ID=$(echo "$C78_BODY" | json_get "booking.bookingId"); fi
      C78_QUOTE_ID=$(echo "$C78_BODY" | json_get "booking.priceSnapshot.quoteId")
      C78_FALLBACK=$(echo "$C78_BODY" | json_get "booking.priceSnapshot.fallbackUsed")
      C78_PRICE_TOTAL=$(echo "$C78_BODY" | json_get "booking.priceSnapshot.total")
      if [[ -z "$C78_PRICE_TOTAL" ]]; then C78_PRICE_TOTAL=$(echo "$C78_BODY" | json_get "booking.price.total"); fi

      print_case "Case 78 - Service mesh routing fail (fallback route)" \
        "Fault: pause pricing-service (simulate route failure); Payload: $create_booking_payload" \
        "request not lost: booking still created with fallback/default pricing path" \
        "$C78_STATUS" "$C78_BODY"

      if [[ "$C78_STATUS" == "200" || "$C78_STATUS" == "201" ]] && [[ -n "$C78_BOOKING_ID" ]] \
        && ( [[ "$C78_QUOTE_ID" == quote_local_fallback_* ]] || [[ "$C78_FALLBACK" == "true" ]] || node -e "const n=Number(process.argv[1]);process.exit(Number.isFinite(n)&&n>=0?0:1)" "${C78_PRICE_TOTAL:-NaN}" ); then
        mark_result 1 "78"
      else
        mark_result 0 "78"
      fi
    fi

    unpause_services "pricing-service"
    ensure_ready_or_skip "78-post" "core services unhealthy after case 78" >/dev/null || true
  else
    mark_no_evidence_fail "78" "docker compose pause/unpause unsupported in this environment"
  fi
fi

# Case 79: Network partition simulation
if require_compose_or_skip "79" "requires docker compose pause/unpause" && ensure_ready_or_skip "79" "core services unhealthy before case 79"; then
  if pause_services "pricing-service"; then
    C79_MARKED=0
    C79_PHASE1_OK=0
    C79_PHASE2_OK=0
    C79_TOKEN="$(new_user_token 79)"
    if [[ -z "$C79_TOKEN" ]]; then
      mark_no_evidence_fail "79" "cannot get auth token while testing partition scenario"
      C79_MARKED=1
    else
      C79_T0=$(now_ms)
      C79=$(call_gateway_json POST "/v1/bookings" "$C79_TOKEN" "$create_booking_payload")
      C79_T1=$(now_ms)
      C79_STATUS=$(echo "$C79" | sed -n '1p')
      C79_BODY=$(echo "$C79" | sed '1d')
      C79_BOOKING_ID=$(echo "$C79_BODY" | json_get "booking.booking_id")
      if [[ -z "$C79_BOOKING_ID" ]]; then C79_BOOKING_ID=$(echo "$C79_BODY" | json_get "booking.bookingId"); fi
      C79_QUOTE_ID=$(echo "$C79_BODY" | json_get "booking.priceSnapshot.quoteId")
      C79_FALLBACK=$(echo "$C79_BODY" | json_get "booking.priceSnapshot.fallbackUsed")
      C79_PRICE_TOTAL=$(echo "$C79_BODY" | json_get "booking.priceSnapshot.total")
      if [[ -z "$C79_PRICE_TOTAL" ]]; then C79_PRICE_TOTAL=$(echo "$C79_BODY" | json_get "booking.price.total"); fi
      C79_ELAPSED=$((C79_T1 - C79_T0))

      print_case "Case 79 - Network partition simulation" \
        "Fault: pause pricing-service; Payload: $create_booking_payload" \
        "degrade gracefully during partition + recover after network returns" \
        "$C79_STATUS" "$C79_BODY"

      if [[ "$C79_STATUS" == "200" || "$C79_STATUS" == "201" ]] && [[ -n "$C79_BOOKING_ID" ]] \
        && ( [[ "$C79_QUOTE_ID" == quote_local_fallback_* ]] || [[ "$C79_FALLBACK" == "true" ]] || node -e "const n=Number(process.argv[1]);process.exit(Number.isFinite(n)&&n>=0?0:1)" "${C79_PRICE_TOTAL:-NaN}" ); then
        C79_PHASE1_OK=1
      fi
    fi

    unpause_services "pricing-service"
    sleep "$FAULT_SETTLE_SEC"

    if [[ "$C79_MARKED" != "1" ]] && ensure_ready_or_skip "79-post" "core services unhealthy after case 79" >/dev/null; then
      sleep "$CASE79_RECOVERY_WAIT_SEC"
      C79_PRICING_RECOVER=$(call_json_url POST "$PRICING_URL/v1/pricing/estimate" "" '{"distance_km":5,"demand_index":1}' "x-internal-key" "$INTERNAL_API_KEY")
      C79_PRICING_RECOVER_STATUS=$(echo "$C79_PRICING_RECOVER" | sed -n '1p')

      C79_TOKEN2="$(new_user_token 79b)"
      if [[ -n "$C79_TOKEN2" ]]; then
        C79B=$(call_gateway_json POST "/v1/bookings" "$C79_TOKEN2" "$create_booking_payload")
        C79B_STATUS=$(echo "$C79B" | sed -n '1p')
        C79B_BODY=$(echo "$C79B" | sed '1d')
        C79B_BOOKING_ID=$(echo "$C79B_BODY" | json_get "booking.booking_id")
        if [[ -z "$C79B_BOOKING_ID" ]]; then C79B_BOOKING_ID=$(echo "$C79B_BODY" | json_get "booking.bookingId"); fi
        if [[ "$C79_PRICING_RECOVER_STATUS" == "200" ]] && [[ "$C79B_STATUS" == "200" || "$C79B_STATUS" == "201" ]] && [[ -n "$C79B_BOOKING_ID" ]]; then
          C79_PHASE2_OK=1
        fi
      fi
    fi

    if [[ "$C79_MARKED" != "1" ]]; then
      if [[ "${C79_PHASE1_OK:-0}" == "1" && "${C79_PHASE2_OK:-0}" == "1" ]]; then
        mark_result 1 "79"
      else
        echo "[79] detail: phase1_ok=${C79_PHASE1_OK:-0} phase2_ok=${C79_PHASE2_OK:-0} elapsed_ms=${C79_ELAPSED:-0} quote_id=${C79_QUOTE_ID:-}"
        mark_result 0 "79"
      fi
    fi
  else
    mark_no_evidence_fail "79" "docker compose pause/unpause unsupported in this environment"
  fi
fi

# Case 80: Graceful degradation
if require_compose_or_skip "80" "requires docker compose fault injection" && ensure_ready_or_skip "80" "core services unhealthy before case 80"; then
  C80_TOKEN="$(new_user_token 80)"
  if [[ -z "$C80_TOKEN" ]]; then
    mark_no_evidence_fail "80" "cannot get auth token before degradation scenario"
  else
    stop_services "driver-service eta-service pricing-service kafka"

    C80=$(call_gateway_json POST "/v1/bookings" "$C80_TOKEN" "$create_booking_payload" "x-booking-fast-path" "1" "x-load-test" "1")
    C80_STATUS=$(echo "$C80" | sed -n '1p')
    C80_BODY=$(echo "$C80" | sed '1d')
    C80_BID=$(echo "$C80_BODY" | json_get "booking.bookingId")
    if [[ -z "$C80_BID" ]]; then C80_BID=$(echo "$C80_BODY" | json_get "booking.booking_id"); fi
    C80_RID=$(echo "$C80_BODY" | json_get "booking.rideId")
    C80_ST=$(echo "$C80_BODY" | json_get "booking.status")
    C80_CA=$(echo "$C80_BODY" | json_get "booking.createdAt")
    C80_HEALTH=$(call_json_url GET "$BASE_URL/health")
    C80_HEALTH_STATUS=$(echo "$C80_HEALTH" | sed -n '1p')

    print_case "Case 80 - Graceful degradation" \
      "Fault: stop driver + eta + pricing + kafka; Payload: $create_booking_payload; Headers: x-booking-fast-path=1, x-load-test=1" \
      "non-critical features may degrade, but core booking still works and system does not crash" \
      "$C80_STATUS" "$C80_BODY"

    if [[ "$C80_STATUS" == "200" || "$C80_STATUS" == "201" ]] && [[ -n "$C80_BID" ]] \
      && [[ "$C80_ST" == "REQUESTED" || "$C80_ST" == "PENDING" || "$C80_ST" == "CONFIRMED" ]] \
      && [[ "$C80_HEALTH_STATUS" == "200" ]]; then
      mark_result 1 "80"
    else
      mark_result 0 "80"
    fi
  fi

  start_services "driver-service eta-service pricing-service kafka"
  ensure_ready_or_skip "80-post" "core services unhealthy after case 80" >/dev/null || true
fi

echo "========================================="
echo "LEVEL 8 SUMMARY (Cases 71-80)"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
