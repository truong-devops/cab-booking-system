#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

CARD_NUMBER="${CARD_NUMBER:-4111111111111111}"
CASE87_ENC_KEY="${CASE87_ENC_KEY:-case87-demo-master-key}"
CASE87_WRONG_KEY="${CASE87_WRONG_KEY:-case87-wrong-key}"
CASE87_KEY_VERSION="${CASE87_KEY_VERSION:-v1}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/scripts/evidence/case87}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$EVIDENCE_DIR/$RUN_ID"
OUT_JSON="$OUT_DIR/case87-encryption-at-rest.json"
META_FILE="$OUT_DIR/meta.env"
SQL_OUT="$OUT_DIR/sql-output.txt"

mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd docker
need_cmd jq

compose_dev() {
  docker compose -f "$REPO_ROOT/infra/docker-compose.dev.yml" "$@"
}

exec_psql() {
  compose_dev exec -T postgres psql -U cab -d payment-service_db "$@"
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

{
  echo "CASE=87"
  echo "RUN_ID=$RUN_ID"
  echo "CASE87_KEY_VERSION=$CASE87_KEY_VERSION"
  echo "KEY_SOURCE=env:CASE87_ENC_KEY"
  echo "START_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$META_FILE"

PAYMENT_REF="case87-${RUN_ID}"
CARD_SQL="$(sql_escape "$CARD_NUMBER")"
ENC_KEY_SQL="$(sql_escape "$CASE87_ENC_KEY")"
WRONG_KEY_SQL="$(sql_escape "$CASE87_WRONG_KEY")"
PAYMENT_REF_SQL="$(sql_escape "$PAYMENT_REF")"
KEY_VERSION_SQL="$(sql_escape "$CASE87_KEY_VERSION")"

echo "[case87] About to insert:"
echo "  payment_ref=${PAYMENT_REF}"
echo "  card_number=${CARD_NUMBER}"
echo "  key_version=${CASE87_KEY_VERSION}"

exec_psql -v ON_ERROR_STOP=1 <<'SQL' > "$SQL_OUT"
CREATE TABLE IF NOT EXISTS payment_card_vault_case87 (
  id bigserial PRIMARY KEY,
  payment_ref text NOT NULL,
  card_number_enc bytea NOT NULL,
  key_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
SQL

INSERT_ROW="$(exec_psql -v ON_ERROR_STOP=1 -t -A -F '|' \
  -c "INSERT INTO payment_card_vault_case87(payment_ref, card_number_enc, key_version) VALUES ('${PAYMENT_REF_SQL}', pgp_sym_encrypt('${CARD_SQL}', '${ENC_KEY_SQL}', 'cipher-algo=aes256, compress-algo=0'), '${KEY_VERSION_SQL}') RETURNING payment_ref, encode(card_number_enc, 'base64'), key_version, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"');")"
printf "INSERT_RETURNING_ROW=%s\n" "$INSERT_ROW" >> "$SQL_OUT"

echo "[case87] Row returned by INSERT (full):"
echo "$INSERT_ROW"

ROW="$(exec_psql -v ON_ERROR_STOP=1 -t -A -F '|' -c "SELECT payment_ref, encode(card_number_enc, 'base64'), key_version, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM payment_card_vault_case87 WHERE payment_ref = '${PAYMENT_REF_SQL}' ORDER BY id DESC LIMIT 1;")"
IFS='|' read -r ROW_PAYMENT_REF ROW_CIPHERTEXT ROW_KEY_VERSION ROW_CREATED_AT <<< "$ROW"

DECRYPTED_OK="$(exec_psql -v ON_ERROR_STOP=1 -t -A -c "SELECT pgp_sym_decrypt(card_number_enc, '${ENC_KEY_SQL}')::text FROM payment_card_vault_case87 WHERE payment_ref = '${PAYMENT_REF_SQL}' ORDER BY id DESC LIMIT 1;")"

WRONG_KEY_OUTPUT="$(
  exec_psql -v ON_ERROR_STOP=1 -t -A -c "SELECT pgp_sym_decrypt(card_number_enc, '${WRONG_KEY_SQL}')::text FROM payment_card_vault_case87 WHERE payment_ref = '${PAYMENT_REF_SQL}' ORDER BY id DESC LIMIT 1;" 2>&1 || true
)"

PLAINTEXT_VISIBLE="false"
if [[ "$ROW_CIPHERTEXT" == *"$CARD_NUMBER"* ]]; then
  PLAINTEXT_VISIBLE="true"
fi

WRONG_KEY_BLOCKED="false"
if [[ "$WRONG_KEY_OUTPUT" == *"Wrong key or corrupt data"* ]]; then
  WRONG_KEY_BLOCKED="true"
fi

CORRECT_KEY_DECRYPT_OK="false"
if [[ "$(printf '%s' "$DECRYPTED_OK" | tr -d '[:space:]')" == "$CARD_NUMBER" ]]; then
  CORRECT_KEY_DECRYPT_OK="true"
fi

PASS="false"
if [[ "$PLAINTEXT_VISIBLE" == "false" && "$WRONG_KEY_BLOCKED" == "true" && "$CORRECT_KEY_DECRYPT_OK" == "true" ]]; then
  PASS="true"
fi

jq -n \
  --arg case_id "87" \
  --arg payment_ref "${ROW_PAYMENT_REF:-$PAYMENT_REF}" \
  --arg ciphertext "${ROW_CIPHERTEXT:-}" \
  --arg key_version "${ROW_KEY_VERSION:-$CASE87_KEY_VERSION}" \
  --arg created_at "${ROW_CREATED_AT:-}" \
  --arg plaintext_visible "$PLAINTEXT_VISIBLE" \
  --arg wrong_key_blocked "$WRONG_KEY_BLOCKED" \
  --arg correct_key_decrypt_ok "$CORRECT_KEY_DECRYPT_OK" \
  --arg key_source "env:CASE87_ENC_KEY" \
  --arg pass "$PASS" \
  '{
    case: ($case_id|tonumber),
    scenario: "Data encryption at rest for sensitive card data",
    expected: {
      sensitive_data_encrypted: true,
      no_plaintext_in_db: true,
      key_management_present: true
    },
    observed: {
      payment_ref: $payment_ref,
      stored_card_value_sample: $ciphertext,
      key_version: $key_version,
      created_at_utc: $created_at,
      key_source: $key_source
    },
    checks: {
      plaintext_visible_in_db: ($plaintext_visible == "true"),
      wrong_key_cannot_decrypt: ($wrong_key_blocked == "true"),
      correct_key_can_decrypt: ($correct_key_decrypt_ok == "true")
    },
    pass: ($pass == "true")
  }' > "$OUT_JSON"

