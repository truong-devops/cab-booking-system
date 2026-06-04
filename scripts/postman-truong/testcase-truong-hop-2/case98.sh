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

CASE98_RATE="${CASE98_RATE:-150}"
CASE98_DURATION="${CASE98_DURATION:-20s}"
CASE98_VUS="${CASE98_VUS:-80}"
CASE98_MAX_VUS="${CASE98_MAX_VUS:-400}"
CASE98_HEALTH_RATE="${CASE98_HEALTH_RATE:-3}"
CASE98_HEALTH_VUS="${CASE98_HEALTH_VUS:-3}"
CASE98_HEALTH_MAX_VUS="${CASE98_HEALTH_MAX_VUS:-20}"
CASE98_TIMEOUT="${CASE98_TIMEOUT:-3s}"
CASE98_GATEWAY_BOOKING_LIMIT="${CASE98_GATEWAY_BOOKING_LIMIT:-30}"
CASE98_GATEWAY_WINDOW_MS="${CASE98_GATEWAY_WINDOW_MS:-60000}"
CASE98_RESTORE_GATEWAY_CONFIG="${CASE98_RESTORE_GATEWAY_CONFIG:-true}"
CASE98_WARMUP_RETRIES="${CASE98_WARMUP_RETRIES:-20}"
CASE98_WARMUP_SLEEP_SEC="${CASE98_WARMUP_SLEEP_SEC:-1}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case98}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_LOG="$OUT_DIR/k6-case98.log"
META_FILE="$OUT_DIR/meta.env"

mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd docker
need_cmd curl
need_cmd jq

compose_dev() {
  docker compose -f "$REPO_ROOT/infra/docker-compose.dev.yml" "$@"
}

cleanup() {
  if [[ "$CASE98_RESTORE_GATEWAY_CONFIG" == "true" ]]; then
    compose_dev up -d --no-deps --force-recreate api-gateway >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

create_token_if_missing() {
  if [[ -n "$USER_TOKEN" ]]; then
    return 0
  fi

  local ts email username register_json login_json token reg_resp
  ts="$(date +%s%3N)"
  email="case98-k6-${ts}-${RANDOM}@test.com"
  username="case98_${ts}_${RANDOM}"

  register_json=$(jq -nc \
    --arg email "$email" \
    --arg username "$username" \
    --arg pass "$PASS" \
    '{email:$email,username:$username,password:$pass,name:"Case98 K6 User",role:"user"}')

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
    echo "Cannot get USER_TOKEN for case98."
    echo "Auth response: $reg_resp"
    exit 1
  fi

  USER_TOKEN="$token"
  echo "AUTO_USER_EMAIL=$email" >> "$META_FILE"
}

prepare_gateway_rate_limit() {
  RATE_LIMIT_MAX=120000 \
  BOOKING_CREATE_RATE_LIMIT_MAX="$CASE98_GATEWAY_BOOKING_LIMIT" \
  RATE_LIMIT_WINDOW_MS="$CASE98_GATEWAY_WINDOW_MS" \
  compose_dev up -d --no-deps --force-recreate api-gateway >/dev/null
}

warmup_gateway_health() {
  local i=1
  while [[ $i -le "$CASE98_WARMUP_RETRIES" ]]; do
    if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
      echo "[case98] Gateway health is ready."
      return 0
    fi
    sleep "$CASE98_WARMUP_SLEEP_SEC"
    i=$((i + 1))
  done
  echo "[case98] WARNING: gateway /health is not ready after warm-up retries."
  return 0
}

run_case98() {
  (
    cd "$REPO_ROOT"
    docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 \
      run \
      --env BASE_URL="$K6_BASE_URL" \
      --env USER_TOKEN="$USER_TOKEN" \
      --env CASE98_RATE="$CASE98_RATE" \
      --env CASE98_DURATION="$CASE98_DURATION" \
      --env CASE98_VUS="$CASE98_VUS" \
      --env CASE98_MAX_VUS="$CASE98_MAX_VUS" \
      --env CASE98_HEALTH_RATE="$CASE98_HEALTH_RATE" \
      --env CASE98_HEALTH_VUS="$CASE98_HEALTH_VUS" \
      --env CASE98_HEALTH_MAX_VUS="$CASE98_HEALTH_MAX_VUS" \
      --env CASE98_TIMEOUT="$CASE98_TIMEOUT" \
      /work/case98-rate-limit-abuse.js
  ) | tee "$OUT_LOG"
}

{
  echo "CASE=98"
  echo "RUN_ID=$RUN_ID"
  echo "BASE_URL=$BASE_URL"
  echo "K6_BASE_URL=$K6_BASE_URL"
  echo "CASE98_RATE=$CASE98_RATE"
  echo "CASE98_DURATION=$CASE98_DURATION"
  echo "CASE98_VUS=$CASE98_VUS"
  echo "CASE98_MAX_VUS=$CASE98_MAX_VUS"
  echo "CASE98_HEALTH_RATE=$CASE98_HEALTH_RATE"
  echo "CASE98_HEALTH_VUS=$CASE98_HEALTH_VUS"
  echo "CASE98_HEALTH_MAX_VUS=$CASE98_HEALTH_MAX_VUS"
  echo "CASE98_TIMEOUT=$CASE98_TIMEOUT"
  echo "CASE98_GATEWAY_BOOKING_LIMIT=$CASE98_GATEWAY_BOOKING_LIMIT"
  echo "CASE98_GATEWAY_WINDOW_MS=$CASE98_GATEWAY_WINDOW_MS"
  echo "CASE98_WARMUP_RETRIES=$CASE98_WARMUP_RETRIES"
  echo "CASE98_WARMUP_SLEEP_SEC=$CASE98_WARMUP_SLEEP_SEC"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

create_token_if_missing
echo "[case98] Prepare gateway rate-limit profile..."
prepare_gateway_rate_limit
warmup_gateway_health
run_case98

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "USER_TOKEN_SOURCE=${USER_TOKEN:+provided_or_generated}" >> "$META_FILE"

echo "Evidence saved:"
echo "- $OUT_LOG"
echo "- $META_FILE"

