#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
USER_PASS="${USER_PASS:-123456}"
UNIQ_TAG="$(date +%s)-$RANDOM"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"

CASE85_BURST_COUNT="${CASE85_BURST_COUNT:-2400}"
CASE85_CONCURRENCY="${CASE85_CONCURRENCY:-400}"
CASE85_MIN_429="${CASE85_MIN_429:-1}"
CASE85_MAX_TIME_MS="${CASE85_MAX_TIME_MS:-8000}"
CASE85_TARGET_PATH="${CASE85_TARGET_PATH:-/v1/bookings}"
CASE87_EVIDENCE_FILE="${CASE87_EVIDENCE_FILE:-}"
CASE87_EVIDENCE_TEXT="${CASE87_EVIDENCE_TEXT:-}"
CASE88_EVIDENCE_FILE="${CASE88_EVIDENCE_FILE:-}"
CASE88_EVIDENCE_TEXT="${CASE88_EVIDENCE_TEXT:-}"
DEFAULT_CASE87_EVIDENCE_FILE="$SCRIPT_DIR/evidence/case87-data-encryption-at-rest.txt"
DEFAULT_CASE88_EVIDENCE_FILE="$SCRIPT_DIR/evidence/case88-mtls-communication.txt"

if [[ -z "$CASE87_EVIDENCE_FILE" && -f "$DEFAULT_CASE87_EVIDENCE_FILE" ]]; then
  CASE87_EVIDENCE_FILE="$DEFAULT_CASE87_EVIDENCE_FILE"
fi
if [[ -z "$CASE88_EVIDENCE_FILE" && -f "$DEFAULT_CASE88_EVIDENCE_FILE" ]]; then
  CASE88_EVIDENCE_FILE="$DEFAULT_CASE88_EVIDENCE_FILE"
fi
if [[ -z "$CASE87_EVIDENCE_FILE" && -f "./scripts/evidence/case87-data-encryption-at-rest.txt" ]]; then
  CASE87_EVIDENCE_FILE="./scripts/evidence/case87-data-encryption-at-rest.txt"
fi
if [[ -z "$CASE88_EVIDENCE_FILE" && -f "./scripts/evidence/case88-mtls-communication.txt" ]]; then
  CASE88_EVIDENCE_FILE="./scripts/evidence/case88-mtls-communication.txt"
fi

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

