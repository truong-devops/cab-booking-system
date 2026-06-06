#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="http://localhost:42100"
BASE_URL="${1:-${BASE_URL:-$DEFAULT_BASE_URL}}"
BOOKING_URL="${BOOKING_URL:-http://localhost:42104}"
USER_PASS="${USER_PASS:-123456}"
JWT_SECRET="${JWT_SECRET:-dev-secret}"
UNIQ_TAG="$(date +%s)-$RANDOM"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-25}"

CASE98_BURST_COUNT="${CASE98_BURST_COUNT:-120}"
CASE98_CONCURRENCY="${CASE98_CONCURRENCY:-24}"
CASE98_MIN_429="${CASE98_MIN_429:-1}"
CASE98_MAX_TIME_MS="${CASE98_MAX_TIME_MS:-4000}"
AUTH_BOOTSTRAP_ATTEMPTS="${AUTH_BOOTSTRAP_ATTEMPTS:-20}"
AUTH_BOOTSTRAP_RETRY_DELAY_SEC="${AUTH_BOOTSTRAP_RETRY_DELAY_SEC:-3}"
AUTH_BOOTSTRAP_COOLDOWN_SEC="${AUTH_BOOTSTRAP_COOLDOWN_SEC:-65}"
LEVEL10_ADMIN_DASHBOARD_PATH="${LEVEL10_ADMIN_DASHBOARD_PATH:-/v1/admin/dashboard}"
LEVEL10_ADMIN_FALLBACK_PATH="${LEVEL10_ADMIN_FALLBACK_PATH:-/v1/admin/drivers?limit=1}"
CASE94_EVIDENCE_FILE="${CASE94_EVIDENCE_FILE:-}"
CASE94_EVIDENCE_TEXT="${CASE94_EVIDENCE_TEXT:-}"
DEFAULT_CASE94_EVIDENCE_FILE="$SCRIPT_DIR/evidence/case94-mtls-service-to-service.txt"
CASE100_LOGIN_MAX_ATTEMPTS="${CASE100_LOGIN_MAX_ATTEMPTS:-6}"
CASE100_LOGIN_RETRY_DELAY_SEC="${CASE100_LOGIN_RETRY_DELAY_SEC:-2}"
CASE100_LOGIN_COOLDOWN_SEC="${CASE100_LOGIN_COOLDOWN_SEC:-$AUTH_BOOTSTRAP_COOLDOWN_SEC}"
CASE99_TLS_PORT="${CASE99_TLS_PORT:-42101}"
CASE99_BASE_HOST="${CASE99_BASE_HOST:-}"
if [[ -z "$CASE94_EVIDENCE_FILE" && -f "$DEFAULT_CASE94_EVIDENCE_FILE" ]]; then
  CASE94_EVIDENCE_FILE="$DEFAULT_CASE94_EVIDENCE_FILE"
fi
if [[ -z "$CASE94_EVIDENCE_FILE" && -f "./scripts/evidence/case94-mtls-service-to-service.txt" ]]; then
  CASE94_EVIDENCE_FILE="./scripts/evidence/case94-mtls-service-to-service.txt"
fi
if [[ -z "$CASE99_BASE_HOST" ]]; then
  CASE99_BASE_HOST="${BASE_URL#http://}"
  CASE99_BASE_HOST="${CASE99_BASE_HOST#https://}"
  CASE99_BASE_HOST="${CASE99_BASE_HOST%%/*}"
  CASE99_BASE_HOST="${CASE99_BASE_HOST%%:*}"
fi
if [[ -z "$CASE99_BASE_HOST" ]]; then
  CASE99_BASE_HOST="localhost"
fi
CASE99_HTTP_BASE_URL="${CASE99_HTTP_BASE_URL:-http://$CASE99_BASE_HOST:$CASE99_TLS_PORT}"
CASE99_HTTPS_BASE_URL="${CASE99_HTTPS_BASE_URL:-https://$CASE99_BASE_HOST:$CASE99_TLS_PORT}"
CASE99_EXPECT_HTTPS_STATUS="${CASE99_EXPECT_HTTPS_STATUS:-200}"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/case-context-input.sh"

