#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# run-tests.sh — Prepare the test DB and run plugin tests inside pulse_test_redmine.
# Runs RAILS_ENV=test; touches only pulse_test_* containers.
#
# PROOF-RUN ISOLATION (HARNESS-ISO, documented, enforced below):
#   The full plugin suite shares ONE Postgres test DB (redmine_test). A CONCURRENT
#   test/rails process on that DB (a second run-tests.sh, an ad-hoc
#   `ruby -Itest plugins/redmine_pulse/<file>.rb`, or an external review that runs the
#   suite) causes non-deterministic PG deadlocks AND PK-sequence collisions
#   (custom_values_pkey / projects_pkey UniqueViolation) — NOT a product or ordering
#   bug: the suite is deterministically clean when it has redmine_test to itself.
#   This script makes isolation mechanical: (1) a host flock serializes run-tests.sh
#   invocations; (2) a preflight refuses to start (exit 2) if any FOREIGN connection is
#   already busy on redmine_test — fail loud rather than emit a possibly-corrupted result.
#
# LOAD-PATH NOTE (documented, not a bug):
#   Redmine's rake task picks up test/unit/domain/ tests and runs them under
#   Rails' load path. Two tests (DomainPurityTest and TimelineDomainPurityTest
#   #test_suite_loads_without_rails_or_redmine) are bare-process purity guards that
#   assert Rails/Redmine are NOT loaded. They are only meaningful in the pure-domain
#   lane; under this rake harness Rails is booted first, so they SKIP (they are
#   verified in the pure-domain lane). The harness therefore reports 0 failures with
#   2 skips. All other domain tests pass. Functional tests
#   (test/functional/, test/integration/) use Redmine's test_helper and run clean.
set -euo pipefail

RM_CONTAINER="pulse_test_redmine"
PG_CONTAINER="pulse_test_pg"

# Verify containers are running
for c in "${RM_CONTAINER}" "${PG_CONTAINER}"; do
  STATUS=$(podman inspect --format '{{.State.Status}}' "${c}" 2>/dev/null || echo "missing")
  if [ "${STATUS}" != "running" ]; then
    echo "ERROR: Container ${c} is not running (status: ${STATUS})."
    echo "Run ./up.sh first."
    exit 1
  fi
done

# --- Proof-run isolation guard (HARNESS-ISO) --------------------------------------
# (1) Serialize run-tests.sh invocations on this host: hold an exclusive lock for the
#     whole run so two invocations queue instead of colliding on redmine_test.
LOCK_FILE="/tmp/pulse-redmine-test.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "==> [pulse-test] Another run-tests.sh holds the lock; waiting for it to finish..."
  flock 9
fi

# (2) Refuse to start if ANY foreign backend is attached to redmine_test (an ad-hoc
#     single-file test run or an ad-hoc test probe won't take the lock above, so detect it
#     directly). We count ALL foreign connections — not just busy ones — because a test
#     process idle between statements at the sampling instant will resume and still collide
#     (HISO-002). FAIL CLOSED (HISO-001): if the preflight query itself cannot be run, we
#     refuse rather than assume isolation — a proof run must never start unverified.
FOREIGN_CONNS=$(podman exec -e PGPASSWORD=pulse_test_secret "${PG_CONTAINER}" \
  psql -U pulse_test -d redmine_test -tAc \
  "SELECT count(*) FROM pg_stat_activity WHERE datname='redmine_test' AND pid <> pg_backend_pid()" \
  2>/dev/null | tr -d '[:space:]') || true
if ! [[ "${FOREIGN_CONNS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not verify redmine_test isolation — the pg_stat_activity preflight query"
  echo "failed (is ${PG_CONTAINER} up and reachable?). Refusing to run rather than emit a"
  echo "possibly-corrupted proof result. Fix the DB access and re-run."
  exit 3
fi
if [ "${FOREIGN_CONNS}" -gt 0 ]; then
  echo "ERROR: ${FOREIGN_CONNS} other connection(s) are attached to redmine_test right now."
  echo "A proof run must have redmine_test to itself — concurrent test processes cause PG"
  echo "deadlocks and PK-sequence collisions. Wait for other test/rails processes (including"
  echo "ad-hoc 'ruby -Itest ...' runs and other test probes) to finish, then re-run."
  exit 2
fi
# ----------------------------------------------------------------------------------

echo "==> [pulse-test] Preparing test database inside ${RM_CONTAINER}..."
podman exec -e RAILS_ENV=test "${RM_CONTAINER}" bash -c "
  set -e
  cd /usr/src/redmine

  echo '--- Generating Redmine secret token if needed ---'
  [ -f config/initializers/secret_token.rb ] || bundle exec rake generate_secret_token RAILS_ENV=test 2>/dev/null || true

  echo '--- Ensuring test DB exists ---'
  bundle exec rake db:create RAILS_ENV=test 2>&1 || true

  echo '--- Loading Redmine schema + running all migrations ---'
  bundle exec rake db:migrate RAILS_ENV=test 2>&1 | tail -5

  echo '--- Running plugin migrations ---'
  bundle exec rake redmine:plugins:migrate RAILS_ENV=test 2>&1 | tail -5

  echo '--- DB preparation complete ---'
"

echo ""
echo "==> [pulse-test] Running: rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test"
echo ""
echo "NOTE: The two bare-process purity guards (DomainPurityTest /"
echo "TimelineDomainPurityTest#test_suite_loads_without_rails_or_redmine) SKIP under this"
echo "rake task (Rails is loaded by the harness itself; they are verified in the pure-domain"
echo "lane). Expect 0 failures with 2 skips. Any other skip/failure is a real signal."
echo ""

set +e
podman exec -e RAILS_ENV=test "${RM_CONTAINER}" bash -c "
  cd /usr/src/redmine
  echo '=== Plugin test run start ==='
  bundle exec rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test 2>&1
  EXIT_CODE=\$?
  echo ''
  echo '=== Plugin test run complete (exit: '\${EXIT_CODE}') ==='
  exit \${EXIT_CODE}
"
RC=$?
set -e

echo ""
if [ "${RC}" -eq 0 ]; then
  echo "==> [pulse-test] All tests passed."
elif [ "${RC}" -eq 1 ]; then
  echo "==> [pulse-test] Test run reported failures (exit ${RC})."
  echo "    The harness is expected to be CLEAN: 0 failures with 2 skips (the two"
  echo "    bare-process purity guards). Any reported failure is a real signal — investigate it."
  echo "    Functional tests should be placed in test/functional/ and test/integration/."
else
  echo "==> [pulse-test] Test run exited with code ${RC} (likely an error, not a test failure)."
fi
exit "${RC}"