print_usage() {
  cat <<USAGE
Usage:
  ./scripts/test-level9-81-90cases.sh [BASE_URL]

Examples:
  ./scripts/test-level9-81-90cases.sh
  ./scripts/test-level9-81-90cases.sh http://localhost:42100

Notes:
  - Default BASE_URL: $DEFAULT_BASE_URL
  - Cases 87 and 88 require hard runtime/infra evidence; if evidence is unavailable, these cases FAIL.
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
  echo "$input" | sed -n '1,180p'
  echo "Expected: $expected"
  echo "Actual status: $status"
  echo "Actual body:"
  echo "$body" | sed -n '1,220p'
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

extract_user_id() {
  local body="$1"
  local user_id
  user_id=$(echo "$body" | json_get "data.user_id")
  if [[ -z "$user_id" ]]; then user_id=$(echo "$body" | json_get "data.id"); fi
  if [[ -z "$user_id" ]]; then user_id=$(echo "$body" | json_get "user_id"); fi
  if [[ -z "$user_id" ]]; then user_id=$(echo "$body" | json_get "id"); fi
  echo "$user_id"
}

contains_security_leak() {
  local content="$1"
  if [[ -z "$content" ]]; then
    return 1
  fi
  local pattern
  pattern="(password_hash|x-api-key|api[_-]?key\\s*[:=]|jwt[_-]?secret|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY|select\\s+.+\\s+from\\s+|syntax error at or near|Sequelize|SQLSTATE|ECONNREFUSED|Error:\\s+at\\s+|\\bCVV\\b|\"cvv\"\\s*:|\"card(number|_number)?\"\\s*:)"
  if command -v rg >/dev/null 2>&1; then
    echo "$content" | rg -q -i -e "$pattern"
    return $?
  fi
  echo "$content" | grep -Eiq "$pattern"
}

load_evidence_text() {
  local evidence_file="${1:-}"
  local inline_text="${2:-}"
  local evidence=""
  if [[ -n "$evidence_file" && -f "$evidence_file" ]]; then
    evidence="$(cat "$evidence_file" 2>/dev/null || true)"
  fi
  if [[ -z "$evidence" && -n "$inline_text" ]]; then
    evidence="$inline_text"
  fi
  printf '%s' "$evidence"
}

text_matches_pattern() {
  local text="$1"
  local pattern="$2"
  if [[ -z "$text" ]]; then
    return 1
  fi
  if command -v rg >/dev/null 2>&1; then
    echo "$text" | rg -q -i -e "$pattern"
    return $?
  fi
  echo "$text" | grep -Eiq "$pattern"
}

ensure_gateway_ready() {
  local case_id="$1"
  if wait_for_url "$BASE_URL/health" 40; then
    return 0
  fi
  if [[ "$case_id" =~ ^[0-9]+$ ]]; then
    mark_no_evidence_fail "$case_id" "gateway health check failed at $BASE_URL/health"
  fi
  return 1
}

register_and_login_user() {
  local email="$1"
  local name="$2"
  local role="${3:-user}"

  call_gateway_json POST "/v1/auth/register" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"$role\"}" >/dev/null || true

  local attempts=8
  local i=1
  while [[ "$i" -le "$attempts" ]]; do
    local login
    local status
    local body

    login=$(call_gateway_json POST "/v1/auth/login" "" "{\"identifier\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
    status=$(echo "$login" | sed -n '1p')
    body=$(echo "$login" | sed '1d')

    if [[ "$status" != "200" ]]; then
      login=$(call_gateway_json POST "/v1/auth/login" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\"}" || true)
      status=$(echo "$login" | sed -n '1p')
      body=$(echo "$login" | sed '1d')
    fi

    local token
    token=$(extract_access_token "$body")
    local user_id
    user_id=$(extract_user_id "$body")
    if [[ -n "$token" && -n "$user_id" ]]; then
      printf '%s|%s\n' "$token" "$user_id"
      return 0
    fi

    sleep 1
    i=$((i + 1))
  done

  echo "|"
}

tamper_jwt_role_token() {
  local token="$1"
  node - "$token" <<'NODE'
const token = process.argv[2] || '';
const parts = token.split('.');
if (parts.length !== 3) {
  process.stdout.write('');
  process.exit(0);
}
function b64urlDecode(input) {
  const pad = input.length % 4;
  const padded = input + (pad ? '='.repeat(4 - pad) : '');
  return Buffer.from(padded.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}
function b64urlEncode(input) {
  return Buffer.from(input, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
let payload;
try {
  payload = JSON.parse(b64urlDecode(parts[1]));
} catch (_e) {
  process.stdout.write('');
  process.exit(0);
}
payload.role = 'admin';
payload.roles = ['admin'];
const newPayload = b64urlEncode(JSON.stringify(payload));
process.stdout.write(`${parts[0]}.${newPayload}.${parts[2]}`);
NODE
}

echo "== Setup for Level 9 security tests =="
if ! ensure_gateway_ready "setup"; then
  echo "STOP: gateway is not ready"
  exit 1
fi

TEST_EMAIL_USER="level9-user-${UNIQ_TAG}@test.com"
TEST_NAME_USER="Level9 User ${UNIQ_TAG}"
TEST_EMAIL_DRIVER="level9-driver-${UNIQ_TAG}@test.com"
TEST_NAME_DRIVER="Level9 Driver ${UNIQ_TAG}"
TEST_EMAIL_ADMIN="level9-admin-${UNIQ_TAG}@test.com"
TEST_NAME_ADMIN="Level9 Admin ${UNIQ_TAG}"
TEST_EMAIL_REPLAY="level9-replay-${UNIQ_TAG}@test.com"
TEST_NAME_REPLAY="Level9 Replay User ${UNIQ_TAG}"

USER_AUTH="$(register_and_login_user "$TEST_EMAIL_USER" "$TEST_NAME_USER" "user")"
USER_TOKEN="${USER_AUTH%%|*}"
USER_ID="${USER_AUTH##*|}"

DRIVER_AUTH="$(register_and_login_user "$TEST_EMAIL_DRIVER" "$TEST_NAME_DRIVER" "driver")"
DRIVER_TOKEN="${DRIVER_AUTH%%|*}"
DRIVER_ID="${DRIVER_AUTH##*|}"

ADMIN_AUTH="$(register_and_login_user "$TEST_EMAIL_ADMIN" "$TEST_NAME_ADMIN" "admin")"
ADMIN_TOKEN="${ADMIN_AUTH%%|*}"
ADMIN_ID="${ADMIN_AUTH##*|}"

# Provision dedicated replay user before rate-limit attack to avoid auth limiter interference in case 86.
REPLAY_AUTH="$(register_and_login_user "$TEST_EMAIL_REPLAY" "$TEST_NAME_REPLAY" "user")"
REPLAY_TOKEN="${REPLAY_AUTH%%|*}"
REPLAY_USER_ID="${REPLAY_AUTH##*|}"

if [[ -z "$USER_TOKEN" || -z "$USER_ID" ]]; then
  echo "WARN: cannot provision standard user token; cases requiring auth may fail."
fi
if [[ -z "$ADMIN_TOKEN" || -z "$ADMIN_ID" ]]; then
  echo "WARN: cannot provision admin token; RBAC allow-path check may fail."
fi
if [[ -z "$DRIVER_TOKEN" || -z "$DRIVER_ID" ]]; then
  echo "WARN: cannot provision driver token; driver RBAC deny-path check may fail."
fi
if [[ -z "$REPLAY_TOKEN" || -z "$REPLAY_USER_ID" ]]; then
  echo "WARN: cannot provision dedicated replay user token before rate-limit scenario."
fi

create_booking_payload='{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","distance_km":5,"traffic_level":0.5}'

# Case 81: SQL injection attempt
if ensure_gateway_ready "81"; then
  C81_OK=1
  C81_REPORT=""

  C81_A=$(call_gateway_json POST "/v1/auth/login" "" "{\"email\":\"' OR 1=1 --\",\"password\":\"anything\"}")
  C81_A_STATUS=$(echo "$C81_A" | sed -n '1p')
  C81_A_BODY=$(echo "$C81_A" | sed '1d')
  C81_REPORT="${C81_REPORT}probe=login_identifier status=${C81_A_STATUS}\n"
  if [[ "$C81_A_STATUS" != "400" && "$C81_A_STATUS" != "401" ]]; then
    C81_OK=0
  fi
  if contains_security_leak "$C81_A_BODY"; then
    C81_OK=0
  fi

  C81_B=$(call_gateway_json GET "/v1/users?email=%27%20OR%20%271%27=%271" "$ADMIN_TOKEN")
  C81_B_STATUS=$(echo "$C81_B" | sed -n '1p')
  C81_B_BODY=$(echo "$C81_B" | sed '1d')
  C81_REPORT="${C81_REPORT}supplemental_probe=users_query status=${C81_B_STATUS}\n"
  if [[ "$C81_B_STATUS" == "200" || "$C81_B_STATUS" == "201" ]]; then
    C81_OK=0
  fi
  if contains_security_leak "$C81_B_BODY"; then
    C81_OK=0
  fi

  C81_C=$(call_gateway_json GET "/v1/bookings/%27%20OR%20%271%27=%271" "$USER_TOKEN")
  C81_C_STATUS=$(echo "$C81_C" | sed -n '1p')
  C81_C_BODY=$(echo "$C81_C" | sed '1d')
  C81_REPORT="${C81_REPORT}supplemental_probe=booking_id_path status=${C81_C_STATUS}\n"
  if [[ "$C81_C_STATUS" == "200" || "$C81_C_STATUS" == "201" ]]; then
    C81_OK=0
  fi
  if contains_security_leak "$C81_C_BODY"; then
    C81_OK=0
  fi

  C81_HEALTH=$(http_status "$BASE_URL/health")
  C81_REPORT="${C81_REPORT}gateway_health_after_probes=${C81_HEALTH}\n"
  if [[ "$C81_HEALTH" != "200" ]]; then
    C81_OK=0
  fi

  print_case "Case 81 - SQL injection attempt" \
    "POST /v1/auth/login with {\"email\":\"' OR 1=1 --\",\"password\":\"anything\"} (supplemental probes may also run)" \
    "No auth bypass, no SQL/raw stack leak, only defensive status (400/401/403/404), gateway remains healthy" \
    "local-check" "$C81_REPORT"
  mark_result "$C81_OK" "81"
fi

# Case 82: XSS input test
if ensure_gateway_ready "82"; then
  C82_PAYLOAD='{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"<script>alert('\''hack'\'')</script>","distance_km":5,"traffic_level":0.5}'
  C82=$(call_gateway_json POST "/v1/bookings" "$USER_TOKEN" "$C82_PAYLOAD")
  C82_STATUS=$(echo "$C82" | sed -n '1p')
  C82_BODY=$(echo "$C82" | sed '1d')
  C82_OK=1

  if [[ "$C82_STATUS" != "200" && "$C82_STATUS" != "201" && "$C82_STATUS" != "400" && "$C82_STATUS" != "422" ]]; then
    C82_OK=0
  fi
  if echo "$C82_BODY" | grep -Eiq "<script|</script>|alert\\("; then
    C82_OK=0
  fi
  if contains_security_leak "$C82_BODY"; then
    C82_OK=0
  fi
  C82_HEALTH=$(http_status "$BASE_URL/health")
  if [[ "$C82_HEALTH" != "200" ]]; then
    C82_OK=0
  fi

  print_case "Case 82 - XSS input test" \
    "POST /v1/bookings with vehicle_type=<script>alert('hack')</script>" \
    "Script payload is escaped/rejected (no raw executable reflection), system remains healthy" \
    "$C82_STATUS" "$C82_BODY"
  mark_result "$C82_OK" "82"
fi

# Case 83: JWT tampering
if ensure_gateway_ready "83"; then
  C83_OK=1
  C83_REPORT=""

  C83_BAD_SIG="${USER_TOKEN}x"
  C83_BAD_ROLE="$(tamper_jwt_role_token "$USER_TOKEN")"
  C83_MALFORMED="abc.def"

  C83_A=$(call_gateway_json GET "/v1/users?limit=1" "$C83_BAD_SIG")
  C83_A_STATUS=$(echo "$C83_A" | sed -n '1p')
  C83_A_BODY=$(echo "$C83_A" | sed '1d')
  C83_REPORT="${C83_REPORT}bad_signature_status=${C83_A_STATUS}\n"
  if [[ "$C83_A_STATUS" != "401" ]]; then C83_OK=0; fi
  if contains_security_leak "$C83_A_BODY"; then C83_OK=0; fi

  C83_B=$(call_gateway_json GET "/v1/users?limit=1" "$C83_BAD_ROLE")
  C83_B_STATUS=$(echo "$C83_B" | sed -n '1p')
  C83_B_BODY=$(echo "$C83_B" | sed '1d')
  C83_REPORT="${C83_REPORT}role_escalation_tamper_status=${C83_B_STATUS}\n"
  if [[ "$C83_B_STATUS" != "401" ]]; then C83_OK=0; fi
  if contains_security_leak "$C83_B_BODY"; then C83_OK=0; fi

  C83_C=$(call_gateway_json GET "/v1/users?limit=1" "$C83_MALFORMED")
  C83_C_STATUS=$(echo "$C83_C" | sed -n '1p')
  C83_C_BODY=$(echo "$C83_C" | sed '1d')
  C83_REPORT="${C83_REPORT}malformed_status=${C83_C_STATUS}\n"
  if [[ "$C83_C_STATUS" != "401" ]]; then C83_OK=0; fi
  if contains_security_leak "$C83_C_BODY"; then C83_OK=0; fi

  C83_D=$(call_gateway_json GET "/v1/users?limit=1" "$USER_TOKEN")
  C83_D_STATUS=$(echo "$C83_D" | sed -n '1p')
  C83_REPORT="${C83_REPORT}baseline_valid_user_token_status=${C83_D_STATUS}\n"
  if [[ "$C83_D_STATUS" == "200" ]]; then
    C83_REPORT="${C83_REPORT}note=baseline_user_is_forbidden_expected\n"
  fi

  print_case "Case 83 - JWT tampering" \
    "Test invalid signature, role-payload tamper, malformed token on protected admin endpoint" \
    "All tampered tokens rejected with HTTP 401, no sensitive leak, no role bypass" \
    "local-check" "$C83_REPORT"
  mark_result "$C83_OK" "83"
fi

# Case 84: Unauthorized API access
if ensure_gateway_ready "84"; then
  C84_USER=$(call_gateway_json GET "/v1/admin/drivers?limit=1" "$USER_TOKEN")
  C84_USER_STATUS=$(echo "$C84_USER" | sed -n '1p')
  C84_USER_BODY=$(echo "$C84_USER" | sed '1d')

  C84_ADMIN_STATUS="NO_EVIDENCE"
  C84_ADMIN_BODY=""
  if [[ -n "$ADMIN_TOKEN" ]]; then
    C84_ADMIN=$(call_gateway_json GET "/v1/admin/drivers?limit=1" "$ADMIN_TOKEN")
    C84_ADMIN_STATUS=$(echo "$C84_ADMIN" | sed -n '1p')
    C84_ADMIN_BODY=$(echo "$C84_ADMIN" | sed '1d')
  fi

  C84_OK=1
  if [[ "$C84_USER_STATUS" != "403" ]]; then C84_OK=0; fi
  if [[ "$C84_ADMIN_STATUS" != "NO_EVIDENCE" && "$C84_ADMIN_STATUS" != "200" ]]; then C84_OK=0; fi
  if contains_security_leak "$C84_USER_BODY$C84_ADMIN_BODY"; then C84_OK=0; fi

  C84_ACTUAL="user_status=$C84_USER_STATUS; admin_baseline_status=$C84_ADMIN_STATUS"
  print_case "Case 84 - Unauthorized API access" \
    "GET /v1/admin/drivers?limit=1 with USER token (and optional ADMIN baseline)" \
    "USER must be forbidden (403); admin baseline should be 200 when available" \
    "local-check" "$C84_ACTUAL"
  mark_result "$C84_OK" "84"
fi

# Case 85: Rate limit attack
if ensure_gateway_ready "85"; then
  if [[ -z "$USER_TOKEN" ]]; then
    mark_no_evidence_fail "85" "cannot run booking rate-limit test without authenticated user token"
  else
    C85_RESULT=$(BASE_URL="$BASE_URL" CASE85_TARGET_PATH="$CASE85_TARGET_PATH" USER_TOKEN="$USER_TOKEN" CASE85_BURST_COUNT="$CASE85_BURST_COUNT" CASE85_CONCURRENCY="$CASE85_CONCURRENCY" CASE85_MAX_TIME_MS="$CASE85_MAX_TIME_MS" node - <<'NODE'
const baseUrl = process.env.BASE_URL || 'http://localhost:42100';
const path = process.env.CASE85_TARGET_PATH || '/v1/bookings';
const token = process.env.USER_TOKEN || '';
const total = Number(process.env.CASE85_BURST_COUNT || 1400);
const concurrency = Number(process.env.CASE85_CONCURRENCY || 200);
const maxTimeMs = Number(process.env.CASE85_MAX_TIME_MS || 8000);
const bookingUrl = `${baseUrl.replace(/\/$/, '')}${path}`;
let idx = 0;
const counts = {};
const startedAt = Date.now();

function buildBody(i) {
  const jitter = (i % 25) * 0.00001;
  return {
    pickup: { lat: 10.7601 + jitter, lng: 106.6601 + jitter },
    drop: { lat: 10.7701 + jitter, lng: 106.7001 + jitter },
    vehicle_type: 'CAR',
    distance_km: 5,
    traffic_level: 0.5
  };
}

async function once(i) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), maxTimeMs);
  try {
    const response = await fetch(bookingUrl, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
        'x-load-test': 'security-rate-limit',
        'idempotency-key': `c85-${Date.now()}-${i}`
      },
      body: JSON.stringify(buildBody(i)),
      signal: controller.signal
    });
    const code = String(response.status);
    counts[code] = (counts[code] || 0) + 1;
  } catch (_e) {
    counts['000'] = (counts['000'] || 0) + 1;
  } finally {
    clearTimeout(timer);
  }
}

