#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

BASE_URL="${BASE_URL:-http://localhost:3000}"
PASS="${PASS:-123456}"
USER_TOKEN="${USER_TOKEN:-}"

CASE77_RETRY_MAX="${CASE77_RETRY_MAX:-3}"
CASE77_BACKOFF_BASE_MS="${CASE77_BACKOFF_BASE_MS:-1000}"
CASE77_BACKOFF_MAX_MS="${CASE77_BACKOFF_MAX_MS:-4000}"
CASE77_RECOVERY_AFTER_SEC="${CASE77_RECOVERY_AFTER_SEC:-4}"
CASE77_CURL_MAX_TIME="${CASE77_CURL_MAX_TIME:-25}"
CASE77_RESTORE_BOOKING_CONFIG="${CASE77_RESTORE_BOOKING_CONFIG:-true}"
CASE77_COMPACT_LOG="${CASE77_COMPACT_LOG:-true}"
CASE77_REQUIRE_DB_PERSIST="${CASE77_REQUIRE_DB_PERSIST:-false}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case77}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_JSON="$OUT_DIR/case77-retry-backoff.json"
META_FILE="$OUT_DIR/meta.env"
BODY_FILE="$OUT_DIR/booking-response.json"
STATUS_FILE="$OUT_DIR/curl-status.txt"
BOOKING_ENV_FILE="$OUT_DIR/booking-env-active.txt"
RUN_LOG_FILE="$OUT_DIR/case77-run.log"
DB_CHECK_FILE="$OUT_DIR/booking-db-check.txt"

mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd docker
need_cmd curl
need_cmd jq
need_cmd node

compose_dev() {
  docker compose -f "$REPO_ROOT/infra/docker-compose.dev.yml" "$@"
}

log() {
  echo "[case77][$(date +%H:%M:%S)] $*"
}

compose_run() {
  if [[ "$CASE77_COMPACT_LOG" == "true" ]]; then
    compose_dev "$@" >>"$RUN_LOG_FILE" 2>&1
  else
    compose_dev "$@"
  fi
}

cleanup() {
  compose_run start pricing-service || true
  if [[ "$CASE77_RESTORE_BOOKING_CONFIG" == "true" ]]; then
    compose_run up -d --no-deps --force-recreate booking-service || true
  fi
}
trap cleanup EXIT

create_token_if_missing() {
  if [[ -n "$USER_TOKEN" ]]; then
    return 0
  fi

  local ts email username register_json login_json token reg_resp
  ts="$(date +%s%3N)"
  email="case77-k6-${ts}-${RANDOM}@test.com"
  username="case77_${ts}_${RANDOM}"

  register_json=$(jq -nc \
    --arg email "$email" \
    --arg username "$username" \
    --arg pass "$PASS" \
    '{email:$email,username:$username,password:$pass,name:"Case77 User",role:"admin"}')

  reg_resp="$(curl -sS -X POST "$BASE_URL/v1/auth/register" \
    -H 'Content-Type: application/json' \
    -d "$register_json")"
  token="$(printf '%s' "$reg_resp" | jq -r '.tokens.accessToken // empty')"
  if [[ -z "$token" ]]; then
    login_json=$(jq -nc --arg identifier "$email" --arg pass "$PASS" '{identifier:$identifier,password:$pass}')
    reg_resp="$(curl -sS -X POST "$BASE_URL/v1/auth/login" -H 'Content-Type: application/json' -d "$login_json")"
    token="$(printf '%s' "$reg_resp" | jq -r '.tokens.accessToken // empty')"
  fi
  if [[ -z "$token" ]]; then
    echo "Cannot get USER_TOKEN for case77."
    echo "Auth response: $reg_resp"
    exit 1
  fi
  USER_TOKEN="$token"
  echo "AUTO_USER_EMAIL=$email" >> "$META_FILE"
}

