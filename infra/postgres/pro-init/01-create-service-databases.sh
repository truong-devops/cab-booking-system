#!/bin/sh
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"

bootstrap_db="${POSTGRES_DB:-postgres}"
service_databases="
auth-service_db
booking-service_db
user-service_db
driver-service_db
review-service_db
payment-service_db
places-service_db
"

run_psql() {
  if [ -n "${POSTGRES_HOST:-}" ]; then
    psql -v ON_ERROR_STOP=1 --host "$POSTGRES_HOST" --username "$POSTGRES_USER" "$@"
  else
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "$@"
  fi
}

for service_db in $service_databases; do
  run_psql \
    --dbname "$bootstrap_db" \
    --set=service_db="$service_db" \
    --set=service_owner="$POSTGRES_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'service_db', :'service_owner')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_database
  WHERE datname = :'service_db'
)
\gexec
SQL
done