async function worker() {
  while (true) {
    const current = idx++;
    if (current >= total) return;
    await once(current);
  }
}

Promise.all(Array.from({ length: Math.max(1, concurrency) }, () => worker())).then(() => {
  const elapsedSec = Math.max(0.001, (Date.now() - startedAt) / 1000);
  process.stdout.write(JSON.stringify({ path, total, concurrency, elapsed_sec: elapsedSec, achieved_rps: total / elapsedSec, status_counts: counts }));
});
NODE
    )
    C85_429=$(echo "$C85_RESULT" | json_get "status_counts.429")
    C85_000=$(echo "$C85_RESULT" | json_get "status_counts.000")
    C85_5XX=$(echo "$C85_RESULT" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));const sc=j.status_counts||{};let t=0;for(const [k,v] of Object.entries(sc)){const c=Number(k);if(Number.isFinite(c)&&c>=500&&c<600)t+=Number(v)||0;}process.stdout.write(String(t));")
    C85_HEALTH=$(http_status "$BASE_URL/health")

    C85_OK=1
    if [[ -z "$C85_429" ]]; then C85_429=0; fi
    if [[ -z "$C85_000" ]]; then C85_000=0; fi
    if [[ -z "$C85_5XX" ]]; then C85_5XX=0; fi
    if (( C85_429 < CASE85_MIN_429 )); then
      C85_OK=0
    fi
    if [[ "$C85_HEALTH" != "200" ]]; then
      C85_OK=0
    fi
    if (( C85_5XX > 0 )); then
      C85_OK=0
    fi

    print_case "Case 85 - Rate limit attack" \
      "Burst POST ${CASE85_TARGET_PATH} targeting >1000 requests/second (count=$CASE85_BURST_COUNT, concurrency=$CASE85_CONCURRENCY)" \
      "Rate limiter triggers HTTP 429, system still healthy, no backend collapse (no 5xx flood)" \
      "local-check" "$C85_RESULT"
    mark_result "$C85_OK" "85"
  fi
