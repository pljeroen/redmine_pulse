#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# down.sh — Tear down per-combo test harness resources.
# Idempotent: safe to run at any time.
#
# By DEFAULT this tears down ONE explicit combo (same param model as up.sh):
#   REDMINE_VERSION   default 6.1.2    (flag: --redmine-version / -r)
#   DB                default postgres  (flag: --db / -d ; postgres|mysql)
# It acquires that combo's per-combo lock first (flock -n): if the combo is busy
# (an up.sh / run-tests.sh holds the lock), it REFUSES rather than killing it.
#
# Removed for a single combo:
#   - container  pulse_test_rm_<ver>_<db>
#   - (with --dbs) DB  redmine_pulse_test_<ver>_<db>
#
# With --all it tears down EVERY combo: all pulse_test_rm_* containers and all
# pulse-test-redmine:* images. It flock -n's each combo lock and SKIPS (warns) any
# combo whose lock is currently held by a live run.
#
# It DELIBERATELY does NOT touch the SHARED substrate (network pulse_test_net,
# Postgres pulse_test_pg, MySQL pulse_test_mysql) — another session may be live on
# this host. Per-combo DBs (redmine_pulse_test_*) are left in place unless --dbs is
# passed. Pass --network to also remove the network if empty.
#
# SAFETY: NEVER stops/removes pulse_test_pg / pulse_test_mysql / pulse_test_net /
# pulse_test_redmine / pulse_rm7_redmine / pulse_preview_redmine, and NEVER drops
# redmine_test / redmine_pulse_plan_rm7* / redmine_pulse_preview.
set -euo pipefail

# --- Parameters -------------------------------------------------------------------
REDMINE_VERSION="${REDMINE_VERSION:-6.1.2}"
DB="${DB:-postgres}"

DROP_DBS=0
DROP_NETWORK=0
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--redmine-version) REDMINE_VERSION="$2"; shift 2 ;;
    -d|--db)              DB="$2"; shift 2 ;;
    --dbs)     DROP_DBS=1; shift ;;
    --network) DROP_NETWORK=1; shift ;;
    --all)     ALL=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--redmine-version <ver>] [--db postgres|mysql] [--dbs] [--network] [--all]"
      echo "  (default)  tear down ONE combo (REDMINE_VERSION x DB, defaults 6.1.2 x postgres):"
      echo "             its pulse_test_rm_<ver>_<db> container (+ its DB with --dbs)."
      echo "             Refuses if that combo is busy (a run holds its lock)."
      echo "  --all      tear down EVERY combo: all pulse_test_rm_* containers +"
      echo "             pulse-test-redmine:* images. Skips any combo whose lock is held."
      echo "  --dbs      also drop the per-combo DB(s) redmine_pulse_test_* (never shared DBs)"
      echo "  --network  also remove pulse_test_net if empty"
      echo "  env vars REDMINE_VERSION / DB are also honored."
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Input validation (H-001) — BEFORE any name/SQL/identifier derivation --------
# In default (single-combo) mode REDMINE_VERSION and DB become container/DB names
# and SQL identifiers, so validate strictly (same rules as up.sh). In --all mode
# these params are unused, but validating unconditionally is harmless and keeps the
# invariant simple.
if [ "${ALL}" -eq 0 ]; then
  if ! [[ "${REDMINE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: REDMINE_VERSION must be a bare X.Y.Z release (e.g. 6.1.2)." >&2
    echo "       Got: '${REDMINE_VERSION}'. Refusing to derive any resource name or SQL." >&2
    exit 2
  fi
  case "${DB}" in
    postgres|mysql) ;;
    *) echo "ERROR: DB must be exactly 'postgres' or 'mysql' (got '${DB}')." >&2; exit 2 ;;
  esac
fi

PG_CONTAINER="pulse_test_pg"
MYSQL_CONTAINER="pulse_test_mysql"
DB_USER="pulse_test"
DB_PASSWORD="pulse_test_secret"
MYSQL_ROOT_PASSWORD="rootsecret"
NETWORK="pulse_test_net"

# Strict guard: only DB names of the exact catalog shape are ever droppable.
# redmine_pulse_test_<digits/underscores>_<postgres|mysql>
COMBO_DB_RE='^redmine_pulse_test_[0-9]+(_[0-9]+)*_(postgres|mysql)$'

