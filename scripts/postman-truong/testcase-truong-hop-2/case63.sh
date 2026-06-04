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

CASE63_START_RATE="${CASE63_START_RATE:-100}"
CASE63_SPIKE_RATE="${CASE63_SPIKE_RATE:-1000}"
CASE63_WARMUP="${CASE63_WARMUP:-5s}"
CASE63_HOLD="${CASE63_HOLD:-10s}"
CASE63_COOLDOWN="${CASE63_COOLDOWN:-5s}"
CASE63_VUS="${CASE63_VUS:-400}"
CASE63_MAX_VUS="${CASE63_MAX_VUS:-1800}"
CASE63_TIMEOUT="${CASE63_TIMEOUT:-4s}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case63}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_LOG="$OUT_DIR/k6-case63.log"
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
  email="case63-k6-${ts}-${RANDOM}@test.com"
  username="case63_${ts}_${RANDOM}"

  register_json=$(jq -nc \
    --arg email "$email" \
    --arg username "$username" \
    --arg pass "$PASS" \
    '{email:$email,username:$username,password:$pass,name:"Case63 K6 User",role:"user"}')

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
    echo "Cannot get USER_TOKEN for case63."
    echo "Auth response: $reg_resp"
    exit 1
  fi

  USER_TOKEN="$token"
  echo "AUTO_USER_EMAIL=$email" >> "$META_FILE"
}

run_case63() {
  (
    cd "$REPO_ROOT"
    docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 \
      run \
      --env BASE_URL="$K6_BASE_URL" \
      --env USER_TOKEN="$USER_TOKEN" \
      --env CASE63_START_RATE="$CASE63_START_RATE" \
      --env CASE63_SPIKE_RATE="$CASE63_SPIKE_RATE" \
      --env CASE63_WARMUP="$CASE63_WARMUP" \
      --env CASE63_HOLD="$CASE63_HOLD" \
      --env CASE63_COOLDOWN="$CASE63_COOLDOWN" \
      --env CASE63_VUS="$CASE63_VUS" \
      --env CASE63_MAX_VUS="$CASE63_MAX_VUS" \
      --env CASE63_TIMEOUT="$CASE63_TIMEOUT" \
      /work/case63-pricing-spike.js
  ) | tee "$OUT_LOG"
}

{
  echo "CASE=63"
  echo "RUN_ID=$RUN_ID"
  echo "BASE_URL=$BASE_URL"
  echo "K6_BASE_URL=$K6_BASE_URL"
  echo "CASE63_START_RATE=$CASE63_START_RATE"
  echo "CASE63_SPIKE_RATE=$CASE63_SPIKE_RATE"
  echo "CASE63_WARMUP=$CASE63_WARMUP"
  echo "CASE63_HOLD=$CASE63_HOLD"
  echo "CASE63_COOLDOWN=$CASE63_COOLDOWN"
  echo "CASE63_VUS=$CASE63_VUS"
  echo "CASE63_MAX_VUS=$CASE63_MAX_VUS"
  echo "CASE63_TIMEOUT=$CASE63_TIMEOUT"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

create_token_if_missing
run_case63

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "USER_TOKEN_SOURCE=${USER_TOKEN:+provided_or_generated}" >> "$META_FILE"

echo "Evidence saved:"
echo "- $OUT_LOG"
echo "- $META_FILE"
