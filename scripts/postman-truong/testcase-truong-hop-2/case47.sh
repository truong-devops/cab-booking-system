#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BASE_URL="${BASE_URL:-http://localhost:3000}"
AI_URL="${AI_URL:-http://host.docker.internal:3013}"
PASS="${PASS:-123456}"
USER_TOKEN="${USER_TOKEN:-}"

CASE47_RATE="${CASE47_RATE:-1000}"
CASE47_DURATION="${CASE47_DURATION:-30s}"
CASE47_PRE_VUS="${CASE47_PRE_VUS:-200}"
CASE47_MAX_VUS="${CASE47_MAX_VUS:-1200}"
CASE47_TIMEOUT="${CASE47_TIMEOUT:-2s}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case47}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_LOG="$OUT_DIR/k6-case47.log"
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

  local ts email username register_json login_json token
  ts="$(date +%s%3N)"
  email="case47-k6-${ts}-${RANDOM}@test.com"
  username="case47_${ts}_${RANDOM}"

  register_json=$(jq -nc \
    --arg email "$email" \
    --arg username "$username" \
    --arg pass "$PASS" \
    '{email:$email,username:$username,password:$pass,name:"Case47 K6 User",role:"user"}')

  local reg_resp
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
    echo "Cannot get USER_TOKEN for case47."
    echo "Auth response: $reg_resp"
    exit 1
  fi

  USER_TOKEN="$token"
  echo "AUTO_USER_EMAIL=$email" >> "$META_FILE"
}

run_case47() {
  (
    cd "$REPO_ROOT"
    docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 \
      run \
      --env AI_URL="$AI_URL" \
      --env USER_TOKEN="$USER_TOKEN" \
      --env CASE47_RATE="$CASE47_RATE" \
      --env CASE47_DURATION="$CASE47_DURATION" \
      --env CASE47_PRE_VUS="$CASE47_PRE_VUS" \
      --env CASE47_MAX_VUS="$CASE47_MAX_VUS" \
      --env CASE47_TIMEOUT="$CASE47_TIMEOUT" \
      /work/case47-ai-latency.js
  ) | tee "$OUT_LOG"
}

{
  echo "CASE=47"
  echo "RUN_ID=$RUN_ID"
  echo "BASE_URL=$BASE_URL"
  echo "AI_URL=$AI_URL"
  echo "CASE47_RATE=$CASE47_RATE"
  echo "CASE47_DURATION=$CASE47_DURATION"
  echo "CASE47_PRE_VUS=$CASE47_PRE_VUS"
  echo "CASE47_MAX_VUS=$CASE47_MAX_VUS"
  echo "CASE47_TIMEOUT=$CASE47_TIMEOUT"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

create_token_if_missing
run_case47

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "USER_TOKEN_SOURCE=${USER_TOKEN:+provided_or_generated}" >> "$META_FILE"

echo "Evidence saved:"
echo "- $OUT_LOG"
echo "- $META_FILE"