{
  echo "CASE=77"
  echo "RUN_ID=$RUN_ID"
  echo "BASE_URL=$BASE_URL"
  echo "CASE77_RETRY_MAX=$CASE77_RETRY_MAX"
  echo "CASE77_BACKOFF_BASE_MS=$CASE77_BACKOFF_BASE_MS"
  echo "CASE77_BACKOFF_MAX_MS=$CASE77_BACKOFF_MAX_MS"
  echo "CASE77_RECOVERY_AFTER_SEC=$CASE77_RECOVERY_AFTER_SEC"
  echo "CASE77_CURL_MAX_TIME=$CASE77_CURL_MAX_TIME"
  echo "CASE77_REQUIRE_DB_PERSIST=$CASE77_REQUIRE_DB_PERSIST"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

create_token_if_missing

# Recreate booking-service with forced remote pricing + retry profile for case77.
log "STEP 1/5: Recreate booking-service with retry backoff profile"
PRICING_HTTP_RETRY_MAX="$CASE77_RETRY_MAX" \
PRICING_HTTP_RETRY_BACKOFF_MS="$CASE77_BACKOFF_BASE_MS" \
PRICING_HTTP_RETRY_MAX_BACKOFF_MS="$CASE77_BACKOFF_MAX_MS" \
PRICING_CIRCUIT_BREAKER_ENABLED="false" \
ENABLE_PRICING_FALLBACK_MOCK="false" \
BOOKING_FORCE_REMOTE_ESTIMATES="true" \
BOOKING_FORCE_LOCAL_ESTIMATES="false" \
compose_run up -d --no-deps --build --force-recreate booking-service

sleep 2

# Verify booking-service is running with case77 env profile.
log "STEP 2/5: Verify booking-service env profile"
compose_dev exec -T booking-service /bin/sh -lc \
  "env | sort | grep -E 'PRICING_HTTP_RETRY_MAX=|PRICING_HTTP_RETRY_BACKOFF_MS=|PRICING_HTTP_RETRY_MAX_BACKOFF_MS=|PRICING_CIRCUIT_BREAKER_ENABLED=|ENABLE_PRICING_FALLBACK_MOCK=|BOOKING_FORCE_REMOTE_ESTIMATES=|BOOKING_FORCE_LOCAL_ESTIMATES='" \
  > "$BOOKING_ENV_FILE"

if ! grep -q "PRICING_HTTP_RETRY_MAX=$CASE77_RETRY_MAX" "$BOOKING_ENV_FILE"; then
  echo "booking-service env retry profile was not applied."
  echo "See: $BOOKING_ENV_FILE"
  exit 1
fi

echo "BOOKING_ENV_FILE=$BOOKING_ENV_FILE" >> "$META_FILE"

# Temporary failure: pricing goes down, then comes back while retry is running.
log "STEP 3/5: Simulate temporary outage on pricing-service"
compose_run stop pricing-service
( sleep "$CASE77_RECOVERY_AFTER_SEC"; compose_run start pricing-service ) &
RECOVERY_PID=$!

TEST_USER_ID="case77-user-$(date +%s)"
REQ_PAYLOAD=$(jq -nc --arg uid "$TEST_USER_ID" '{
  user_id: $uid,
  pickup: {lat: 10.7602, lng: 106.6602},
  drop: {lat: 10.7711, lng: 106.7011},
  vehicleType: "CAR"
}')

REQUEST_START_MS="$(node -e 'console.log(Date.now())')"
log "STEP 4/5: Send one booking request while pricing-service is down"
curl -sS -m "$CASE77_CURL_MAX_TIME" -o "$BODY_FILE" -w "HTTP_STATUS=%{http_code}\nTOTAL_TIME_S=%{time_total}\n" \
  -X POST "$BASE_URL/v1/bookings" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$REQ_PAYLOAD" > "$STATUS_FILE" || true
REQUEST_END_MS="$(node -e 'console.log(Date.now())')"

wait "$RECOVERY_PID" || true

HTTP_STATUS="$(awk -F= '/^HTTP_STATUS=/{print $2}' "$STATUS_FILE" | tail -n1)"
TOTAL_TIME_S="$(awk -F= '/^TOTAL_TIME_S=/{print $2}' "$STATUS_FILE" | tail -n1)"
ELAPSED_MS="$((REQUEST_END_MS - REQUEST_START_MS))"

BOOKING_ID="$(jq -r '.booking.booking_id // .booking.bookingId // .booking_id // .bookingId // empty' "$BODY_FILE" 2>/dev/null || true)"
DB_PERSISTED="false"
DB_BOOKING_STATUS=""
DB_BOOKING_CREATED_AT=""
if [[ -n "$BOOKING_ID" ]]; then
  log "STEP 4.5/5: Check booking persisted in Postgres"
  SQL_BOOKING_ID="$(printf "%s" "$BOOKING_ID" | sed "s/'/''/g")"
  DB_ROW="$(compose_dev exec -T postgres psql -U cab -d booking-service_db -t -A -F '|' \
    -c "SELECT booking_id, status, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM bookings WHERE booking_id='${SQL_BOOKING_ID}' LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "$DB_ROW" ]]; then
    DB_PERSISTED="true"
    IFS='|' read -r _DB_BOOKING_ID DB_BOOKING_STATUS DB_BOOKING_CREATED_AT <<< "$DB_ROW"
    printf "booking_id=%s\nstatus=%s\ncreated_at_utc=%s\n" "$BOOKING_ID" "$DB_BOOKING_STATUS" "$DB_BOOKING_CREATED_AT" > "$DB_CHECK_FILE"
  else
    printf "booking_id=%s\nstatus=NOT_FOUND\n" "$BOOKING_ID" > "$DB_CHECK_FILE"
  fi
