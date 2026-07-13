#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# up.sh — Bring up ONE (Redmine version x DB) combo of the isolated test harness.
#
# Parameterized matrix: pick a Redmine version and a DB adapter. Each combo gets
# its OWN container (its OWN Redmine checkout) and its OWN distinct test DB, so
# combos never collide with each other or with any other session sharing this host.
#
#   REDMINE_VERSION   default 6.1.2   (flag: --redmine-version / -r)
#   DB                default postgres (flag: --db / -d ; postgres|mysql)
#
# Version -> image routing:
#   6.1.x  -> official docker.io/library/redmine:<ver>
#   7.0.x  (or any version without an official image) -> build
#            pulse-test-redmine:<ver> from ./Dockerfile (redmine.org tarball).
#
# SHARED-SUBSTRATE SAFETY: this script REUSES the shared network + Postgres +
# MySQL (creating them only if absent) and never stops/removes them. It ONLY
# creates: containers named  pulse_test_rm_<ver>_<db>, DBs named
# redmine_pulse_test_<ver>_<db>, and images tagged pulse-test-redmine:<ver>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Parameters -------------------------------------------------------------------
REDMINE_VERSION="${REDMINE_VERSION:-6.1.2}"
DB="${DB:-postgres}"

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--redmine-version) REDMINE_VERSION="$2"; shift 2 ;;
    -d|--db)              DB="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--redmine-version <ver>] [--db postgres|mysql]"
      echo "  env vars REDMINE_VERSION / DB are also honored."
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Input validation (H-001) — BEFORE any name/SQL/identifier derivation --------
# REDMINE_VERSION and DB are interpolated into container names, DB names, and SQL
# literals/identifiers. Validate them strictly here so nothing downstream can be an
# injection vector against the shared Postgres/MySQL servers.
#   - REDMINE_VERSION must be a bare X.Y.Z release. This guarantees VER_SAN
#     (dots -> underscores) contains only [0-9_], safe as a SQL identifier.
#   - DB must be exactly postgres or mysql.
if ! [[ "${REDMINE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: REDMINE_VERSION must be a bare X.Y.Z release (e.g. 6.1.2)." >&2
  echo "       Got: '${REDMINE_VERSION}'. Refusing to derive any resource name or SQL." >&2
  exit 2
fi
case "${DB}" in
  postgres|mysql) ;;
  *) echo "ERROR: DB must be exactly 'postgres' or 'mysql' (got '${DB}')." >&2; exit 2 ;;
esac

# Sanitized version token (dots -> underscores) for resource names.
VER_SAN="${REDMINE_VERSION//./_}"

# --- Shared substrate (REUSE — never recreate/stop/remove) ------------------------
NETWORK="pulse_test_net"
PG_CONTAINER="pulse_test_pg"
MYSQL_CONTAINER="pulse_test_mysql"

POSTGRES_IMAGE="docker.io/library/postgres:16-alpine"
MYSQL_IMAGE="docker.io/library/mysql:8"

DB_USER="pulse_test"
DB_PASSWORD="pulse_test_secret"
MYSQL_ROOT_PASSWORD="rootsecret"

# --- Per-combo resources (this script may create/remove ONLY these) ---------------
RM_CONTAINER="pulse_test_rm_${VER_SAN}_${DB}"
COMBO_DB="redmine_pulse_test_${VER_SAN}_${DB}"

# --- Per-combo bring-up lock (M-002) ----------------------------------------------
# Force-removing the combo container below can kill a concurrently-running proof
# run of the SAME combo. Serialize on a per-combo host lock so two up.sh (or an
# up.sh vs a run-tests.sh) for the SAME combo queue instead of clobbering each
# other. Different combos have different lock files -> no false serialization.
COMBO_LOCK="/tmp/pulse-test-rm-${VER_SAN}-${DB}.lock"
exec 8>"${COMBO_LOCK}"
if ! flock -n 8; then
  echo "==> [pulse-test] Combo ${VER_SAN}/${DB} is busy (lock held); waiting for it..."
  flock 8
fi

# Version -> image routing.
OFFICIAL_IMAGE="docker.io/library/redmine:${REDMINE_VERSION}"
BUILT_IMAGE="pulse-test-redmine:${REDMINE_VERSION}"
case "${REDMINE_VERSION}" in
  6.1.*) REDMINE_IMAGE="${OFFICIAL_IMAGE}"; BUILD_FROM_TARBALL=0 ;;
  *)     REDMINE_IMAGE="${BUILT_IMAGE}";    BUILD_FROM_TARBALL=1 ;;
esac

echo "==> [pulse-test] Combo: Redmine ${REDMINE_VERSION} x ${DB}"
echo "    container : ${RM_CONTAINER}"
echo "    test DB   : ${COMBO_DB}"
echo "    image     : ${REDMINE_IMAGE}"

remove_if_exists() {
  local name="$1"
  if podman container exists "${name}" 2>/dev/null; then
    podman rm -f "${name}" 2>/dev/null || true
    echo "    Removed pre-existing combo container: ${name}"
  fi
}

