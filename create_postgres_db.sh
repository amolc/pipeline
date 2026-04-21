#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./create_postgres_db.sh <username>

Creates:
  - a PostgreSQL role named <username> if it does not exist
  - a PostgreSQL database named <username> if it does not exist
  - a new password every run
  - a details file at db/<username>.txt

Behavior:
  - If the role already exists, the script resets its password.
  - If the database already exists, it is reused.
  - The script must run as `postgres`, as `root`, or via passwordless
    `sudo -n -u postgres`.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

username="$1"
script_path="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ ! "$username" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "Error: username must start with a lowercase letter and contain only lowercase letters, numbers, and underscores."
  exit 1
fi

db_name="$username"
db_user="$username"
db_host="${DB_HOST:-localhost}"
db_port="${DB_PORT:-5432}"
output_dir="db"
output_file="${output_dir}/${username}.txt"
random_suffix="$(printf "%04d" "$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 10000 ))")"
db_password="${username}${random_suffix}"

mkdir -p "$output_dir"

ensure_postgres_context() {
  if [[ "$(id -un)" == "postgres" ]]; then
    return
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    exec su -s /bin/bash postgres -c "$(printf '%q ' "$script_path" "$@")"
  fi

  if command -v sudo >/dev/null 2>&1; then
    exec sudo -n -u postgres -- "$script_path" "$@"
  fi

  echo "Error: this script must run as postgres, as root, or with passwordless sudo to postgres."
  exit 1
}

ensure_postgres_context "$@"

run_psql() {
  psql -v ON_ERROR_STOP=1 -d postgres "$@"
}

run_db_psql() {
  local database="$1"
  shift
  psql -v ON_ERROR_STOP=1 -d "$database" "$@"
}

role_exists="$(
  run_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${db_user}';" | tr -d '[:space:]'
)"

if [[ "$role_exists" == "1" ]]; then
  run_psql -c "ALTER USER ${db_user} WITH PASSWORD '${db_password}';"
  user_action="reset"
else
  run_psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_password}';"
  user_action="created"
fi

db_exists="$(
  run_psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db_name}';" | tr -d '[:space:]'
)"

if [[ "$db_exists" != "1" ]]; then
  run_psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};"
  db_action="created"
else
  run_psql -c "ALTER DATABASE ${db_name} OWNER TO ${db_user};"
  db_action="reused"
fi

run_psql -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};"
run_db_psql "$db_name" -c "ALTER SCHEMA public OWNER TO ${db_user};"
run_db_psql "$db_name" -c "GRANT USAGE, CREATE ON SCHEMA public TO ${db_user};"
run_db_psql "$db_name" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${db_user};"
run_db_psql "$db_name" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${db_user};"
run_db_psql "$db_name" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO ${db_user};"
run_db_psql "$db_name" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO ${db_user};"

cat >"$output_file" <<EOF
Database engine: postgres
Database name: ${db_name}
Database user: ${db_user}
Database password: ${db_password}
Database host: ${db_host}
Database port: ${db_port}
Details file: ${output_file}
Connection URL: postgresql://${db_user}:${db_password}@${db_host}:${db_port}/${db_name}
EOF

cat <<EOF
PostgreSQL provisioning completed.

Role:         ${db_user} (${user_action})
Database:     ${db_name} (${db_action})
Password:     ${db_password}
Details file: ${output_file}
EOF