fi

# Case 86: Replay attack (idempotency)
if ensure_gateway_ready "86"; then
  C86_TOKEN="$REPLAY_TOKEN"
  C86_USER_ID="$REPLAY_USER_ID"
  if [[ -z "$C86_TOKEN" || -z "$C86_USER_ID" ]]; then
    mark_no_evidence_fail "86" "cannot run replay test without authenticated user token"
  else
    C86_RIDE_ID="ride-replay-${UNIQ_TAG}-${RANDOM}"
    C86_PAYLOAD="{\"rideId\":\"$C86_RIDE_ID\",\"amount\":\"50000\",\"currency\":\"VND\",\"userId\":\"$C86_USER_ID\"}"
    C86_LIST_BEFORE=$(call_gateway_json GET "/v1/payments?rideId=$C86_RIDE_ID&limit=50" "$C86_TOKEN")
    C86_LIST_BEFORE_STATUS=$(echo "$C86_LIST_BEFORE" | sed -n '1p')
    C86_LIST_BEFORE_BODY=$(echo "$C86_LIST_BEFORE" | sed '1d')
    C86_COUNT_BEFORE=$(echo "$C86_LIST_BEFORE_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(String(Array.isArray(j.data)?j.data.length:0));}catch(e){process.stdout.write('0')}})")

    C86_IDEM="level9-idem-${UNIQ_TAG}-${RANDOM}"
    C86_FIRST=$(call_gateway_json POST "/v1/payments" "$C86_TOKEN" "$C86_PAYLOAD" "Idempotency-Key" "$C86_IDEM")
    C86_FIRST_STATUS=$(echo "$C86_FIRST" | sed -n '1p')
    C86_FIRST_BODY=$(echo "$C86_FIRST" | sed '1d')
    C86_FIRST_PID=$(echo "$C86_FIRST_BODY" | json_get "data.id")

    C86_SECOND=$(call_gateway_json POST "/v1/payments" "$C86_TOKEN" "$C86_PAYLOAD" "Idempotency-Key" "$C86_IDEM")
    C86_SECOND_STATUS=$(echo "$C86_SECOND" | sed -n '1p')
    C86_SECOND_BODY=$(echo "$C86_SECOND" | sed '1d')
    C86_SECOND_PID=$(echo "$C86_SECOND_BODY" | json_get "data.id")

    C86_LIST_AFTER=$(call_gateway_json GET "/v1/payments?rideId=$C86_RIDE_ID&limit=50" "$C86_TOKEN")
    C86_LIST_AFTER_STATUS=$(echo "$C86_LIST_AFTER" | sed -n '1p')
    C86_LIST_AFTER_BODY=$(echo "$C86_LIST_AFTER" | sed '1d')
    C86_COUNT_AFTER=$(echo "$C86_LIST_AFTER_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(String(Array.isArray(j.data)?j.data.length:0));}catch(e){process.stdout.write('0')}})")

    C86_COUNT_DIFF=$((C86_COUNT_AFTER - C86_COUNT_BEFORE))
    C86_OK=1
    if [[ "$C86_FIRST_STATUS" != "201" ]]; then
      C86_OK=0
    fi
    if [[ "$C86_SECOND_STATUS" != "201" && "$C86_SECOND_STATUS" != "200" ]]; then
      C86_OK=0
    fi
    if [[ -z "$C86_FIRST_PID" || -z "$C86_SECOND_PID" || "$C86_FIRST_PID" != "$C86_SECOND_PID" ]]; then
      C86_OK=0
    fi
    if (( C86_COUNT_DIFF > 1 )); then
      C86_OK=0
    fi
    if [[ "$C86_LIST_BEFORE_STATUS" != "200" || "$C86_LIST_AFTER_STATUS" != "200" ]]; then
      C86_OK=0
    fi

    C86_ACTUAL="ride_id=$C86_RIDE_ID idem=$C86_IDEM; first_status=$C86_FIRST_STATUS first_payment_id=$C86_FIRST_PID; second_status=$C86_SECOND_STATUS second_payment_id=$C86_SECOND_PID; before_count=$C86_COUNT_BEFORE after_count=$C86_COUNT_AFTER diff=$C86_COUNT_DIFF"
    print_case "Case 86 - Replay attack (idempotency)" \
      "POST /v1/payments twice with same idempotency key and same payload ({userId:$C86_USER_ID, amount:50000})" \
      "No duplicate transaction/double charge: second response replays same payment, records growth <= 1" \
      "local-check" "$C86_ACTUAL"
    mark_result "$C86_OK" "86"
  fi
