# redmine_pulse — Isolated Functional Test Harness

## Purpose

Isolated Podman-based harness to run `rake redmine:plugins:test` for the
`redmine_pulse` plugin against a real Redmine 6.1.2 instance + Postgres 16.

## Isolation guarantee

All resources are prefixed `pulse_test_*` and exist on a dedicated network.
This harness **never touches** any container, network, volume, or image outside
its own `pulse_test_*` set.

## Versions

| Component | Image                                  |
|-----------|----------------------------------------|
| Redmine   | `docker.io/library/redmine:6.1.2`      |
| Postgres  | `docker.io/library/postgres:16-alpine` |

## Commands

```sh
# 1. Bring up the stack (first run installs build tools + gems — takes minutes)
./scripts/test-redmine/up.sh

# 2. Run the plugin tests
./scripts/test-redmine/run-tests.sh

# 3. Tear down everything (idempotent)
./scripts/test-redmine/down.sh
```

## Smoke-test result (2026-06-20)

Status: **WORKS-WITH-CAVEAT**

- Redmine 6.1.2 (docker.io/library/redmine:6.1.2, Debian 13 trixie, Ruby 3.4)
- Postgres 16-alpine
- `rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test` runs the full
  functional/integration + domain suite to completion. Expect **0 failures and
  2 skips** — the 2 skips are the bare-process purity guards described in the
  caveat below (they are only meaningful in the standalone domain lane). Any other
  skip or failure is a real signal.

## Domain unit tests vs. Redmine functional tests — load-path caveat

The plugin has two test suites with **different load paths**:

### Standalone domain suite (`test/unit/domain/`)

Uses `test/domain_test_helper.rb` — plain Minitest, `-Ilib` only.
Zero Redmine dependency. Intended to run standalone:

```sh
ruby -Itest -Ilib test/unit/domain/scoring_formula_test.rb
```

When Redmine's rake task picks up these tests, they run under Rails' load path.
**Two tests assert Rails/Redmine are not loaded** (`DomainPurityTest` and
`TimelineDomainPurityTest`, `#test_suite_loads_without_rails_or_redmine`). Those
guards are only meaningful in the standalone domain lane, so under
`rake redmine:plugins:test` — where Rails is booted first — they **SKIP** rather
than fail. That is the source of the expected 2 skips; they are verified in the
standalone lane. All other domain tests pass correctly.

Do NOT modify the domain tests to force these two guards green under rake. The
standalone suite stays standalone; the Redmine task is for functional tests.

### Functional / integration suite (`test/functional/`, `test/integration/`)

Uses `test/test_helper.rb` — requires Redmine's test_helper.
Run via Redmine's rake task (what this harness is for):

```sh
rake redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test
```

### Scoping rules for the functional test suite

- File location: `test/functional/pulse_<feature>_test.rb`
- First line: `require File.expand_path('../../../../test/test_helper', __FILE__)`
  (already wired in `test/test_helper.rb` — just `require 'test_helper'`)
- The standalone domain suite in `test/unit/domain/` stays untouched.
- The `DomainPurityTest` / `TimelineDomainPurityTest` **skip** under
  `rake redmine:plugins:test` is expected as-is (it proves the isolation is real).

## First-run prerequisites (handled by up.sh)

The official `redmine:6.1.2` image (Debian) ships without build tools
(gcc, make) and native dev headers. `up.sh` installs these into the container
on first run:

- `build-essential` — gcc, make, etc. (for native gem extensions)
- `libpq-dev` — PostgreSQL client headers (for the `pg` gem)
- `libyaml-dev` — YAML headers (for the `psych` gem)

These installs are not persistent across container re-creation. `up.sh` always
runs them on a fresh container.

## Resources created

| Resource           | Name                |
|--------------------|---------------------|
| Podman network     | `pulse_test_net`    |
| Postgres container | `pulse_test_pg`     |
| Redmine container  | `pulse_test_redmine`|
| Postgres volume    | `pulse_test_pgdata` |
