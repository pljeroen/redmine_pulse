#!/usr/bin/env bash
# run.sh — host-neutral test runner for redmine_pulse.
#
# Copyright (C) 2026  redmine_pulse contributors
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License, version 2, as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
# ─────────────────────────────────────────────────────────────────────────────
#
# Portable runner with NO host coupling: it assumes the current working
# directory is a prepared Redmine checkout with this plugin linked in at
# plugins/redmine_pulse, OR it is told where that root lives via REDMINE_ROOT or
# the first positional argument. It contains no container runtime, no harness
# container names, no hardcoded image paths, and no CI-template expressions — so
# the same script runs identically under GitHub Actions, a local container-based
# harness, or a bare workstation checkout.
#
# It runs two lanes:
#   1. The Redmine-integrated plugin lane (rake redmine:plugins:test), which
#      needs a live database + migrated schema. We drive the Rails-loaded
#      functional + integration subtasks here. The pure-domain unit tests are
#      DELIBERATELY excluded from this lane: they assert that Rails is NOT
#      loaded, so running them under Rails' loader would fail by design. They
#      belong to lane 2 only — "the standalone suite stays standalone; the
#      Redmine task is for functional tests" (see scripts/test-redmine/README).
#   2. The standalone pure-domain lane (ruby -Itest -Ilib on test/unit/domain),
#      which needs neither a database nor Rails — fast, framework-free signal.
#
# Local-dev parity: the committed harness under scripts/test-redmine/ wraps this
# same contract for an isolated local Redmine container.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Resolve the Redmine root: explicit REDMINE_ROOT wins, then $1, then cwd.
REDMINE_ROOT="${REDMINE_ROOT:-${1:-$PWD}}"
PLUGIN_NAME="redmine_pulse"
PLUGIN_DIR="${REDMINE_ROOT}/plugins/${PLUGIN_NAME}"

export RAILS_ENV=test

if [ ! -d "${PLUGIN_DIR}" ]; then
  echo "ERROR: plugin not found at ${PLUGIN_DIR}" >&2
  echo "       point REDMINE_ROOT (or \$1) at a Redmine checkout with the plugin linked in." >&2
  exit 1
fi

echo "==> [ci] Redmine root: ${REDMINE_ROOT}"
cd "${REDMINE_ROOT}"

echo "==> [ci] Lane 1: Redmine-integrated plugin tests"

echo "--- Creating + migrating the core database (RAILS_ENV=test) ---"
bundle exec rake db:create
bundle exec rake db:migrate

echo "--- Running plugin migrations ---"
bundle exec rake redmine:plugins:migrate NAME="${PLUGIN_NAME}"

echo "--- Running rake redmine:plugins:test (functional + integration) NAME=${PLUGIN_NAME} ---"
# Run the Rails-coupled suites only. The domain unit tests run standalone in
# lane 2 (they assert Rails is absent and must not be loaded under rake).
bundle exec rake redmine:plugins:test:functionals NAME="${PLUGIN_NAME}"
bundle exec rake redmine:plugins:test:integration NAME="${PLUGIN_NAME}"

echo "==> [ci] Lane 2: standalone unit suite (no DB, no Rails)"
cd "${PLUGIN_DIR}"
# Run from the PLUGIN dir so the top-level guards' relative paths (.github/,
# scripts/, config/locales/, app/views/) resolve correctly.
#
# A RECURSIVE test/unit/**/*_test.rb glob runs the WHOLE standalone unit suite,
# not just test/unit/domain/*: the bare-Ruby top-level guards
# (static_source_guards, i18n_coverage, ci_workflow_safety) are discovered by
# the Redmine functional+integration lane NOWHERE — this standalone lane is
# their only home in CI. The narrow domain-only glob silently dropped them
# (CI-A10-001); the recursive sweep restores coverage parity with the local
# `rake redmine:plugins:test` harness.
#
# MT_NO_PLUGINS=1 stops Minitest from auto-loading third-party plugins. When this
# lane runs from inside a Redmine tree (e.g. plugins/redmine_pulse under CI),
# Rails' Minitest plugin would otherwise auto-activate and pull Rails into the
# process — which the domain-purity tests correctly refuse. Disabling plugin
# autoload keeps this lane a genuine bare-Ruby run, matching local execution.
MT_NO_PLUGINS=1 ruby -Itest -Ilib -e 'Dir["test/unit/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'

echo "==> [ci] Both lanes complete."