fi

# Case 87: Data encryption at rest
C87_EVIDENCE="$(load_evidence_text "$CASE87_EVIDENCE_FILE" "$CASE87_EVIDENCE_TEXT")"
C87_STATUS="NO_EVIDENCE"
C87_OK=0
if [[ -n "$C87_EVIDENCE" ]]; then
  C87_STORAGE_OK=0
  C87_CRYPTO_OK=0
  if text_matches_pattern "$C87_EVIDENCE" '(storage|volume|disk|filesystem|persistent|pvc|pv|postgres|mongo|redis|database)'; then
    C87_STORAGE_OK=1
  fi
  if text_matches_pattern "$C87_EVIDENCE" '(encrypt|encrypted|encryption|at[ -]?rest|kms|key management|luks|dm-crypt|aes[- ]?256|bitlocker|vault)'; then
    C87_CRYPTO_OK=1
  fi
  if [[ "$C87_STORAGE_OK" == "1" && "$C87_CRYPTO_OK" == "1" ]]; then
    C87_STATUS="EVIDENCE_OK"
    C87_OK=1
  else
    C87_STATUS="INSUFFICIENT_EVIDENCE"
  fi
fi
C87_BODY="evidence_file=${CASE87_EVIDENCE_FILE:-<none>}; has_evidence=$([[ -n "$C87_EVIDENCE" ]] && echo 1 || echo 0); storage_signal=$([[ "${C87_STORAGE_OK:-0}" == "1" ]] && echo 1 || echo 0); encryption_signal=$([[ "${C87_CRYPTO_OK:-0}" == "1" ]] && echo 1 || echo 0)"
print_case "Case 87 - Data encryption at rest" \
  "Verify storage-level encryption evidence (DB volume/KMS/storage policy and runtime proof)" \
  "Sensitive data at rest must be encrypted and verifiable by concrete infra evidence" \
  "$C87_STATUS" "$C87_BODY"