# --- Ensure shared network exists (create only if absent) -------------------------
echo "==> [pulse-test] Ensuring shared network: ${NETWORK}"
if ! podman network exists "${NETWORK}" 2>/dev/null; then
  podman network create "${NETWORK}"
  echo "    Created network ${NETWORK}."
else
  echo "    Reusing existing network ${NETWORK}."
fi

# --- Ensure the chosen shared DB server exists + is reachable ----------------------
if [ "${DB}" = "postgres" ]; then
  echo "==> [pulse-test] Ensuring shared Postgres: ${PG_CONTAINER}"
  if ! podman container exists "${PG_CONTAINER}" 2>/dev/null; then
    # 8>&- : do NOT leak the combo-lock fd into the detached container's
    # supervisor (conmon) — otherwise it would hold the flock for the container's
    # whole lifetime and permanently block run-tests.sh / down.sh.
    podman run -d --name "${PG_CONTAINER}" --network "${NETWORK}" \
      -e POSTGRES_USER="${DB_USER}" \
      -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
      -e POSTGRES_DB="redmine_test" \
      "${POSTGRES_IMAGE}" 8>&-
    echo "    Created ${PG_CONTAINER}."
  else
    echo "    Reusing existing ${PG_CONTAINER} (never recreated)."
  fi
  echo "==> [pulse-test] Waiting for Postgres to accept connections..."
  for i in $(seq 1 30); do
    if podman exec "${PG_CONTAINER}" pg_isready -U "${DB_USER}" &>/dev/null; then
      echo "    Postgres ready (${i}s)."; break
    fi
    sleep 1
  done
else
  echo "==> [pulse-test] Ensuring shared MySQL: ${MYSQL_CONTAINER}"
  if ! podman container exists "${MYSQL_CONTAINER}" 2>/dev/null; then
    # 8>&- : do NOT leak the combo-lock fd into conmon (see Postgres branch).
    podman run -d --name "${MYSQL_CONTAINER}" --network "${NETWORK}" \
      -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
      -e MYSQL_USER="${DB_USER}" \
      -e MYSQL_PASSWORD="${DB_PASSWORD}" \
      "${MYSQL_IMAGE}" 8>&-
    echo "    Created ${MYSQL_CONTAINER}."
  else
    echo "    Reusing existing ${MYSQL_CONTAINER} (never recreated)."
  fi
  echo "==> [pulse-test] Waiting for MySQL to accept connections..."
  for i in $(seq 1 60); do
    if podman exec "${MYSQL_CONTAINER}" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" &>/dev/null; then
      echo "    MySQL ready (${i}s)."; break
    fi
    sleep 1
  done
fi

# --- Create the distinct per-combo test DB ----------------------------------------
if [ "${DB}" = "postgres" ]; then
  echo "==> [pulse-test] Ensuring test DB ${COMBO_DB} on Postgres..."
  # pulse_test is a superuser here and can create its own DBs.
  EXISTS=$(podman exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_CONTAINER}" \
    psql -U "${DB_USER}" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${COMBO_DB}'" 2>/dev/null | tr -d '[:space:]')
  if [ "${EXISTS}" != "1" ]; then
    podman exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_CONTAINER}" \
      psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${COMBO_DB}"
    echo "    Created ${COMBO_DB}."
  else
    echo "    ${COMBO_DB} already exists — reusing."
  fi
