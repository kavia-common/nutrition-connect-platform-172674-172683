#!/bin/bash
set -euo pipefail

# Idempotent PostgreSQL startup and configuration script
# Standardized configuration (can be overridden via env if provided by orchestrator)
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5001}"
POSTGRES_DB="${POSTGRES_DB:-nutrition_connect}"
POSTGRES_USER="${POSTGRES_USER:-nc_app}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-change_me_dev}"

echo "Starting PostgreSQL setup for ${POSTGRES_DB} on ${POSTGRES_HOST}:${POSTGRES_PORT} ..."

# Discover Postgres install and bin path
PG_BIN=""
if [ -d "/usr/lib/postgresql" ]; then
  # Prefer highest version
  PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "${PG_VERSION:-}" ]; then
    PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
  fi
fi

# Helper: run as postgres user if available
as_pg() {
  if id postgres >/dev/null 2>&1; then
    sudo -u postgres "$@"
  else
    "$@"
  fi
}

# Helper to execute psql as postgres
run_psql() {
  if [ -n "${PG_BIN}" ] && id postgres >/dev/null 2>&1; then
    sudo -u postgres "${PG_BIN}/psql" "$@"
  else
    psql "$@"
  fi
}

# Helper to call pg_isready with explicit user fallback
pg_ready() {
  local host="${1:-127.0.0.1}"
  local port="${2:-${POSTGRES_PORT}}"
  local user_try="${3:-${POSTGRES_USER}}"
  local ready_cmd=()
  if [ -n "${PG_BIN}" ] && id postgres >/dev/null 2>&1; then
    ready_cmd=(sudo -u postgres "${PG_BIN}/pg_isready" -h "${host}" -p "${port}" -U "${user_try}")
  else
    ready_cmd=(pg_isready -h "${host}" -p "${port}" -U "${user_try}")
  fi
  "${ready_cmd[@]}"
}

DATA_DIR="${PGDATA:-/var/lib/postgresql/data}"

# Ensure data directory exists with correct ownership
if [ ! -d "${DATA_DIR}" ]; then
  echo "Creating data directory at ${DATA_DIR} ..."
  mkdir -p "${DATA_DIR}"
  if id postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "${DATA_DIR}"
  fi
fi

# Remove stale postmaster.pid if server isn't running
if [ -f "${DATA_DIR}/postmaster.pid" ]; then
  if ! pg_ready >/dev/null 2>&1; then
    echo "Detected stale postmaster.pid; removing to unblock startup ..."
    rm -f "${DATA_DIR}/postmaster.pid"
  fi
fi

# Initialize data dir if necessary
if [ -n "${PG_BIN}" ] && [ ! -f "${DATA_DIR}/PG_VERSION" ] && id postgres >/dev/null 2>&1; then
  echo "Initializing PostgreSQL data directory ..."
  as_pg "${PG_BIN}/initdb" -D "${DATA_DIR}" >/dev/null
fi

# Ensure configuration for binding on 0.0.0.0 and port 5001
CONF_FILE="${DATA_DIR}/postgresql.conf"
HBA_FILE="${DATA_DIR}/pg_hba.conf"
AUTO_CONF="${DATA_DIR}/postgresql.auto.conf"

# Apply settings via postgresql.auto.conf for reliability across restarts
if id postgres >/dev/null 2>&1; then
  echo "Enforcing port and listen_addresses via postgresql.auto.conf ..."
  touch "${AUTO_CONF}"
  chown postgres:postgres "${AUTO_CONF}" || true
  # Ensure entries exist/updated
  if grep -q "^port =" "${AUTO_CONF}" 2>/dev/null; then
    sed -i "s/^port .*/port = ${POSTGRES_PORT}/" "${AUTO_CONF}"
  else
    echo "port = ${POSTGRES_PORT}" >> "${AUTO_CONF}"
  fi
  if grep -q "^listen_addresses =" "${AUTO_CONF}" 2>/dev/null; then
    sed -i "s/^listen_addresses .*/listen_addresses = '*'/" "${AUTO_CONF}"
  else
    echo "listen_addresses = '*'" >> "${AUTO_CONF}"
  fi
fi