mark_result "$C87_OK" "87"

# Case 88: mTLS communication
C88_EVIDENCE="$(load_evidence_text "$CASE88_EVIDENCE_FILE" "$CASE88_EVIDENCE_TEXT")"
C88_STATUS="NO_EVIDENCE"
C88_OK=0
if [[ -n "$C88_EVIDENCE" ]]; then
  C88_MTLS_SIGNAL=0
  C88_REJECT_SIGNAL=0
  if text_matches_pattern "$C88_EVIDENCE" '(mtls|mutual tls|client cert|client certificate|x509|spiffe|tls handshake|ssl handshake|certificate chain)'; then
    C88_MTLS_SIGNAL=1
  fi
  if text_matches_pattern "$C88_EVIDENCE" '(reject|rejected|denied|forbidden|unknown ca|bad certificate|certificate required|no certificate|handshake fail|tlsv1 alert)'; then
    C88_REJECT_SIGNAL=1
  fi
  if [[ "$C88_MTLS_SIGNAL" == "1" && "$C88_REJECT_SIGNAL" == "1" ]]; then
    C88_STATUS="EVIDENCE_OK"
    C88_OK=1
  else
    C88_STATUS="INSUFFICIENT_EVIDENCE"
  fi
fi
C88_BODY="evidence_file=${CASE88_EVIDENCE_FILE:-<none>}; has_evidence=$([[ -n "$C88_EVIDENCE" ]] && echo 1 || echo 0); mtls_signal=$([[ "${C88_MTLS_SIGNAL:-0}" == "1" ]] && echo 1 || echo 0); reject_signal=$([[ "${C88_REJECT_SIGNAL:-0}" == "1" ]] && echo 1 || echo 0)"
print_case "Case 88 - mTLS communication" \
  "Verify service-to-service mTLS with handshake/cert-chain/identity evidence from mesh or PKI runtime" \
  "All internal service communication must enforce mTLS and reject invalid/no-cert callers" \
  "$C88_STATUS" "$C88_BODY"