print_usage() {
  cat <<USAGE
Usage:
  ./scripts/test-level10-91-100cases.sh [BASE_URL]

Examples:
  ./scripts/test-level10-91-100cases.sh
  ./scripts/test-level10-91-100cases.sh http://localhost:42100

Notes:
  - Default BASE_URL: $DEFAULT_BASE_URL
  - Case 94 (mTLS) requires concrete runtime evidence; if unavailable, this case FAILS.
  - Case 99 uses CASE99_HTTP_BASE_URL / CASE99_HTTPS_BASE_URL for probe URLs.
  - Case 100 (audit logging) FAILS when runtime log evidence is unavailable.
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

register_and_login_user() {
  local email="$1"
  local name="$2"
  local role="${3:-user}"

  call_gateway_json POST "/v1/auth/register" "" "{\"email\":\"$email\",\"password\":\"$USER_PASS\",\"name\":\"$name\",\"role\":\"$role\"}" >/dev/null || true

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
    local user_id
    user_id=$(extract_user_id "$body")
    if [[ -n "$token" && -n "$user_id" ]]; then
      printf '%s|%s\n' "$token" "$user_id"
      return 0
    fi

    sleep "$AUTH_BOOTSTRAP_RETRY_DELAY_SEC"
    i=$((i + 1))
  done

  echo "|"
}

tamper_jwt_payload_without_resign() {
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

create_expired_token() {
  local subject="$1"
  local role="$2"
  local secret="$3"
  node - "$subject" "$role" "$secret" <<'NODE'
const jwt = require('jsonwebtoken');
const sub = process.argv[2] || '';
const role = process.argv[3] || 'user';
const secret = process.argv[4] || '';
if (!sub || !secret) {
  process.stdout.write('');
  process.exit(0);
}
const token = jwt.sign({ sub, role, roles: [role] }, secret, { algorithm: 'HS256', expiresIn: -60 });
process.stdout.write(token);
NODE
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

contains_security_leak() {
  local content="$1"
  if [[ -z "$content" ]]; then
    return 1
  fi
  local pattern
  pattern="(password_hash|x-api-key|api[_-]?key\\s*[:=]|jwt[_-]?secret|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY|select\\s+.+\\s+from\\s+|syntax error at or near|Sequelize|SQLSTATE|ECONNREFUSED|Error:\\s+at\\s+|\\\"cvv\\\"\\s*:|\\\"card(number|_number)?\\\"\\s*:)"
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

echo "== Setup for Level 10 zero trust security tests =="
if ! ensure_gateway_ready "setup"; then
  echo "STOP: gateway is not ready"
  exit 1
fi

TEST_EMAIL_USER="level10-user-${UNIQ_TAG}@test.com"
TEST_NAME_USER="Level10 User ${UNIQ_TAG}"
TEST_EMAIL_ADMIN="level10-admin-${UNIQ_TAG}@test.com"
TEST_NAME_ADMIN="Level10 Admin ${UNIQ_TAG}"
TEST_EMAIL_DRIVER="level10-driver-${UNIQ_TAG}@test.com"
TEST_NAME_DRIVER="Level10 Driver ${UNIQ_TAG}"

USER_AUTH="$(register_and_login_user "$TEST_EMAIL_USER" "$TEST_NAME_USER" "user")"
USER_TOKEN="${USER_AUTH%%|*}"
USER_ID="${USER_AUTH##*|}"

ADMIN_AUTH="$(register_and_login_user "$TEST_EMAIL_ADMIN" "$TEST_NAME_ADMIN" "admin")"
ADMIN_TOKEN="${ADMIN_AUTH%%|*}"
ADMIN_ID="${ADMIN_AUTH##*|}"

DRIVER_AUTH="$(register_and_login_user "$TEST_EMAIL_DRIVER" "$TEST_NAME_DRIVER" "driver")"
DRIVER_TOKEN="${DRIVER_AUTH%%|*}"
DRIVER_ID="${DRIVER_AUTH##*|}"

if [[ -z "$USER_TOKEN" || -z "$ADMIN_TOKEN" || -z "$DRIVER_TOKEN" ]]; then
  echo "INFO: auth token bootstrap incomplete; waiting ${AUTH_BOOTSTRAP_COOLDOWN_SEC}s for auth rate-limit window reset, then retry once."
  sleep "$AUTH_BOOTSTRAP_COOLDOWN_SEC"

  if [[ -z "$USER_TOKEN" || -z "$USER_ID" ]]; then
    USER_AUTH="$(register_and_login_user "$TEST_EMAIL_USER" "$TEST_NAME_USER" "user")"
    USER_TOKEN="${USER_AUTH%%|*}"
    USER_ID="${USER_AUTH##*|}"
  fi
  if [[ -z "$ADMIN_TOKEN" || -z "$ADMIN_ID" ]]; then
    ADMIN_AUTH="$(register_and_login_user "$TEST_EMAIL_ADMIN" "$TEST_NAME_ADMIN" "admin")"
    ADMIN_TOKEN="${ADMIN_AUTH%%|*}"
    ADMIN_ID="${ADMIN_AUTH##*|}"
  fi
  if [[ -z "$DRIVER_TOKEN" || -z "$DRIVER_ID" ]]; then
    DRIVER_AUTH="$(register_and_login_user "$TEST_EMAIL_DRIVER" "$TEST_NAME_DRIVER" "driver")"
    DRIVER_TOKEN="${DRIVER_AUTH%%|*}"
    DRIVER_ID="${DRIVER_AUTH##*|}"
  fi
fi

if [[ -z "$USER_TOKEN" || -z "$USER_ID" ]]; then
  echo "WARN: cannot provision standard user token; cases 92/93/97 may fail."
fi
if [[ -z "$ADMIN_TOKEN" || -z "$ADMIN_ID" ]]; then
  echo "WARN: cannot provision admin token; admin baseline check in case 95 may fail."
fi
if [[ -z "$DRIVER_TOKEN" || -z "$DRIVER_ID" ]]; then
  echo "WARN: cannot provision driver token; case 96 may fail."
fi

create_booking_payload='{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","distance_km":5,"traffic_level":0.5}'

# Case 91: Missing token
if ensure_gateway_ready "91"; then
  C91=$(call_gateway_json GET "/v1/bookings" "")
  C91_STATUS=$(echo "$C91" | sed -n '1p')
  C91_BODY=$(echo "$C91" | sed '1d')
  C91_MSG=$(echo "$C91_BODY" | json_get "error.message")
  if [[ -z "$C91_MSG" ]]; then C91_MSG=$(echo "$C91_BODY" | json_get "message"); fi

  C91_OK=1
  if [[ "$C91_STATUS" != "401" ]]; then C91_OK=0; fi
  if [[ "$C91_MSG" != *"Missing"* && "$C91_MSG" != *"token"* && "$C91_MSG" != *"authorization"* ]]; then C91_OK=0; fi

  print_case "Case 91 - Missing token" \
    "GET /v1/bookings without Authorization header" \
    "HTTP 401 Unauthorized; message indicates missing token; request rejected at API gateway" \
    "$C91_STATUS" "$C91_BODY"
  mark_result "$C91_OK" "91"
fi

# Case 92: Tampered JWT
if ensure_gateway_ready "92"; then
  if [[ -z "$USER_TOKEN" ]]; then
    mark_no_evidence_fail "92" "cannot run tampered JWT test without valid base token"
  else
    C92_TAMPERED="$(tamper_jwt_payload_without_resign "$USER_TOKEN")"
    if [[ -z "$C92_TAMPERED" ]]; then
      mark_no_evidence_fail "92" "failed to build tampered token payload"
    else
      C92=$(call_gateway_json GET "/v1/bookings" "$C92_TAMPERED")
      C92_STATUS=$(echo "$C92" | sed -n '1p')
      C92_BODY=$(echo "$C92" | sed '1d')
      C92_MSG=$(echo "$C92_BODY" | json_get "error.message")
      if [[ -z "$C92_MSG" ]]; then C92_MSG=$(echo "$C92_BODY" | json_get "message"); fi

      C92_OK=1
      if [[ "$C92_STATUS" != "401" ]]; then C92_OK=0; fi
      if [[ "$C92_MSG" != *"Invalid token"* && "$C92_MSG" != *"invalid token"* ]]; then C92_OK=0; fi

      print_case "Case 92 - Tampered JWT" \
        "GET /v1/bookings with payload-tampered JWT (signature unchanged)" \
        "HTTP 401; message indicates invalid token/signature; no token bypass" \
        "$C92_STATUS" "$C92_BODY"
      mark_result "$C92_OK" "92"
    fi
  fi
fi

# Case 93: Expired token
if ensure_gateway_ready "93"; then
  if [[ -z "$USER_ID" ]]; then
    mark_no_evidence_fail "93" "cannot create expired token without known subject"
  else
    C93_EXPIRED_TOKEN="$(create_expired_token "$USER_ID" "user" "$JWT_SECRET")"
    if [[ -z "$C93_EXPIRED_TOKEN" ]]; then
      mark_no_evidence_fail "93" "failed to create expired JWT (jsonwebtoken unavailable or secret missing)"
    else
      C93=$(call_gateway_json GET "/v1/bookings" "$C93_EXPIRED_TOKEN")
      C93_STATUS=$(echo "$C93" | sed -n '1p')
      C93_BODY=$(echo "$C93" | sed '1d')
      C93_MSG=$(echo "$C93_BODY" | json_get "error.message")
      if [[ -z "$C93_MSG" ]]; then C93_MSG=$(echo "$C93_BODY" | json_get "message"); fi

      C93_OK=1
      if [[ "$C93_STATUS" != "401" ]]; then C93_OK=0; fi
      if [[ "$C93_MSG" != *"expired"* && "$C93_MSG" != *"Expired"* && "$C93_MSG" != *"Invalid token"* ]]; then C93_OK=0; fi

      print_case "Case 93 - Expired token" \
        "GET /v1/bookings with JWT exp in the past" \
        "HTTP 401; message indicates token expired/invalid; access denied" \
        "$C93_STATUS" "$C93_BODY"
      mark_result "$C93_OK" "93"
    fi
  fi
fi

# Case 94: mTLS service-to-service
C94_EVIDENCE="$(load_evidence_text "$CASE94_EVIDENCE_FILE" "$CASE94_EVIDENCE_TEXT")"
C94_STATUS="NO_EVIDENCE"
C94_OK=0
if [[ -n "$C94_EVIDENCE" ]]; then
  C94_MTLS_SIGNAL=0
  C94_REJECT_SIGNAL=0
  if text_matches_pattern "$C94_EVIDENCE" '(mtls|mutual tls|client cert|client certificate|x509|spiffe|tls handshake|ssl handshake|certificate chain)'; then
    C94_MTLS_SIGNAL=1
  fi
  if text_matches_pattern "$C94_EVIDENCE" '(reject|rejected|denied|forbidden|unknown ca|bad certificate|certificate required|no certificate|handshake fail|tlsv1 alert)'; then
    C94_REJECT_SIGNAL=1
  fi
  if [[ "$C94_MTLS_SIGNAL" == "1" && "$C94_REJECT_SIGNAL" == "1" ]]; then
    C94_STATUS="EVIDENCE_OK"
    C94_OK=1
  else
    C94_STATUS="INSUFFICIENT_EVIDENCE"
  fi
fi
C94_HAS_EVIDENCE=0
if [[ -n "$C94_EVIDENCE" ]]; then
  C94_HAS_EVIDENCE=1
fi
C94_BODY="evidence_file=${CASE94_EVIDENCE_FILE:-<none>}; has_evidence=$C94_HAS_EVIDENCE; mtls_signal=${C94_MTLS_SIGNAL:-0}; reject_signal=${C94_REJECT_SIGNAL:-0}"
print_case "Case 94 - mTLS service-to-service" \
  "Verify Service A -> Service B calls with valid/invalid client certificates and observe runtime handshake evidence" \
  "Invalid/no certificate must be rejected (mTLS handshake fail) and unauthorized service access denied" \
  "$C94_STATUS" "$C94_BODY"
mark_result "$C94_OK" "94"

# Case 95: RBAC (user calls admin)
if ensure_gateway_ready "95"; then
  if [[ -z "$USER_TOKEN" ]]; then
    mark_no_evidence_fail "95" "cannot run RBAC deny test without user token"
  else
    C95_TARGET_PATH="$LEVEL10_ADMIN_DASHBOARD_PATH"
    C95_USER=$(call_gateway_json GET "$C95_TARGET_PATH" "$USER_TOKEN")
    C95_USER_STATUS=$(echo "$C95_USER" | sed -n '1p')
    C95_USER_BODY=$(echo "$C95_USER" | sed '1d')
    C95_USER_MSG=$(echo "$C95_USER_BODY" | json_get "error.message")
    if [[ -z "$C95_USER_MSG" ]]; then C95_USER_MSG=$(echo "$C95_USER_BODY" | json_get "message"); fi

    C95_ADMIN_STATUS="NO_EVIDENCE"
    C95_ADMIN_BODY=""
    if [[ -n "$ADMIN_TOKEN" ]]; then
      C95_ADMIN=$(call_gateway_json GET "$C95_TARGET_PATH" "$ADMIN_TOKEN")
      C95_ADMIN_STATUS=$(echo "$C95_ADMIN" | sed -n '1p')
      C95_ADMIN_BODY=$(echo "$C95_ADMIN" | sed '1d')
    fi

    C95_OK=1
    if [[ "$C95_USER_STATUS" != "403" ]]; then C95_OK=0; fi
    if [[ "$C95_ADMIN_STATUS" != "NO_EVIDENCE" && "$C95_ADMIN_STATUS" != "200" ]]; then C95_OK=0; fi
    if [[ "$C95_USER_MSG" != *"Access denied"* && "$C95_USER_MSG" != *"Forbidden"* && "$C95_USER_MSG" != *"forbidden"* ]]; then C95_OK=0; fi

    C95_ACTUAL="target_path=$C95_TARGET_PATH; user_status=$C95_USER_STATUS; user_message=${C95_USER_MSG:-<empty>}; admin_baseline_status=$C95_ADMIN_STATUS"
    print_case "Case 95 - RBAC (user calls admin)" \
      "GET /v1/admin/dashboard with token role=USER" \
      "User must be denied with 403 Access denied; admin token should be allowed (200)" \
      "local-check" "$C95_ACTUAL"
    mark_result "$C95_OK" "95"
  fi
fi

# Case 96: Least privilege (driver cannot access other user's data)
if ensure_gateway_ready "96"; then
  if [[ -z "$DRIVER_TOKEN" || -z "$USER_ID" ]]; then
    mark_no_evidence_fail "96" "cannot run least-privilege test without driver token and target user_id"
  else
    C96_TARGET_ID="$USER_ID"
    C96=$(call_gateway_json GET "/v1/users/$C96_TARGET_ID" "$DRIVER_TOKEN")
    C96_STATUS=$(echo "$C96" | sed -n '1p')
    C96_BODY=$(echo "$C96" | sed '1d')

    C96_OK=1
    if [[ "$C96_STATUS" != "403" ]]; then C96_OK=0; fi
    if echo "$C96_BODY" | grep -Eq '"email"|"phone"|"fullName"|"role"'; then C96_OK=0; fi

    print_case "Case 96 - Least privilege" \
      "driver_id token calls GET /v1/users/$C96_TARGET_ID (other user's profile)" \
      "HTTP 403; no user data disclosure" \
      "$C96_STATUS" "$C96_BODY"
    mark_result "$C96_OK" "96"
  fi
fi

# Case 97: Bypass gateway
if ensure_gateway_ready "97"; then
  C97_NOAUTH=$(call_json_url POST "$BOOKING_URL/v1/bookings" "" "$create_booking_payload")
  C97_NOAUTH_STATUS=$(echo "$C97_NOAUTH" | sed -n '1p')
  C97_NOAUTH_BODY=$(echo "$C97_NOAUTH" | sed '1d')

  C97_USER_STATUS="NO_EVIDENCE"
  C97_USER_BODY=""
  if [[ -n "$USER_TOKEN" ]]; then
    C97_USER=$(call_json_url POST "$BOOKING_URL/v1/bookings" "$USER_TOKEN" "$create_booking_payload")
    C97_USER_STATUS=$(echo "$C97_USER" | sed -n '1p')
    C97_USER_BODY=$(echo "$C97_USER" | sed '1d')
  fi

  C97_OK=1
  if [[ "$C97_NOAUTH_STATUS" != "401" && "$C97_NOAUTH_STATUS" != "403" ]]; then C97_OK=0; fi
  if [[ "$C97_USER_STATUS" == "NO_EVIDENCE" ]]; then C97_OK=0; fi
  if [[ "$C97_USER_STATUS" != "NO_EVIDENCE" && "$C97_USER_STATUS" != "401" && "$C97_USER_STATUS" != "403" ]]; then C97_OK=0; fi
  if echo "$C97_NOAUTH_BODY"$'\n'"$C97_USER_BODY" | grep -Eq '"booking_id"|"bookingId"|"ride_id"|"rideId"'; then C97_OK=0; fi

  C97_ACTUAL="internal_booking_url=$BOOKING_URL/v1/bookings; noauth_status=$C97_NOAUTH_STATUS; with_user_token_status=$C97_USER_STATUS"
  print_case "Case 97 - Bypass gateway" \
    "Direct POST to internal booking service (without gateway), both without token and with valid user token" \
    "Request must be denied (401/403); only API Gateway path is allowed" \
    "local-check" "$C97_ACTUAL"
  mark_result "$C97_OK" "97"
fi

# Case 98: Rate limiting
if ensure_gateway_ready "98"; then
  C98_RESULT=$(BASE_URL="$BASE_URL" CASE98_BURST_COUNT="$CASE98_BURST_COUNT" CASE98_CONCURRENCY="$CASE98_CONCURRENCY" CASE98_MAX_TIME_MS="$CASE98_MAX_TIME_MS" node - <<'NODE'
const baseUrl = process.env.BASE_URL || 'http://localhost:42100';
const total = Number(process.env.CASE98_BURST_COUNT || 120);
const concurrency = Number(process.env.CASE98_CONCURRENCY || 24);
const maxTimeMs = Number(process.env.CASE98_MAX_TIME_MS || 4000);
const loginUrl = `${baseUrl.replace(/\/$/, '')}/v1/auth/login`;
let idx = 0;
const counts = {};

async function once(i) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), maxTimeMs);
  try {
    const response = await fetch(loginUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ identifier: `level10-rate-${i}@test.local`, password: 'wrong-password' }),
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
  process.stdout.write(JSON.stringify({ total, concurrency, status_counts: counts }));
});
NODE
)

  C98_429=$(echo "$C98_RESULT" | json_get "status_counts.429")
  if [[ -z "$C98_429" ]]; then C98_429=0; fi
  C98_000=$(echo "$C98_RESULT" | json_get "status_counts.000")
  if [[ -z "$C98_000" ]]; then C98_000=0; fi
  C98_5XX=$(echo "$C98_RESULT" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));const sc=j.status_counts||{};let t=0;for(const [k,v] of Object.entries(sc)){const c=Number(k);if(Number.isFinite(c)&&c>=500&&c<600)t+=Number(v)||0;}process.stdout.write(String(t));")
  if [[ -z "$C98_5XX" ]]; then C98_5XX=0; fi
  C98_HEALTH=$(http_status "$BASE_URL/health")

  C98_OK=1
  if (( C98_429 < CASE98_MIN_429 )); then C98_OK=0; fi
  if (( C98_000 > 0 )); then C98_OK=0; fi
  if (( C98_5XX > 0 )); then C98_OK=0; fi
  if [[ "$C98_HEALTH" != "200" ]]; then C98_OK=0; fi

  print_case "Case 98 - Rate limiting" \
    "Burst POST /v1/auth/login (count=$CASE98_BURST_COUNT, concurrency=$CASE98_CONCURRENCY)" \
    "Rate limiter must trigger with >=${CASE98_MIN_429} responses 429; no 5xx/timeout flood; system stays healthy" \
    "local-check" "$C98_RESULT"
  mark_result "$C98_OK" "98"