# Ensure pg_hba.conf allows local and remote connections (md5)
if [ -f "${HBA_FILE}" ]; then
  echo "Configuring pg_hba.conf for local and remote md5 access ..."
  grep -Eq "^local[[:space:]]+all[[:space:]]+all[[:space:]]+md5" "${HBA_FILE}" 2>/dev/null || echo "local all all md5" >> "${HBA_FILE}"
  grep -Eq "^host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+md5" "${HBA_FILE}" 2>/dev/null || echo "host all all 127.0.0.1/32 md5" >> "${HBA_FILE}"
  grep -Eq "^host[[:space:]]+all[[:space:]]+all[[:space:]]+0\.0\.0\.0/0[[:space:]]+md5" "${HBA_FILE}" 2>/dev/null || echo "host all all 0.0.0.0/0 md5" >> "${HBA_FILE}"
fi

# Start server if not ready (best-effort; in CI it may already be running)
if ! pg_ready 127.0.0.1 "${POSTGRES_PORT}" "${POSTGRES_USER}" >/dev/null 2>&1; then
  if [ -n "${PG_BIN}" ] && id postgres >/dev/null 2>&1; then
    echo "Starting PostgreSQL server on 0.0.0.0:${POSTGRES_PORT} ..."
    # Use postgres -D with explicit -h and -p
    nohup sudo -u postgres "${PG_BIN}/postgres" -D "${DATA_DIR}" -h 0.0.0.0 -p "${POSTGRES_PORT}" >/dev/null 2>&1 &
    sleep 1
  else
    echo "Warning: PG binaries or postgres user not found; assuming system-managed service."
  fi
fi

# Wait for readiness with exponential backoff (max ~45s)
echo "Waiting for PostgreSQL readiness on 127.0.0.1:${POSTGRES_PORT} ..."
retries=10
delay=1
READY=0
for ((i=1; i<=retries; i++)); do
  if pg_ready 127.0.0.1 "${POSTGRES_PORT}" "${POSTGRES_USER}" >/dev/null 2>&1 || \
     pg_ready 127.0.0.1 "${POSTGRES_PORT}" postgres >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep "${delay}"
  delay=$((delay*2))
  if [ "${delay}" -gt 8 ]; then delay=8; fi
done

if [ "${READY}" -eq 0 ]; then
  echo "⚠ Warning: Could not verify PostgreSQL readiness after retries. Continuing, but operations may fail."
else
  echo "✓ PostgreSQL is ready on ${POSTGRES_HOST}:${POSTGRES_PORT}"
fi

# Create/alter role and database idempotently without requiring dblink
run_psql -h 127.0.0.1 -p "${POSTGRES_PORT}" -d postgres -v ON_ERROR_STOP=1 <<EOSQL || true
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
    CREATE ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  ELSE
    ALTER ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  END IF;
END
\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', '${POSTGRES_DB}', '${POSTGRES_USER}');
  END IF;
END
\$\$;
EOSQL

# Grant privileges and schema permissions inside target DB
run_psql -h 127.0.0.1 -p "${POSTGRES_PORT}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<'EOSQL' || true
CREATE SCHEMA IF NOT EXISTS public;
GRANT USAGE ON SCHEMA public TO public;
EOSQL

# Apply user-specific grants
run_psql -h 127.0.0.1 -p "${POSTGRES_PORT}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<EOSQL || true
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
GRANT CREATE ON SCHEMA public TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${POSTGRES_USER};
EOSQL

# Final readiness check for external bind (0.0.0.0) via localhost resolution
if pg_ready 127.0.0.1 "${POSTGRES_PORT}" "${POSTGRES_USER}" >/dev/null 2>&1; then
  echo "✓ Postgres listening confirmed on 127.0.0.1:${POSTGRES_PORT} (bound to 0.0.0.0)"
fi

# Write connection info artifacts
CONN_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo "psql ${CONN_URL}" > db_connection.txt

cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="${CONN_URL}"
export POSTGRES_USER="${POSTGRES_USER}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
export POSTGRES_DB="${POSTGRES_DB}"
export POSTGRES_PORT="${POSTGRES_PORT}"
EOF

echo ""
echo "PostgreSQL configured."
echo "  Host: ${POSTGRES_HOST}"
echo "  Port: ${POSTGRES_PORT}"
echo "  Database: ${POSTGRES_DB}"
echo "  User: ${POSTGRES_USER}"
echo ""
echo "Connection URL:"
echo "  ${CONN_URL}"
echo ""
echo "Saved:"
echo "  - db_connection.txt"
echo "  - db_visualizer/postgres.env"
echo ""
echo "psql quick connect:"
echo "  psql -h ${POSTGRES_HOST} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -p ${POSTGRES_PORT}"