mark_result "$C88_OK" "88"

# Case 89: RBAC enforcement
if ensure_gateway_ready "89"; then
  if [[ -z "$DRIVER_TOKEN" || -z "$ADMIN_TOKEN" ]]; then
    mark_no_evidence_fail "89" "cannot run RBAC test because driver/admin token provisioning failed"
  else
    C89_DRIVER=$(call_gateway_json GET "/v1/admin/drivers?limit=1" "$DRIVER_TOKEN")
    C89_DRIVER_STATUS=$(echo "$C89_DRIVER" | sed -n '1p')
    C89_DRIVER_BODY=$(echo "$C89_DRIVER" | sed '1d')

    C89_ADMIN=$(call_gateway_json GET "/v1/admin/drivers?limit=1" "$ADMIN_TOKEN")
    C89_ADMIN_STATUS=$(echo "$C89_ADMIN" | sed -n '1p')
    C89_ADMIN_BODY=$(echo "$C89_ADMIN" | sed '1d')
    C89_ADMIN_COUNT=$(echo "$C89_ADMIN_BODY" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(String(Array.isArray(j.data)?j.data.length:-1));}catch(e){process.stdout.write('-1')}})")

    C89_OK=1
    if [[ "$C89_DRIVER_STATUS" != "403" ]]; then C89_OK=0; fi
    if [[ "$C89_ADMIN_STATUS" != "200" ]]; then C89_OK=0; fi
    if [[ "$C89_ADMIN_COUNT" == "-1" ]]; then C89_OK=0; fi
    if contains_security_leak "$C89_DRIVER_BODY$C89_ADMIN_BODY"; then C89_OK=0; fi

    C89_ACTUAL="driver_status=$C89_DRIVER_STATUS; admin_status=$C89_ADMIN_STATUS; admin_list_count=$C89_ADMIN_COUNT"
    print_case "Case 89 - RBAC enforcement" \
      "GET /v1/admin/drivers?limit=1 with role=driver token and role=admin token" \
      "driver denied (403), admin allowed (200), no unauthorized resource access" \
      "local-check" "$C89_ACTUAL"
    mark_result "$C89_OK" "89"
  fi
