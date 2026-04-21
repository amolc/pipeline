#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./setup_project.sh <projectname>

Creates:
  - /home/ubuntu/<projectname>
  - a database named <projectname>
  - a database user named <projectname>
  - a password in the format <projectname><4-digit-random-number>

Environment overrides:
  DB_ENGINE=mysql|postgres   Force a specific database engine.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

project_name="$1"

if [[ ! "$project_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "Error: projectname must start with a lowercase letter and contain only lowercase letters, numbers, and underscores."
  exit 1
fi

project_dir="/home/ubuntu/${project_name}"
random_suffix="$(printf "%04d" "$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 10000 ))")"
db_password="${project_name}${random_suffix}"
db_engine="${DB_ENGINE:-}"

mkdir -p "$project_dir"

detect_engine() {
  if [[ -n "$db_engine" ]]; then
    echo "$db_engine"
    return
  fi

  if command -v mysql >/dev/null 2>&1; then
    echo "mysql"
    return
  fi

  if command -v psql >/dev/null 2>&1; then
    echo "postgres"
    return
  fi

  echo ""
}

run_mysql() {
  local sql
  sql=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS \`${project_name}\`;
CREATE USER IF NOT EXISTS '${project_name}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${project_name}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON \`${project_name}\`.* TO '${project_name}'@'localhost';
FLUSH PRIVILEGES;
EOF
)

  if mysql -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -e "$sql"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo mysql -e "$sql"
    return
  fi

  echo "Error: unable to connect to MySQL/MariaDB. Run the script as a user with database admin access."
  exit 1
}

run_postgres() {
  local exists_sql create_user_sql create_db_sql
  exists_sql="SELECT 1 FROM pg_roles WHERE rolname = '${project_name}';"
  create_user_sql="DO \$\$ BEGIN IF NOT EXISTS (${exists_sql}) THEN CREATE USER ${project_name} WITH PASSWORD '${db_password}'; ELSE ALTER USER ${project_name} WITH PASSWORD '${db_password}'; END IF; END \$\$;"
  create_db_sql="SELECT format('CREATE DATABASE %I OWNER %I', '${project_name}', '${project_name}') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${project_name}')"

  if psql -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
    psql -v ON_ERROR_STOP=1 -d postgres <<EOF
${create_user_sql}
EOF
    psql -v ON_ERROR_STOP=1 -d postgres -tAqc "${create_db_sql}" | psql -v ON_ERROR_STOP=1 -d postgres
    psql -v ON_ERROR_STOP=1 -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${project_name} TO ${project_name};"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres <<EOF
${create_user_sql}
EOF
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -tAqc "${create_db_sql}" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${project_name} TO ${project_name};"
    return
  fi

  echo "Error: unable to connect to PostgreSQL. Run the script as a user with database admin access."
  exit 1
}

engine="$(detect_engine)"

case "$engine" in
  mysql)
    run_mysql
    ;;
  postgres)
    run_postgres
    ;;
  *)
    echo "Error: no supported database engine found. Install MySQL/MariaDB or PostgreSQL, or set DB_ENGINE."
    exit 1
    ;;
esac

cat <<EOF
Project setup completed.

Project directory: ${project_dir}
Database engine:   ${engine}
Database name:     ${project_name}
Database user:     ${project_name}
Database password: ${db_password}
EOF