fi

# Case 99: Encryption in transit (HTTPS only)
if ensure_gateway_ready "99"; then
  C99_HTTP_URL="${CASE99_HTTP_BASE_URL%/}/health"
  C99_HTTPS_URL="${CASE99_HTTPS_BASE_URL%/}/health"
  C99_HTTP_STATUS=$(http_status "$C99_HTTP_URL")
  C99_HTTPS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$C99_HTTPS_URL" || true)
  if [[ -z "$C99_HTTPS_STATUS" ]]; then C99_HTTPS_STATUS="000"; fi

  C99_ACTUAL="http_url=$C99_HTTP_URL http_health=$C99_HTTP_STATUS; https_url=$C99_HTTPS_URL https_health=$C99_HTTPS_STATUS; expected_https=$CASE99_EXPECT_HTTPS_STATUS"
  C99_OK=1
  if [[ "$C99_HTTP_STATUS" == "200" ]]; then C99_OK=0; fi
  if [[ "$C99_HTTPS_STATUS" != "$CASE99_EXPECT_HTTPS_STATUS" ]]; then C99_OK=0; fi

  print_case "Case 99 - Encryption in transit (HTTPS only)" \
    "Probe dedicated service transport URL over HTTP vs HTTPS" \
    "HTTP transport must be rejected; only HTTPS / mTLS is allowed" \
    "local-check" "$C99_ACTUAL"
  mark_result "$C99_OK" "99"
