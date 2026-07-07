#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# up.sh — Bring up the isolated pulse_test_* Redmine 6.1.2 test harness.
# SAFETY: this script ONLY creates/touches pulse_test_* resources; it never
# touches any other container, network, or volume on the host.
set -euo pipefail

PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REDMINE_IMAGE="docker.io/library/redmine:6.1.2"
POSTGRES_IMAGE="docker.io/library/postgres:16-alpine"

NETWORK="pulse_test_net"
PG_CONTAINER="pulse_test_pg"
RM_CONTAINER="pulse_test_redmine"
VOLUME="pulse_test_pgdata"

PG_USER="pulse_test"
PG_PASSWORD="pulse_test_secret"
PG_DB="redmine_test"

# Helper: stop+remove a container if it exists in any state (running or exited)
remove_if_exists() {
  local name="$1"
  if podman container exists "${name}" 2>/dev/null; then
    podman stop "${name}" --time 5 2>/dev/null || true
    podman rm -f "${name}" 2>/dev/null || true
    echo "    Removed stale container: ${name}"
  fi
}

echo "==> [pulse-test] Creating isolated network: ${NETWORK}"
if ! podman network exists "${NETWORK}" 2>/dev/null; then
  podman network create "${NETWORK}"
else
  echo "    Network ${NETWORK} already exists — skipping."
fi

echo "==> [pulse-test] Creating volume: ${VOLUME}"
if ! podman volume exists "${VOLUME}" 2>/dev/null; then
  podman volume create "${VOLUME}"
else
  echo "    Volume ${VOLUME} already exists — skipping."
fi

echo "==> [pulse-test] Starting Postgres container: ${PG_CONTAINER}"
PG_STATUS=$(podman inspect --format '{{.State.Status}}' "${PG_CONTAINER}" 2>/dev/null || echo "missing")
if [ "${PG_STATUS}" = "running" ]; then
  echo "    Container ${PG_CONTAINER} already running — skipping."
elif [ "${PG_STATUS}" = "missing" ]; then
  podman run -d \
    --name "${PG_CONTAINER}" \
    --network "${NETWORK}" \
    -e POSTGRES_USER="${PG_USER}" \
    -e POSTGRES_PASSWORD="${PG_PASSWORD}" \
    -e POSTGRES_DB="${PG_DB}" \
    -v "${VOLUME}:/var/lib/postgresql/data:z" \
    "${POSTGRES_IMAGE}"
else
  # exited or other non-running state — remove and re-create
  echo "    Container ${PG_CONTAINER} is in state '${PG_STATUS}' — removing and re-creating."
  remove_if_exists "${PG_CONTAINER}"
  podman run -d \
    --name "${PG_CONTAINER}" \
    --network "${NETWORK}" \
    -e POSTGRES_USER="${PG_USER}" \
    -e POSTGRES_PASSWORD="${PG_PASSWORD}" \
    -e POSTGRES_DB="${PG_DB}" \
    -v "${VOLUME}:/var/lib/postgresql/data:z" \
    "${POSTGRES_IMAGE}"
fi

echo "==> [pulse-test] Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
  if podman exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" -d "${PG_DB}" &>/dev/null; then
    echo "    Postgres ready (${i}s)."
    break
  fi
  sleep 1
done

echo "==> [pulse-test] Starting Redmine container: ${RM_CONTAINER}"
RM_STATUS=$(podman inspect --format '{{.State.Status}}' "${RM_CONTAINER}" 2>/dev/null || echo "missing")
if [ "${RM_STATUS}" = "running" ]; then
  echo "    Container ${RM_CONTAINER} already running — skipping."
else
  if [ "${RM_STATUS}" != "missing" ]; then
    echo "    Container ${RM_CONTAINER} is in state '${RM_STATUS}' — removing and re-creating."
    remove_if_exists "${RM_CONTAINER}"
  fi
  podman run -d \
    --name "${RM_CONTAINER}" \
    --network "${NETWORK}" \
    -e REDMINE_DB_POSTGRES="${PG_CONTAINER}" \
    -e REDMINE_DB_DATABASE="${PG_DB}" \
    -e REDMINE_DB_USERNAME="${PG_USER}" \
    -e REDMINE_DB_PASSWORD="${PG_PASSWORD}" \
    -e REDMINE_SECRET_KEY_BASE="pulse_test_secret_key_not_for_prod" \
    -e RAILS_ENV=test \
    -v "${PLUGIN_SRC}:/usr/src/redmine/plugins/redmine_pulse:z" \
    "${REDMINE_IMAGE}" \
    tail -f /dev/null

  echo "==> [pulse-test] Waiting for Redmine container to be running..."
  for i in $(seq 1 15); do
    STATUS=$(podman inspect --format '{{.State.Status}}' "${RM_CONTAINER}" 2>/dev/null || echo "missing")
    if [ "${STATUS}" = "running" ]; then
      echo "    Redmine container running (${i}s)."
      break
    fi
    sleep 1
  done

  echo "==> [pulse-test] Writing database.yml for RAILS_ENV=test..."
  podman exec "${RM_CONTAINER}" bash -c "
cat > /usr/src/redmine/config/database.yml <<'DBEOF'
test:
  adapter: postgresql
  host: ${PG_CONTAINER}
  port: 5432
  username: ${PG_USER}
  password: ${PG_PASSWORD}
  database: ${PG_DB}
  encoding: utf8
DBEOF
echo 'database.yml written.'
"

  echo "==> [pulse-test] Installing build tools (required for native gem extensions)..."
  podman exec "${RM_CONTAINER}" bash -c "
    apt-get update -qq 2>/dev/null
    apt-get install -y -q build-essential libpq-dev libyaml-dev 2>&1 | tail -3
    echo 'Build tools installed.'
  "

  echo "==> [pulse-test] Fixing bundle directory permissions..."
  podman exec "${RM_CONTAINER}" bash -c "
    chmod 1777 /usr/local/bundle/gems/ 2>/dev/null || true
    chmod 1777 /usr/local/bundle/extensions/x86_64-linux/3.4.0/ 2>/dev/null || true
  " 2>/dev/null || true

  echo "==> [pulse-test] Enabling bundler test group and installing gems..."
  echo "    (This may take several minutes on first run — native extensions compile)"
  podman exec "${RM_CONTAINER}" bash -c "
    set -e
    cd /usr/src/redmine
    # The global bundle config in the image uses BUNDLE_WITH for groups,
    # and GEM_HOME=/usr/local/bundle. Add 'test' to the with-list.
    bundle config set --local with 'test'
    bundle install 2>&1 | grep -E '(Installing|Bundle complete|error|Error)' | tail -20
    echo 'bundle install done.'
  "
fi

echo ""
echo "==> [pulse-test] Stack is UP."
echo "    Redmine: ${RM_CONTAINER} (${REDMINE_IMAGE})"
echo "    Postgres: ${PG_CONTAINER} (${POSTGRES_IMAGE})"
echo "    Network: ${NETWORK} | Volume: ${VOLUME}"
echo ""
echo "Next: run ./run-tests.sh"
