#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
target="$repo_root/infra/postgres/pro-init/service-migrations"
services="
auth-service
booking-service
user-service
driver-service
review-service
payment-service
"

rm -rf "$target"
mkdir -p "$target"

for service in $services; do
  source_dir="$repo_root/services/$service/migrations"
  if [ ! -d "$source_dir" ]; then
    echo "Missing migrations for $service: $source_dir" >&2
    exit 1
  fi
  cp -R "$source_dir" "$target/$service"
done

echo "Synced production migrations to $target"