fi

# Case 90: Sensitive data masking
if ensure_gateway_ready "90"; then
  C90_RAW_CARD="4111111111111111"
  C90_A=$(call_gateway_json GET "/v1/users?limit=1" "fake.jwt.token")
  C90_A_STATUS=$(echo "$C90_A" | sed -n '1p')
  C90_A_BODY=$(echo "$C90_A" | sed '1d')

  C90_B=$(call_gateway_json POST "/v1/payments" "$USER_TOKEN" "{\"rideId\":\"ride_sensitive_test_${UNIQ_TAG}\",\"amount\":\"100000\",\"currency\":\"VND\",\"note\":\"card=${C90_RAW_CARD}\"}" "Idempotency-Key" "c90-${UNIQ_TAG}")
  C90_B_STATUS=$(echo "$C90_B" | sed -n '1p')
  C90_B_BODY=$(echo "$C90_B" | sed '1d')
  C90_B_PAYMENT_ID=$(echo "$C90_B_BODY" | json_get "data.id")
  C90_B_NOTE=$(echo "$C90_B_BODY" | json_get "data.note")
  C90_B_CARD_LEAK=0
  if [[ "$C90_B_BODY" == *"$C90_RAW_CARD"* || "$C90_B_NOTE" == *"$C90_RAW_CARD"* ]]; then
    C90_B_CARD_LEAK=1
  fi

  C90_C=$(call_gateway_json GET "/v1/nonexistent-domain/anything" "")
  C90_C_STATUS=$(echo "$C90_C" | sed -n '1p')
  C90_C_BODY=$(echo "$C90_C" | sed '1d')

  C90_OK=1
  if contains_security_leak "$C90_A_BODY$C90_B_BODY$C90_C_BODY"; then
    C90_OK=0
  fi
  if [[ "$C90_B_CARD_LEAK" == "1" ]]; then
    C90_OK=0
  fi
  if [[ "$C90_A_STATUS" != "401" && "$C90_A_STATUS" != "403" ]]; then
    C90_OK=0
  fi
  if [[ "$C90_C_STATUS" != "404" ]]; then
    C90_OK=0
  fi

  C90_LOG_CHECK_STATUS="NO_EVIDENCE"
  C90_LOG_CHECK_NOTE="runtime logs not accessible from script context"
  if command -v docker >/dev/null 2>&1; then
    C90_LOG_TARGETS="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'api-gateway|payment-service' || true)"
    if [[ -n "$C90_LOG_TARGETS" ]]; then
      C90_LOGS=""
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        C90_LOGS="$C90_LOGS"$'\n'"[$svc]"$'\n'"$(docker logs --tail=120 "$svc" 2>&1 || true)"
      done <<< "$C90_LOG_TARGETS"
      if contains_security_leak "$C90_LOGS" || [[ "$C90_LOGS" == *"$C90_RAW_CARD"* ]]; then
        C90_OK=0
        C90_LOG_CHECK_STATUS="FAIL"
        C90_LOG_CHECK_NOTE="sensitive pattern or raw card number detected in log sample"
      else
        C90_LOG_CHECK_STATUS="PASS"
        C90_LOG_CHECK_NOTE="no sensitive pattern in gateway/payment log sample"
      fi
    fi
  fi

  C90_ACTUAL="probe1_invalid_token_status=$C90_A_STATUS; probe2_payment_status=$C90_B_STATUS payment_id=$C90_B_PAYMENT_ID card_leak=$C90_B_CARD_LEAK; probe3_unknown_domain_status=$C90_C_STATUS; log_check=$C90_LOG_CHECK_STATUS ($C90_LOG_CHECK_NOTE)"
  print_case "Case 90 - Sensitive data masking" \
    "Request payment path with sensitive card-like value, inspect API responses + optional gateway/payment logs" \
    "No full card number leakage; sensitive data masked/absent in response and logs" \
    "local-check" "$C90_ACTUAL"
  mark_result "$C90_OK" "90"
fi

echo "========================================="
echo "LEVEL 9 SUMMARY (Cases 81-90)"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