echo "END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
echo "PAYMENT_REF=$PAYMENT_REF" >> "$META_FILE"
echo "PLAINTEXT_VISIBLE=$PLAINTEXT_VISIBLE" >> "$META_FILE"
echo "WRONG_KEY_BLOCKED=$WRONG_KEY_BLOCKED" >> "$META_FILE"
echo "CORRECT_KEY_DECRYPT_OK=$CORRECT_KEY_DECRYPT_OK" >> "$META_FILE"
echo "PASS=$PASS" >> "$META_FILE"

echo "[case87] SQL check output:"
cat "$SQL_OUT"
echo "[case87] Ciphertext sample (from DB): ${ROW_CIPHERTEXT:0:32}..."
echo "[case87] Wrong key blocked: $WRONG_KEY_BLOCKED"
echo "[case87] Correct key decrypt ok: $CORRECT_KEY_DECRYPT_OK"
echo "[case87] PASS=$PASS"
# echo "Evidence saved:"
# echo "- $OUT_JSON"
# echo "- $META_FILE"
# echo "- $SQL_OUT"


echo "SQL:"
docker compose -f infra/docker-compose.dev.yml exec -T postgres \
psql -U cab -d payment-service_db -c "
SELECT id, payment_ref, encode(card_number_enc,'base64') AS card_number_stored, key_version, created_at
FROM payment_card_vault_case87
ORDER BY id DESC
LIMIT 5;"


if [[ "$PASS" != "true" ]]; then
  exit 1
fi
