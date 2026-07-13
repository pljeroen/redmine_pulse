# redmine_pulse — Parameterized Test Matrix Harness

## Purpose

Podman-based harness to run `rake redmine:plugins:test` for the `redmine_pulse`
plugin across a **matrix of Redmine versions x databases**. Every combo is a
distinct, reproducible, isolated stack:

| Combo | Redmine | Rails | Database | Ruby |
|-------|---------|-------|----------|------|
| 6.1.2 x postgres | 6.1.2 | 7.2 | PostgreSQL 16 | 3.4 |
| 6.1.2 x mysql    | 6.1.2 | 7.2 | MySQL 8       | 3.4 |
| 7.0.0 x postgres | 7.0.0 | 8.1 | PostgreSQL 16 | 3.4 |
| 7.0.0 x mysql    | 7.0.0 | 8.1 | MySQL 8       | 3.4 |

## Isolation model

- **Shared substrate (reused, never recreated):** network `pulse_test_net`,
  Postgres `pulse_test_pg`, MySQL `pulse_test_mysql`. `up.sh` ensures these exist
  (creating them only if absent) and never stops or removes them.
- **Per-combo (created/removed by this harness only):**
  - container `pulse_test_rm_<ver>_<db>` (e.g. `pulse_test_rm_7_0_0_mysql`) — its
    OWN Redmine checkout, so a PostgreSQL-format `db/schema.rb` can never leak into
    a MySQL leg;
  - test DB `redmine_pulse_test_<ver>_<db>` — distinct per combo;
  - built image `pulse-test-redmine:<ver>` for versions without an official image.

Every combo therefore has a distinct DB **and** a distinct container, so nothing
collides with another combo or another session on the same host.

## Version -> image routing

- **6.1.x** -> official `docker.io/library/redmine:<ver>`.
- **7.0.x** (and any version with no official image — Docker Hub's newest
  `redmine` is 6.1.3) -> built from `Dockerfile` using the official release tarball
  `https://www.redmine.org/releases/redmine-<ver>.tar.gz` on `ruby:3.4-slim-bookworm`.
  Both `libpq-dev` and `default-libmysqlclient-dev` are installed so one image
  serves either DB; gems are bundled at runtime (the gem set is DB-dependent).

## Commands

```sh
cd scripts/test-redmine

# Bring up one combo (defaults: REDMINE_VERSION=6.1.2 DB=postgres)
REDMINE_VERSION=6.1.2 DB=postgres  ./up.sh
REDMINE_VERSION=6.1.2 DB=mysql     ./up.sh
REDMINE_VERSION=7.0.0 DB=postgres  ./up.sh
REDMINE_VERSION=7.0.0 DB=mysql     ./up.sh
# flags also work:  ./up.sh --redmine-version 7.0.0 --db mysql

# Run the suite for the matching combo (same params)
REDMINE_VERSION=7.0.0 DB=mysql ./run-tests.sh

# Tear down ONE combo (default: REDMINE_VERSION=6.1.2 DB=postgres, same params as up.sh).
# Refuses if that combo is busy (a live up.sh/run-tests.sh holds its lock).
REDMINE_VERSION=7.0.0 DB=mysql ./down.sh          # its pulse_test_rm_ container
REDMINE_VERSION=7.0.0 DB=mysql ./down.sh --dbs    # also drop that combo's DB

# Tear down EVERY combo (all pulse_test_rm_* containers + pulse-test-redmine:* images
# + all redmine_pulse_test_* DBs). Skips (warns on) any combo whose lock is held.
./down.sh --all
./down.sh --all --network  # also remove pulse_test_net if empty
```

Run combos **sequentially** — they share the same Postgres/MySQL servers.

## Expected results

A combo is **GREEN iff 0 failures AND 0 errors**.

| Combo | runs | failures | errors | skips |
|-------|------|----------|--------|-------|
| 6.1.2 x postgres | 1254 | 0 | 0 | ~4   |
| 6.1.2 x mysql    | 1254 | 0 | 0 | ~324 |
| 7.0.0 x postgres | 1254 | 0 | 0 | ~4   |
| 7.0.0 x mysql    | 1254 | 0 | 0 | ~324 |

- **~4 PG skips** — bare-process purity guards (`DomainPurityTest` /
  `TimelineDomainPurityTest#test_suite_loads_without_rails_or_redmine`) skip under
  the rake task (Rails is booted first; they are verified in the pure-domain lane).
- **~324 MySQL skips** — PG-gated functional tests skip on MySQL by policy.

## Proof-run isolation guard (HARNESS-ISO)

`run-tests.sh` makes single-writer isolation mechanical:

1. a host `flock` **keyed on the combo DB** (`/tmp/pulse-redmine-test.<db>.lock`)
   serializes runs of the same combo without falsely serializing different combos;
2. a preflight refuses to start (exit 2) if any FOREIGN connection is already
   attached to **this combo's DB**, and fails closed (exit 3) if the preflight
   query itself cannot run.

The preflight probes the **actual adapter/server** for the combo (PostgreSQL
`pg_stat_activity` or MySQL `information_schema.processlist`).

## Two defect fixes baked into this harness

1. **Test-group install.** On the `redmine:6.1.2` image an app-level bundler
   `without` overrides a local `with`, so `bundle config set --local with 'test'`
   silently skips the test group and `mocha`/`minitest` raise `LoadError`. `up.sh`
   uses `bundle config set --local without 'development'` instead and asserts
   `mocha` is present after `bundle install`.
2. **Isolation-guard adapter.** The previous harness always probed
   `pulse_test_pg`/`redmine_test` even on a MySQL run. The guard now probes the
   combo's real DB on its real server (postgres or mysql).

## Files

| File | Role |
|------|------|
| `Dockerfile`   | Tarball build for versions without an official image (7.0.x+). |
| `up.sh`        | Bring up one (version x DB) combo. |
| `run-tests.sh` | Run the suite for one combo (with isolation guard). |
| `down.sh`      | Tear down ONE combo (default) or every combo (`--all`); shared substrate safe, refuses/skips busy combos. |