fi

# Case 100: Audit logging
if ensure_gateway_ready "100"; then
  C100_LOGIN_TRACE="level10-audit-login-${UNIQ_TAG}-${RANDOM}"
  C100_API_TRACE="level10-audit-api-${UNIQ_TAG}-${RANDOM}"
  C100_LOGIN_STATUS="000"
  C100_LOGIN_BODY='{"error":"login_not_attempted"}'
  C100_LOGIN='000
{"error":"login_not_attempted"}'
  for _attempt in $(seq 1 "$CASE100_LOGIN_MAX_ATTEMPTS"); do
    C100_LOGIN=$(call_gateway_json POST "/v1/auth/login" "" "{\"identifier\":\"$TEST_EMAIL_USER\",\"password\":\"$USER_PASS\"}" "x-trace-id" "$C100_LOGIN_TRACE" "x-force-audit-log" "1")
    C100_LOGIN_STATUS=$(echo "$C100_LOGIN" | sed -n '1p')
    C100_LOGIN_BODY=$(echo "$C100_LOGIN" | sed '1d')
    if [[ "$C100_LOGIN_STATUS" == "200" ]]; then
      break
    fi
    if [[ "$C100_LOGIN_STATUS" != "429" ]]; then
      break
    fi
    if [[ "$_attempt" -lt "$CASE100_LOGIN_MAX_ATTEMPTS" ]]; then
      if [[ "$_attempt" == "1" && "$CASE100_LOGIN_COOLDOWN_SEC" -gt 0 ]]; then
        sleep "$CASE100_LOGIN_COOLDOWN_SEC"
      else
        sleep "$CASE100_LOGIN_RETRY_DELAY_SEC"
      fi
    fi
  done

  C100_API_STATUS="NO_EVIDENCE"
  C100_API_BODY='{"error":"no authenticated user token for protected API audit step"}'
  if [[ -n "$USER_TOKEN" ]]; then
    C100_API=$(call_gateway_json GET "/v1/bookings" "$USER_TOKEN" "" "x-trace-id" "$C100_API_TRACE" "x-force-audit-log" "1")
    C100_API_STATUS=$(echo "$C100_API" | sed -n '1p')
    C100_API_BODY=$(echo "$C100_API" | sed '1d')
  fi

  C100_LOG_ACCESS=0
  C100_LOGIN_FOUND=0
  C100_API_FOUND=0
  C100_API_HAS_ACTION=0
  C100_API_HAS_ACTOR=0
  C100_API_HAS_TIMESTAMP=0
  C100_LOG_NOTE="runtime logs not accessible"

  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^infra-api-gateway-1$'; then
      C100_LOG_ACCESS=1
      C100_LOGS=$(docker logs --tail=500 infra-api-gateway-1 2>&1 || true)
      C100_LOGIN_LINE=$(echo "$C100_LOGS" | grep -F "$C100_LOGIN_TRACE" | grep -F '"event":"security_audit"' | tail -n 1 || true)
      C100_API_LINE=$(echo "$C100_LOGS" | grep -F "$C100_API_TRACE" | grep -F '"event":"security_audit"' | tail -n 1 || true)
      if [[ -n "$C100_LOGIN_LINE" ]]; then
        C100_LOGIN_FOUND=1
      fi
      if [[ -n "$C100_API_LINE" ]]; then
        C100_API_FOUND=1
        if echo "$C100_API_LINE" | grep -Fq '"action":"'; then C100_API_HAS_ACTION=1; fi
        if echo "$C100_API_LINE" | grep -Eq "\"actorId\":\"?$USER_ID\"?"; then C100_API_HAS_ACTOR=1; fi
        if echo "$C100_API_LINE" | grep -Fq '"occurredAt":"'; then C100_API_HAS_TIMESTAMP=1; fi
      fi
      C100_LOG_NOTE="login_found=$C100_LOGIN_FOUND api_found=$C100_API_FOUND api_action=$C100_API_HAS_ACTION api_actorId=$C100_API_HAS_ACTOR api_occurredAt=$C100_API_HAS_TIMESTAMP"
    fi
  fi

  C100_ACTUAL="login_status=$C100_LOGIN_STATUS; api_status=$C100_API_STATUS; login_trace=$C100_LOGIN_TRACE; api_trace=$C100_API_TRACE; log_access=$C100_LOG_ACCESS; login_found=$C100_LOGIN_FOUND; api_found=$C100_API_FOUND; api_has_action=$C100_API_HAS_ACTION; api_has_actorId=$C100_API_HAS_ACTOR; api_has_occurredAt=$C100_API_HAS_TIMESTAMP ($C100_LOG_NOTE)"
  print_case "Case 100 - Audit logging" \
    "Login + protected API call with unique trace ids, then inspect runtime gateway logs" \
    "Audit log contains user_id(actorId), action, timestamp(occurredAt), traceId for login + API activity; no missing log" \
    "local-check" "$C100_ACTUAL"

  C100_OK=1
  if [[ "$C100_LOGIN_STATUS" != "200" && "$C100_LOGIN_STATUS" != "429" ]]; then C100_OK=0; fi
  if [[ "$C100_API_STATUS" != "200" ]]; then C100_OK=0; fi
  if [[ "$C100_LOG_ACCESS" != "1" ]]; then C100_OK=0; fi
  if [[ "$C100_LOGIN_FOUND" != "1" || "$C100_API_FOUND" != "1" ]]; then C100_OK=0; fi
  if [[ "$C100_API_HAS_ACTION" != "1" || "$C100_API_HAS_ACTOR" != "1" || "$C100_API_HAS_TIMESTAMP" != "1" ]]; then C100_OK=0; fi
  mark_result "$C100_OK" "100"
fi

echo "========================================="
echo "LEVEL 10 SUMMARY (Cases 91-100)"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
