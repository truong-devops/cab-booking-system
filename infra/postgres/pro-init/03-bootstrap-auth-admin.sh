#!/bin/sh
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${BOOTSTRAP_ADMIN_EMAIL:?BOOTSTRAP_ADMIN_EMAIL is required}"
: "${BOOTSTRAP_ADMIN_PASSWORD:?BOOTSTRAP_ADMIN_PASSWORD is required}"

auth_database="${AUTH_DATABASE_NAME:-auth-service_db}"
admin_username="${BOOTSTRAP_ADMIN_USERNAME:-}"
bcrypt_rounds="${BOOTSTRAP_ADMIN_BCRYPT_ROUNDS:-10}"

run_psql() {
  if [ -n "${POSTGRES_HOST:-}" ]; then
    psql -v ON_ERROR_STOP=1 --host "$POSTGRES_HOST" --username "$POSTGRES_USER" "$@"
  else
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "$@"
  fi
}

run_psql \
  --dbname "$auth_database" \
  --set=admin_email="$BOOTSTRAP_ADMIN_EMAIL" \
  --set=admin_username="$admin_username" \
  --set=admin_password="$BOOTSTRAP_ADMIN_PASSWORD" \
  --set=bcrypt_rounds="$bcrypt_rounds" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO users (email, username, password_hash, role, status)
VALUES (
  :'admin_email',
  NULLIF(:'admin_username', ''),
  crypt(:'admin_password', gen_salt('bf', :'bcrypt_rounds'::int)),
  'admin',
  'active'
)
ON CONFLICT (email)
DO UPDATE SET
  password_hash = EXCLUDED.password_hash,
  role = 'admin',
  status = 'active'
RETURNING id, email, username, role, status;
SQL
