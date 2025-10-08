#!/bin/bash
set -euo pipefail

# Idempotent PostgreSQL startup and configuration script
# Standardized configuration
POSTGRES_HOST="localhost"
POSTGRES_PORT="5001"
POSTGRES_DB="nutrition_connect"
POSTGRES_USER="nc_app"
POSTGRES_PASSWORD="change_me_dev"

echo "Starting PostgreSQL setup for ${POSTGRES_DB} on ${POSTGRES_HOST}:${POSTGRES_PORT} ..."

# Discover Postgres install and bin path
if [ -d "/usr/lib/postgresql" ]; then
  PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
  PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
else
  # Fallback to PATH
  PG_BIN=""
fi

# Helper to execute psql as postgres
run_psql() {
  if [ -n "${PG_BIN}" ] && sudo -u postgres true 2>/dev/null; then
    sudo -u postgres ${PG_BIN}/psql "$@"
  else
    psql "$@"
  fi
}

# Helper to call pg_isready
pg_ready() {
  if [ -n "${PG_BIN}" ] && sudo -u postgres true 2>/dev/null; then
    sudo -u postgres ${PG_BIN}/pg_isready -h ${POSTGRES_HOST} -p ${POSTGRES_PORT}
  else
    pg_isready -h ${POSTGRES_HOST} -p ${POSTGRES_PORT}
  fi
}

# Initialize data dir if necessary (typical Debian/Ubuntu layout)
if [ -n "${PG_BIN}" ] && [ ! -f "/var/lib/postgresql/data/PG_VERSION" ] && sudo -u postgres true 2>/dev/null; then
  echo "Initializing PostgreSQL data directory (if required)..."
  sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data >/dev/null 2>&1 || true
fi

# Start server if not ready (best-effort; in CI it may already be running)
if ! pg_ready >/dev/null 2>&1; then
  if [ -n "${PG_BIN}" ] && sudo -u postgres true 2>/dev/null; then
    echo "Starting PostgreSQL server on port ${POSTGRES_PORT} ..."
    sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${POSTGRES_PORT} >/dev/null 2>&1 &
    # Wait for readiness
    for i in {1..20}; do
      if pg_ready >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
fi

if pg_ready >/dev/null 2>&1; then
  echo "✓ PostgreSQL is ready on ${POSTGRES_HOST}:${POSTGRES_PORT}"
else
  echo "⚠ Warning: Could not verify PostgreSQL readiness. Continuing with configuration attempts."
fi

# Create role and database if missing, idempotently
SQL_SETUP=$(cat <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
    CREATE ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  ELSE
    ALTER ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  END IF;
END
\$\$;

-- Create database if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}') THEN
    PERFORM dblink_exec('dbname=' || current_database(), 'CREATE DATABASE ${POSTGRES_DB}');
  END IF;
EXCEPTION
  WHEN undefined_function THEN
    -- dblink not available; fallback
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}') THEN
      EXECUTE 'CREATE DATABASE ${POSTGRES_DB}';
    END IF;
END
\$\$;
EOSQL
)

# Execute setup in postgres maintenance DB
run_psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -d postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS dblink;" 2>/dev/null || true
run_psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -d postgres -v ON_ERROR_STOP=1 -c "${SQL_SETUP}" || true

# Grant privileges and schema permissions inside target DB
run_psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -d ${POSTGRES_DB} -v ON_ERROR_STOP=1 <<'EOSQL'
-- Ensure public schema exists and set sane permissions
CREATE SCHEMA IF NOT EXISTS public;
GRANT USAGE ON SCHEMA public TO public;

-- No blanket public rights; grant to app user (script will substitute variable values)
EOSQL

# Because here-doc above is single-quoted, run a second block to apply user-specific grants
run_psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -d ${POSTGRES_DB} -v ON_ERROR_STOP=1 <<EOSQL
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
GRANT CREATE ON SCHEMA public TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${POSTGRES_USER};
EOSQL

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