else
  echo "==> [pulse-test] Ensuring test DB ${COMBO_DB} on MySQL..."
  # pulse_test lacks CREATE on arbitrary mysql DBs — create as root + grant.
  podman exec "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e \
    "CREATE DATABASE IF NOT EXISTS ${COMBO_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; \
     GRANT ALL PRIVILEGES ON ${COMBO_DB}.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
  echo "    Ensured ${COMBO_DB} + grant."
fi

# --- Build the Redmine image if this version has no official one -------------------
if [ "${BUILD_FROM_TARBALL}" -eq 1 ]; then
  if podman image exists "${REDMINE_IMAGE}" 2>/dev/null; then
    echo "==> [pulse-test] Reusing built image ${REDMINE_IMAGE}."
  else
    echo "==> [pulse-test] Building ${REDMINE_IMAGE} from redmine.org tarball (few minutes)..."
    podman build \
      --build-arg REDMINE_VERSION="${REDMINE_VERSION}" \
      -t "${REDMINE_IMAGE}" \
      -f "${SCRIPT_DIR}/Dockerfile" \
      "${SCRIPT_DIR}"
    echo "    Built ${REDMINE_IMAGE}."
  fi
else
  echo "==> [pulse-test] Ensuring official image ${REDMINE_IMAGE} is present..."
  podman image exists "${REDMINE_IMAGE}" 2>/dev/null || podman pull "${REDMINE_IMAGE}"
fi

# --- Create the per-combo Redmine container (own checkout) -------------------------
echo "==> [pulse-test] Creating combo container ${RM_CONTAINER}..."
remove_if_exists "${RM_CONTAINER}"
# 8>&- : do NOT leak the combo-lock fd into this container's conmon supervisor —
# otherwise conmon holds the flock for the container's whole lifetime and blocks
# every later run-tests.sh / down.sh for this combo.
podman run -d \
  --name "${RM_CONTAINER}" \
  --network "${NETWORK}" \
  -e RAILS_ENV=test \
  -v "${PLUGIN_SRC}:/usr/src/redmine/plugins/redmine_pulse:z" \
  "${REDMINE_IMAGE}" \
  tail -f /dev/null 8>&-

echo "==> [pulse-test] Waiting for container to be running..."
for i in $(seq 1 15); do
  STATUS=$(podman inspect --format '{{.State.Status}}' "${RM_CONTAINER}" 2>/dev/null || echo "missing")
  [ "${STATUS}" = "running" ] && { echo "    Running (${i}s)."; break; }
  sleep 1
done

# --- Write the per-combo database.yml test: block ---------------------------------
echo "==> [pulse-test] Writing config/database.yml (${DB}) ..."
if [ "${DB}" = "postgres" ]; then
  podman exec "${RM_CONTAINER}" bash -c "cat > /usr/src/redmine/config/database.yml <<'DBEOF'
test:
  adapter: postgresql
  host: ${PG_CONTAINER}
  port: 5432
  username: ${DB_USER}
  password: ${DB_PASSWORD}
  database: ${COMBO_DB}
  encoding: utf8
DBEOF
echo 'database.yml (postgres) written.'"
else
  podman exec "${RM_CONTAINER}" bash -c "cat > /usr/src/redmine/config/database.yml <<'DBEOF'
test:
  adapter: mysql2
  host: ${MYSQL_CONTAINER}
  port: 3306
  username: ${DB_USER}
  password: ${DB_PASSWORD}
  database: ${COMBO_DB}
  encoding: utf8mb4
DBEOF
echo 'database.yml (mysql) written.'"
fi

# --- Build tools (official image only; the built image already has them) ----------
if [ "${BUILD_FROM_TARBALL}" -eq 0 ]; then
  echo "==> [pulse-test] Installing build tools + DB client headers in official image..."
  podman exec "${RM_CONTAINER}" bash -c "
    apt-get update -qq 2>/dev/null
    apt-get install -y -q build-essential pkg-config libpq-dev default-libmysqlclient-dev libyaml-dev 2>&1 | tail -3
    chmod 1777 /usr/local/bundle/gems/ 2>/dev/null || true
    chmod 1777 /usr/local/bundle/extensions/x86_64-linux/3.4.0/ 2>/dev/null || true
    echo 'Build tools installed.'
  "
fi

# --- Runtime bundle (DEFECT FIX): use 'without development', NOT 'with test' -------
# On the redmine:6.1.2 image an app-level `without` overrides a local `with`, so
# `--local with test` silently skips the test group -> mocha/minitest LoadError.
# `--local without development` reliably installs the test group on both images.
echo "==> [pulse-test] Bundling gems (without development)..."
echo "    (first run compiles native extensions — several minutes)"
podman exec "${RM_CONTAINER}" bash -c "
  set -e
  cd /usr/src/redmine
  bundle config unset --local with  2>/dev/null || true
  bundle config set --local without 'development'
  bundle install 2>&1 | grep -E '(Installing|Bundle complete|error|Error)' | tail -20
  echo '--- verifying mocha (test group) installed ---'
  bundle list | grep -q mocha && echo 'OK: mocha present.' || { echo 'FATAL: mocha NOT installed — test group missing.'; exit 1; }
"

# --- Prepare the DB: secret token, create/migrate, plugin migrate -----------------
echo "==> [pulse-test] Preparing DB (secret token, migrate, plugin migrate)..."
podman exec -e RAILS_ENV=test "${RM_CONTAINER}" bash -c "
  set -e
  cd /usr/src/redmine
  [ -f config/initializers/secret_token.rb ] || bundle exec rake generate_secret_token 2>/dev/null || true
  echo '--- db:create ---'
  bundle exec rake db:create 2>&1 | tail -3 || true
  echo '--- db:migrate ---'
  bundle exec rake db:migrate 2>&1 | tail -5
  echo '--- redmine:plugins:migrate NAME=redmine_pulse ---'
  bundle exec rake redmine:plugins:migrate NAME=redmine_pulse 2>&1 | tail -5
  echo '--- DB prep complete ---'
"

echo ""
echo "==> [pulse-test] Combo UP: Redmine ${REDMINE_VERSION} x ${DB}"
echo "    Container : ${RM_CONTAINER} (${REDMINE_IMAGE})"
echo "    Test DB   : ${COMBO_DB}"
echo "    Network   : ${NETWORK}"
echo ""
echo "Next: REDMINE_VERSION=${REDMINE_VERSION} DB=${DB} ./run-tests.sh"
