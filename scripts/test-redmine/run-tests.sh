#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# run-tests.sh — Run the plugin test suite for ONE (Redmine version x DB) combo.
#
# Parameters (same as up.sh):
#   REDMINE_VERSION   default 6.1.2    (flag: --redmine-version / -r)
#   DB                default postgres  (flag: --db / -d ; postgres|mysql)
#
# Each combo has its OWN container + OWN test DB, so combos are isolated from
# each other and from any other session on this shared host.
#
# PROOF-RUN ISOLATION (HARNESS-ISO, enforced below):
#   A CONCURRENT test/rails process on the SAME combo DB causes non-deterministic
#   DB deadlocks AND PK-sequence collisions — not a product bug: the suite is
#   deterministically clean when it has its combo DB to itself. Isolation is
#   mechanical: (1) a host flock (keyed per combo DB) serializes invocations;
#   (2) a preflight refuses to start if any FOREIGN connection is already busy on
#   THIS combo's DB. FIX vs. the old harness: the preflight now guards the ACTUAL
#   combo DB on the ACTUAL adapter/server (postgres OR mysql) — the old code always
#   probed pulse_test_pg/redmine_test even for a mysql run.
#
# LOAD-PATH NOTE (documented, not a bug):
#   Two bare-process purity guards (DomainPurityTest / TimelineDomainPurityTest
#   #test_suite_loads_without_rails_or_redmine) SKIP under this rake task (Rails is
#   booted first; they are verified in the pure-domain lane). PG legs report ~4
#   skips; MySQL legs ~324 skips (PG-gated functional tests skip by policy). Expect
#   0 failures and 0 errors on every combo.
set -euo pipefail

# --- Parameters -------------------------------------------------------------------
REDMINE_VERSION="${REDMINE_VERSION:-6.1.2}"
DB="${DB:-postgres}"

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--redmine-version) REDMINE_VERSION="$2"; shift 2 ;;
    -d|--db)              DB="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--redmine-version <ver>] [--db postgres|mysql]"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Input validation (H-001) — BEFORE any name/SQL/identifier derivation --------
# Same rules as up.sh: REDMINE_VERSION and DB flow into container names, DB names,
# and SQL literals/identifiers. Validate strictly before deriving VER_SAN / COMBO_DB
# so nothing downstream can be an injection vector against the shared DB servers.
if ! [[ "${REDMINE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: REDMINE_VERSION must be a bare X.Y.Z release (e.g. 6.1.2)." >&2
  echo "       Got: '${REDMINE_VERSION}'. Refusing to derive any resource name or SQL." >&2
  exit 2
fi
case "${DB}" in
  postgres|mysql) ;;
  *) echo "ERROR: DB must be exactly 'postgres' or 'mysql' (got '${DB}')." >&2; exit 2 ;;
esac

VER_SAN="${REDMINE_VERSION//./_}"

PG_CONTAINER="pulse_test_pg"
MYSQL_CONTAINER="pulse_test_mysql"
DB_USER="pulse_test"
DB_PASSWORD="pulse_test_secret"
MYSQL_ROOT_PASSWORD="rootsecret"

RM_CONTAINER="pulse_test_rm_${VER_SAN}_${DB}"
COMBO_DB="redmine_pulse_test_${VER_SAN}_${DB}"

if [ "${DB}" = "postgres" ]; then
  DB_CONTAINER="${PG_CONTAINER}"
else
  DB_CONTAINER="${MYSQL_CONTAINER}"
fi

# --- Verify the combo container + its DB server are running ------------------------
for c in "${RM_CONTAINER}" "${DB_CONTAINER}"; do
  STATUS=$(podman inspect --format '{{.State.Status}}' "${c}" 2>/dev/null || echo "missing")
  if [ "${STATUS}" != "running" ]; then
    echo "ERROR: Container ${c} is not running (status: ${STATUS})."
    echo "Run: REDMINE_VERSION=${REDMINE_VERSION} DB=${DB} ./up.sh first."
    exit 1
  fi
done

# --- Per-combo lifecycle lock (M-002) ---------------------------------------------
# Hold the SAME per-combo lock up.sh/down.sh use for the whole test run, so a
# concurrent up.sh or down.sh for THIS combo cannot remove the container/DB
# mid-flight. Different combos have different lock files -> no false serialization.
COMBO_LOCK="/tmp/pulse-test-rm-${VER_SAN}-${DB}.lock"
exec 8>"${COMBO_LOCK}"
if ! flock -n 8; then
  echo "==> [pulse-test] Combo ${VER_SAN}/${DB} is busy (lock held); waiting for it..."
  flock 8
