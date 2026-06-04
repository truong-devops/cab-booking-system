#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

BASE_URL="${BASE_URL:-http://localhost:3000}"
K6_BASE_URL="${K6_BASE_URL:-http://host.docker.internal:3000}"
PASS="${PASS:-123456}"
USER_TOKEN="${USER_TOKEN:-}"

CASE68_START_RATE="${CASE68_START_RATE:-150}"
CASE68_BASELINE_RATE="${CASE68_BASELINE_RATE:-200}"
CASE68_SPIKE_RATE="${CASE68_SPIKE_RATE:-1000}"
CASE68_RECOVERY_RATE="${CASE68_RECOVERY_RATE:-200}"
CASE68_BASELINE_DURATION="${CASE68_BASELINE_DURATION:-5s}"
CASE68_SPIKE_UP_DURATION="${CASE68_SPIKE_UP_DURATION:-2s}"
CASE68_SPIKE_HOLD_DURATION="${CASE68_SPIKE_HOLD_DURATION:-8s}"
CASE68_RECOVERY_DURATION="${CASE68_RECOVERY_DURATION:-5s}"
CASE68_VUS="${CASE68_VUS:-150}"
CASE68_MAX_VUS="${CASE68_MAX_VUS:-800}"
CASE68_TIMEOUT="${CASE68_TIMEOUT:-2s}"
CASE68_SLA_P95_MS="${CASE68_SLA_P95_MS:-200}"
CASE68_SLA_P99_MS="${CASE68_SLA_P99_MS:-300}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case68}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_LOG="$OUT_DIR/k6-case68.log"
META_FILE="$OUT_DIR/meta.env"

mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd docker
need_cmd curl
need_cmd jq

create_token_if_missing() {
  if [[ -n "$USER_TOKEN" ]]; then
    return 0
  fi

  local ts email username register_json login_json token reg_resp
  ts="$(date +%s%3N)"
  email="case68-k6-${ts}-${RANDOM}@test.com"
  username="case68_${ts}_${RANDOM}"

  register_json=$(jq -nc \
    --arg email "$email" \
    --arg username "$username" \
    --arg pass "$PASS" \
    '{email:$email,username:$username,password:$pass,name:"Case68 K6 User",role:"user"}')

  reg_resp="$(curl -sS -X POST "$BASE_URL/v1/auth/register" \
    -H 'Content-Type: application/json' \
    -d "$register_json")"

  token="$(printf '%s' "$reg_resp" | jq -r '.tokens.accessToken // empty')"
  if [[ -z "$token" ]]; then
    login_json=$(jq -nc --arg identifier "$email" --arg pass "$PASS" '{identifier:$identifier,password:$pass}')
    reg_resp="$(curl -sS -X POST "$BASE_URL/v1/auth/login" \
      -H 'Content-Type: application/json' \
      -d "$login_json")"
    token="$(printf '%s' "$reg_resp" | jq -r '.tokens.accessToken // empty')"
  fi

  if [[ -z "$token" ]]; then
    echo "Cannot get USER_TOKEN for case68."
    echo "Auth response: $reg_resp"
    exit 1
  fi

  USER_TOKEN="$token"
  echo "AUTO_USER_EMAIL=$email" >> "$META_FILE"
}

run_case68() {
  (
    cd "$REPO_ROOT"
    docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 \
      run \
      --env BASE_URL="$K6_BASE_URL" \
      --env USER_TOKEN="$USER_TOKEN" \
      --env CASE68_START_RATE="$CASE68_START_RATE" \
      --env CASE68_BASELINE_RATE="$CASE68_BASELINE_RATE" \
      --env CASE68_SPIKE_RATE="$CASE68_SPIKE_RATE" \
      --env CASE68_RECOVERY_RATE="$CASE68_RECOVERY_RATE" \
      --env CASE68_BASELINE_DURATION="$CASE68_BASELINE_DURATION" \
      --env CASE68_SPIKE_UP_DURATION="$CASE68_SPIKE_UP_DURATION" \
      --env CASE68_SPIKE_HOLD_DURATION="$CASE68_SPIKE_HOLD_DURATION" \
      --env CASE68_RECOVERY_DURATION="$CASE68_RECOVERY_DURATION" \
      --env CASE68_VUS="$CASE68_VUS" \
      --env CASE68_MAX_VUS="$CASE68_MAX_VUS" \
      --env CASE68_TIMEOUT="$CASE68_TIMEOUT" \
      --env CASE68_SLA_P95_MS="$CASE68_SLA_P95_MS" \
      --env CASE68_SLA_P99_MS="$CASE68_SLA_P99_MS" \
      /work/case68-latency-under-spike.js
  ) | tee "$OUT_LOG"
}

{
  echo "CASE=68"
  echo "RUN_ID=$RUN_ID"
  echo "BASE_URL=$BASE_URL"
  echo "K6_BASE_URL=$K6_BASE_URL"
  echo "CASE68_START_RATE=$CASE68_START_RATE"
  echo "CASE68_BASELINE_RATE=$CASE68_BASELINE_RATE"
  echo "CASE68_SPIKE_RATE=$CASE68_SPIKE_RATE"
  echo "CASE68_RECOVERY_RATE=$CASE68_RECOVERY_RATE"
  echo "CASE68_BASELINE_DURATION=$CASE68_BASELINE_DURATION"
  echo "CASE68_SPIKE_UP_DURATION=$CASE68_SPIKE_UP_DURATION"
  echo "CASE68_SPIKE_HOLD_DURATION=$CASE68_SPIKE_HOLD_DURATION"
  echo "CASE68_RECOVERY_DURATION=$CASE68_RECOVERY_DURATION"
  echo "CASE68_VUS=$CASE68_VUS"
  echo "CASE68_MAX_VUS=$CASE68_MAX_VUS"
  echo "CASE68_TIMEOUT=$CASE68_TIMEOUT"
  echo "CASE68_SLA_P95_MS=$CASE68_SLA_P95_MS"
  echo "CASE68_SLA_P99_MS=$CASE68_SLA_P99_MS"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

create_token_if_missing
run_case68

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "USER_TOKEN_SOURCE=${USER_TOKEN:+provided_or_generated}" >> "$META_FILE"

echo "Evidence saved:"
echo "- $OUT_LOG"
echo "- $META_FILE"