else
  printf "booking_id=\nstatus=NO_BOOKING_ID_IN_RESPONSE\n" > "$DB_CHECK_FILE"
fi

echo "[case77][SQL] booking persistence check:"
cat "$DB_CHECK_FILE"

BACKOFF_JSON="$(node - <<'NODE' "$CASE77_BACKOFF_BASE_MS" "$CASE77_BACKOFF_MAX_MS"
const { computeRetryDelayMs } = require('./services/booking-service/src/repositories/outboxRepo');
const baseMs = Number(process.argv[2] || 1000);
const maxMs = Number(process.argv[3] || 4000);
const seq = [1,2,3].map((a) => computeRetryDelayMs({ attemptCount: a, baseMs, maxMs }));
process.stdout.write(JSON.stringify(seq));
NODE
)"

EXPECTED_MIN_WAIT_MS="$(node - <<'NODE' "$BACKOFF_JSON"
const seq = JSON.parse(process.argv[2] || '[1000,2000,4000]');
const sum = seq.reduce((a,b)=>a+Number(b||0),0);
process.stdout.write(String(sum));
NODE
)"

PASS="false"
if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
  if [[ "$ELAPSED_MS" -ge "$EXPECTED_MIN_WAIT_MS" ]]; then
    PASS="true"
  fi
fi
if [[ "$CASE77_REQUIRE_DB_PERSIST" == "true" && "$DB_PERSISTED" != "true" ]]; then
  PASS="false"
fi

log "STEP 5/5: Evaluate pass/fail and write evidence"
jq -n \
  --arg case_id "77" \
  --arg scenario "Retry exponential backoff on temporary pricing-service failure (real services)" \
  --argjson backoff "$BACKOFF_JSON" \
  --arg http_status "${HTTP_STATUS:-0}" \
  --arg total_time_s "${TOTAL_TIME_S:-0}" \
  --argjson elapsed_ms "$ELAPSED_MS" \
  --argjson expected_min_wait_ms "$EXPECTED_MIN_WAIT_MS" \
  --arg recover_after_sec "$CASE77_RECOVERY_AFTER_SEC" \
  --arg booking_id "${BOOKING_ID:-}" \
  --arg db_persisted "$DB_PERSISTED" \
  --arg db_booking_status "${DB_BOOKING_STATUS:-}" \
  --arg db_booking_created_at "${DB_BOOKING_CREATED_AT:-}" \
  --arg require_db_persist "$CASE77_REQUIRE_DB_PERSIST" \
  --arg pass "$PASS" \
  '{
    case: ($case_id | tonumber),
    scenario: $scenario,
    expected: {
      backoff_pattern_ms: $backoff,
      no_spam: true,
      recover_success: true
    },
    observed: {
      http_status: ($http_status | tonumber),
      total_time_s: ($total_time_s | tonumber),
      elapsed_ms: $elapsed_ms,
      expected_min_wait_ms: $expected_min_wait_ms,
      pricing_recovered_after_sec: ($recover_after_sec | tonumber),
      booking_id: $booking_id,
      db_persisted: ($db_persisted == "true"),
      db_booking_status: $db_booking_status,
      db_booking_created_at_utc: $db_booking_created_at
    },
    checks: {
      pattern_1_2_4: ($backoff[0] == 1000 and $backoff[1] == 2000 and $backoff[2] == 4000),
      no_spam_inferred_from_wait: ($elapsed_ms >= $expected_min_wait_ms),
      recover_success: (($http_status | tonumber) == 200 or ($http_status | tonumber) == 201),
      booking_persisted_in_db: ($db_persisted == "true"),
      db_persist_required: ($require_db_persist == "true")
    },
    pass: ($pass == "true")
  }' > "$OUT_JSON"

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "HTTP_STATUS=${HTTP_STATUS:-0}" >> "$META_FILE"
echo "TOTAL_TIME_S=${TOTAL_TIME_S:-0}" >> "$META_FILE"
echo "ELAPSED_MS=$ELAPSED_MS" >> "$META_FILE"
echo "EXPECTED_MIN_WAIT_MS=$EXPECTED_MIN_WAIT_MS" >> "$META_FILE"
echo "BOOKING_ID=${BOOKING_ID:-}" >> "$META_FILE"
echo "DB_PERSISTED=$DB_PERSISTED" >> "$META_FILE"
echo "DB_CHECK_FILE=$DB_CHECK_FILE" >> "$META_FILE"
echo "PASS=$PASS" >> "$META_FILE"

echo "Evidence saved:"
echo "- $OUT_JSON"
echo "- $META_FILE"
echo "- $RUN_LOG_FILE"
echo "- $DB_CHECK_FILE"
echo "Result: PASS=$PASS, HTTP_STATUS=${HTTP_STATUS:-0}, ELAPSED_MS=$ELAPSED_MS"

if [[ "$PASS" != "true" ]]; then
  exit 1
fi