fi

# --- Proof-run isolation guard (HARNESS-ISO) --------------------------------------
# (1) Serialize invocations keyed on THIS combo DB so two runs of the same combo
#     queue instead of colliding. Different combos have different DBs -> no false
#     serialization.
LOCK_FILE="/tmp/pulse-redmine-test.${COMBO_DB}.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "==> [pulse-test] Another run holds the lock for ${COMBO_DB}; waiting..."
  flock 9
fi

# (2) Refuse to start if ANY foreign backend is attached to THIS combo DB. We
#     probe the ACTUAL adapter/server (the old harness always probed postgres —
#     the fixed defect). FAIL CLOSED: if the preflight query itself cannot run,
#     refuse rather than emit a possibly-corrupted proof result.
if [ "${DB}" = "postgres" ]; then
  FOREIGN_CONNS=$(podman exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_CONTAINER}" \
    psql -U "${DB_USER}" -d "${COMBO_DB}" -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname='${COMBO_DB}' AND pid <> pg_backend_pid()" \
    2>/dev/null | tr -d '[:space:]') || true
else
  # Count threads whose db is this combo DB, excluding our own probe connection.
  FOREIGN_CONNS=$(podman exec "${MYSQL_CONTAINER}" \
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e \
    "SELECT count(*) FROM information_schema.processlist WHERE db='${COMBO_DB}' AND id <> CONNECTION_ID()" \
    2>/dev/null | tr -d '[:space:]') || true
fi

if ! [[ "${FOREIGN_CONNS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not verify ${COMBO_DB} isolation on ${DB_CONTAINER} — the"
  echo "preflight query failed. Refusing to run rather than emit a possibly-corrupted"
  echo "proof result. Fix DB access and re-run."
  exit 3
fi
if [ "${FOREIGN_CONNS}" -gt 0 ]; then
  echo "ERROR: ${FOREIGN_CONNS} other connection(s) attached to ${COMBO_DB} right now."
  echo "A proof run must have its combo DB to itself — concurrent processes cause"
  echo "deadlocks and PK collisions. Wait for them to finish, then re-run."
  exit 2
fi
# ----------------------------------------------------------------------------------

echo "==> [pulse-test] Combo: Redmine ${REDMINE_VERSION} x ${DB}  (DB ${COMBO_DB})"
echo "==> [pulse-test] Ensuring test DB is migrated inside ${RM_CONTAINER}..."
podman exec -e RAILS_ENV=test "${RM_CONTAINER}" bash -c "
  set -e
  cd /usr/src/redmine
  [ -f config/initializers/secret_token.rb ] || bundle exec rake generate_secret_token 2>/dev/null || true
  bundle exec rake db:create 2>&1 | tail -2 || true
  echo '--- db:migrate ---'
  bundle exec rake db:migrate 2>&1 | tail -5
  echo '--- redmine:plugins:migrate ---'
  bundle exec rake redmine:plugins:migrate NAME=redmine_pulse 2>&1 | tail -5
"

echo ""
echo "==> [pulse-test] Running: rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test"
echo "    Expect 0 failures / 0 errors. Skips: PG ~4, MySQL ~324 (PG-gated by policy)."
echo ""

set +e
podman exec -e RAILS_ENV=test "${RM_CONTAINER}" bash -c "
  cd /usr/src/redmine
  echo '=== Plugin test run start ==='
  bundle exec rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test 2>&1
  EC=\$?
  echo ''
  echo '=== Plugin test run complete (exit: '\${EC}') ==='
  exit \${EC}
"
RC=$?
set -e

echo ""
if [ "${RC}" -eq 0 ]; then
  echo "==> [pulse-test] GREEN: Redmine ${REDMINE_VERSION} x ${DB} — all tests passed."
elif [ "${RC}" -eq 1 ]; then
  echo "==> [pulse-test] RED: Redmine ${REDMINE_VERSION} x ${DB} reported failures/errors."
  echo "    A combo is GREEN iff 0 failures AND 0 errors. Investigate."
else
  echo "==> [pulse-test] Redmine ${REDMINE_VERSION} x ${DB} exited ${RC} (likely a harness error)."
fi
exit "${RC}"