# --- Drop one validated per-combo DB, quoted for the target adapter ---------------
# $1 = adapter (postgres|mysql), $2 = db name. The COMBO_DB_RE regex is the primary
# guard; identifier quoting is defense-in-depth.
drop_combo_db() {
  local adapter="$1" name="$2"
  if ! [[ "${name}" =~ ${COMBO_DB_RE} ]]; then
    echo "    SKIPPED (name failed safety regex, NOT dropped): ${name}"
    return 0
  fi
  if [ "${adapter}" = "postgres" ]; then
    podman exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_CONTAINER}" \
      psql -U "${DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS \"${name}\"" >/dev/null 2>&1 \
      && echo "    Dropped pg DB ${name}." || echo "    (pg DB ${name} not dropped — may not exist)"
  else
    podman exec "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e \
      "DROP DATABASE IF EXISTS \`${name}\`" >/dev/null 2>&1 \
      && echo "    Dropped mysql DB ${name}." || echo "    (mysql DB ${name} not dropped — may not exist)"
  fi
}

# --- Drop a per-combo DB ONLY if its combo is not busy -----------------------------
# Used by --all, which (unlike the default single-combo path) does not otherwise hold
# the combo lock. A live run-tests.sh holds /tmp/pulse-test-rm-<ver>-<db>.lock; we must
# skip that combo's DB exactly like we skip its container, or --all could drop the DB
# out from under a live proof run. Derive the lock from the ALREADY-validated DB name
# (redmine_pulse_test_<ver>_<db>) and flock -n a dedicated fd (7, distinct from the
# single-combo path's fd 8). $1 = adapter, $2 = db name.
drop_combo_db_if_free() {
  local adapter="$1" name="$2"
  if ! [[ "${name}" =~ ${COMBO_DB_RE} ]]; then
    echo "    SKIPPED (name failed safety regex, NOT dropped): ${name}"
    return 0
  fi
  local rest="${name#redmine_pulse_test_}"
  local ndb="${rest##*_}"
  local nver="${rest%_*}"
  local nlock="/tmp/pulse-test-rm-${nver}-${ndb}.lock"
  exec 7>"${nlock}"
  if flock -n 7; then
    drop_combo_db "${adapter}" "${name}"
    flock -u 7
  else
    echo "    BUSY, SKIPPED DB (lock held by a live run): ${name}"
  fi
  exec 7>&-
}

if [ "${ALL}" -eq 0 ]; then
  # ============================ DEFAULT: ONE COMBO ================================
  VER_SAN="${REDMINE_VERSION//./_}"
  RM_CONTAINER="pulse_test_rm_${VER_SAN}_${DB}"
  COMBO_DB="redmine_pulse_test_${VER_SAN}_${DB}"
  COMBO_LOCK="/tmp/pulse-test-rm-${VER_SAN}-${DB}.lock"

  echo "==> [pulse-test] Tearing down combo ${REDMINE_VERSION} x ${DB}"
  echo "    container : ${RM_CONTAINER}"

  # Acquire the combo lock non-blocking; if busy, refuse (do NOT kill a live run).
  exec 8>"${COMBO_LOCK}"
  if ! flock -n 8; then
    echo "ERROR: combo ${VER_SAN}/${DB} is BUSY (its lock is held by a live up.sh/run-tests.sh)." >&2
    echo "       Refusing to tear it down mid-flight. Wait for it to finish, then re-run." >&2
    exit 2
  fi

  if podman container exists "${RM_CONTAINER}" 2>/dev/null; then
    podman rm -f "${RM_CONTAINER}" 8>&- >/dev/null 2>&1 && echo "    Removed ${RM_CONTAINER}." || true
  else
    echo "    No container ${RM_CONTAINER} found."
  fi

  if [ "${DROP_DBS}" -eq 1 ]; then
    echo "==> [pulse-test] Dropping per-combo DB ${COMBO_DB}..."
    if [ "${DB}" = "postgres" ]; then
      podman container exists "${PG_CONTAINER}" 2>/dev/null && drop_combo_db postgres "${COMBO_DB}" \
        || echo "    ${PG_CONTAINER} not present — nothing to drop."
    else
      podman container exists "${MYSQL_CONTAINER}" 2>/dev/null && drop_combo_db mysql "${COMBO_DB}" \
        || echo "    ${MYSQL_CONTAINER} not present — nothing to drop."
    fi
  else
    echo "==> [pulse-test] Leaving per-combo DB ${COMBO_DB} in place (pass --dbs to drop it)."
  fi
else
  # ============================ --all: EVERY COMBO ===============================
  echo "==> [pulse-test] --all: tearing down EVERY combo (skipping any busy one)..."

  # (1) Containers: for each pulse_test_rm_<VER_SAN>_<db>, flock -n its combo lock;
  #     skip + warn if held (a live run owns it).
  COMBO_CONTAINERS=$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^pulse_test_rm_' || true)
  if [ -n "${COMBO_CONTAINERS}" ]; then
    while IFS= read -r c; do
      [ -z "${c}" ] && continue
      # Parse <VER_SAN>_<db> back out of pulse_test_rm_<VER_SAN>_<db>.
      rest="${c#pulse_test_rm_}"
      cdb="${rest##*_}"
      cver="${rest%_*}"
      case "${cdb}" in postgres|mysql) ;; *)
        echo "    SKIPPED (unrecognized combo name): ${c}"; continue ;;
      esac
      clock="/tmp/pulse-test-rm-${cver}-${cdb}.lock"
      # flock -n on a dedicated fd; SKIP (do not kill) any combo a live run holds.
      # 8>&- on podman rm keeps the removed container's exit handling from
      # inheriting the lock fd.
      exec 8>"${clock}"
      if flock -n 8; then
        podman rm -f "${c}" 8>&- >/dev/null 2>&1 && echo "    Removed ${c}." || true
        flock -u 8
      else
        echo "    BUSY, SKIPPED (lock held by a live run): ${c}"
      fi
    done <<< "${COMBO_CONTAINERS}"
  else
    echo "    No pulse_test_rm_* containers found."
  fi

  # (2) Built images.
  echo "==> [pulse-test] Removing built images (pulse-test-redmine:*)..."
  COMBO_IMAGES=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '^(localhost/)?pulse-test-redmine:' || true)
  if [ -n "${COMBO_IMAGES}" ]; then
    while IFS= read -r img; do
      [ -z "${img}" ] && continue
      podman rmi -f "${img}" >/dev/null 2>&1 && echo "    Removed image ${img}." || true
    done <<< "${COMBO_IMAGES}"
  else
    echo "    No pulse-test-redmine:* images found."
  fi

  # (3) DBs: enumerate the catalog, validate each name against the strict regex,
  #     drop only matches (quoted). --all implies dropping the per-combo DBs too.
  echo "==> [pulse-test] Dropping per-combo DBs (redmine_pulse_test_*)..."
  if podman container exists "${PG_CONTAINER}" 2>/dev/null; then
    PG_DBS=$(podman exec -e PGPASSWORD="${DB_PASSWORD}" "${PG_CONTAINER}" \
      psql -U "${DB_USER}" -d postgres -tAc \
      "SELECT datname FROM pg_database WHERE datname LIKE 'redmine_pulse_test_%'" 2>/dev/null || true)
    while IFS= read -r d; do
      d="$(echo "${d}" | tr -d '[:space:]')"; [ -z "${d}" ] && continue
      drop_combo_db_if_free postgres "${d}"
    done <<< "${PG_DBS}"
  fi
  if podman container exists "${MYSQL_CONTAINER}" 2>/dev/null; then
    MY_DBS=$(podman exec "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e \
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'redmine_pulse_test_%'" 2>/dev/null || true)
    while IFS= read -r d; do
      d="$(echo "${d}" | tr -d '[:space:]')"; [ -z "${d}" ] && continue
      drop_combo_db_if_free mysql "${d}"
    done <<< "${MY_DBS}"
  fi
fi

if [ "${DROP_NETWORK}" -eq 1 ]; then
  echo "==> [pulse-test] Removing network ${NETWORK} if empty..."
  # Only succeeds if no container (shared pg/mysql included) is still attached; if
  # the shared DBs are up, this is a no-op — that is the safe outcome.
  podman network rm "${NETWORK}" >/dev/null 2>&1 \
    && echo "    Removed ${NETWORK}." \
    || echo "    ${NETWORK} still in use (shared DBs attached) — left as-is."
fi

echo ""
echo "==> [pulse-test] Teardown complete. Shared substrate left untouched."
