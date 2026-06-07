#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_USER:?POSTGRES_USER is required}"

services_root="${SERVICES_ROOT:-/repo/services}"

extract_up_sql() {
  local input_file="$1"
  awk '
    BEGIN { has_markers = 0; in_up = 1 }
    /^[[:space:]]*--[[:space:]]*migrate:up([[:space:]]|$)/ {
      has_markers = 1
      in_up = 1
      next
    }
    /^[[:space:]]*--[[:space:]]*migrate:down([[:space:]]|$)/ {
      has_markers = 1
      in_up = 0
      next
    }
    {
      if (!has_markers || in_up) {
        print
      }
    }
  ' "$input_file"
}

run_service_migrations() {
  local database_name="$1"
  local migrations_dir="$2"

  if [[ ! -d "$migrations_dir" ]]; then
    return
  fi

  local migration_file
  while IFS= read -r migration_file; do
    local temp_sql
    temp_sql="$(mktemp)"
    extract_up_sql "$migration_file" > "$temp_sql"
    if [[ -s "$temp_sql" ]]; then
      echo "Applying ${migration_file} to ${database_name}"
      psql -v ON_ERROR_STOP=1 \
        --username "$POSTGRES_USER" \
        --dbname "$database_name" \
        --file "$temp_sql"
    fi
    rm -f "$temp_sql"
  done < <(find "$migrations_dir" -maxdepth 1 -type f -name '*.sql' | sort)
}

# These services do not currently bootstrap their full relational schema on
# process startup. Keep production init schema-only and leave demo seed data in
# infra/postgres/init for local development.
run_service_migrations "auth-service_db" "$services_root/auth-service/migrations"
run_service_migrations "user-service_db" "$services_root/user-service/migrations"
run_service_migrations "driver-service_db" "$services_root/driver-service/migrations"
run_service_migrations "review-service_db" "$services_root/review-service/migrations"
