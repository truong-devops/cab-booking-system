#!/bin/sh
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"

migrations_root="${SERVICE_MIGRATIONS_ROOT:-/docker-entrypoint-initdb.d/service-migrations}"

run_psql() {
  if [ -n "${POSTGRES_HOST:-}" ]; then
    psql -v ON_ERROR_STOP=1 --host "$POSTGRES_HOST" --username "$POSTGRES_USER" "$@"
  else
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "$@"
  fi
}

extract_up_sql() {
  input_file="$1"
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

migration_version() {
  basename "$1" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'
}

ensure_migration_table() {
  database_name="$1"
  run_psql --dbname "$database_name" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL
}

is_migration_applied() {
  database_name="$1"
  version="$2"
  applied="$(
    run_psql \
      --dbname "$database_name" \
      --tuples-only \
      --no-align \
      --set=version="$version" \
      --command "SELECT 1 FROM schema_migrations WHERE version = :'version' LIMIT 1;"
  )"
  [ "$applied" = "1" ]
}

apply_migration_file() {
  database_name="$1"
  migration_file="$2"
  version="$3"
  temp_sql="$(mktemp)"

  {
    echo "BEGIN;"
    extract_up_sql "$migration_file"
    echo
    printf "INSERT INTO schema_migrations (version) VALUES ('%s') ON CONFLICT (version) DO NOTHING;\n" "$version"
    echo "COMMIT;"
  } > "$temp_sql"

  run_psql --dbname "$database_name" --file "$temp_sql"
  rm -f "$temp_sql"
}

run_service_migrations() {
  database_name="$1"
  migrations_dir="$2"

  if [ ! -d "$migrations_dir" ]; then
    echo "Missing required migration directory: $migrations_dir" >&2
    exit 1
  fi

  ensure_migration_table "$database_name"

  migration_files="$(find "$migrations_dir" -maxdepth 1 -type f -name '*.sql' | sort)"
  if [ -z "$migration_files" ]; then
    echo "Missing SQL migration files in: $migrations_dir" >&2
    exit 1
  fi

  for migration_file in $migration_files; do
    version="$(migration_version "$migration_file")"
    if [ -z "$version" ]; then
      echo "Skipping migration with no numeric version: $migration_file"
      continue
    fi
    if is_migration_applied "$database_name" "$version"; then
      echo "Migration ${version} already applied to ${database_name}"
      continue
    fi
    echo "Applying ${migration_file} to ${database_name}"
    apply_migration_file "$database_name" "$migration_file" "$version"
  done
}

run_service_migrations "auth-service_db" "$migrations_root/auth-service"
run_service_migrations "booking-service_db" "$migrations_root/booking-service"
run_service_migrations "user-service_db" "$migrations_root/user-service"
run_service_migrations "driver-service_db" "$migrations_root/driver-service"
run_service_migrations "review-service_db" "$migrations_root/review-service"
run_service_migrations "payment-service_db" "$migrations_root/payment-service"
