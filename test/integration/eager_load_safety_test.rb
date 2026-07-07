# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))

# PRODUCTION EAGER-LOAD SAFETY.
#
# THE DEFECT
# ----------
# Redmine 6.x adds each plugin's lib/ to Zeitwerk (Rails.autoloaders.main) and
# EAGER-LOADS it when RAILS_ENV=production. Zeitwerk derives the constant a file
# is EXPECTED to define from the file's path:
#
#     lib/redmine_pulse/hooks.rb  =>  RedminePulse::Hooks
#
# The original implementation instead defines a TOP-LEVEL constant `RedminePulseHooks`
# in that file. Under eager-load this path/constant mismatch makes
# `Rails.application.eager_load!` raise:
#
#     NameError: uninitialized constant RedminePulse::Hooks
#     (Zeitwerk: expected file .../lib/redmine_pulse/hooks.rb to define RedminePulse::Hooks)
#
# WHY THE EXISTING TEST SUITE MISSED IT
# -------------------------------------
# RAILS_ENV=test has eager_load OFF, and init.rb does an EXPLICIT
# `require 'redmine_pulse/hooks'` which defines `RedminePulseHooks` the classic
# (non-Zeitwerk) way. So every existing test boots fine and the crash only ever
# appears under the production condition (eager_load!). Reproduced in the harness
# container with `RAILS_ENV=production bin/rails runner "Rails.application.eager_load!"`.
#
# THE GUARD
# ---------
# This test FORCES the exact production condition inside the test suite by calling
# `Rails.application.eager_load!` explicitly (the test-env boot itself does not).
# It fails now (NameError as above) and passes once the file/constant Zeitwerk
# mismatch is resolved. The whole app's lib/pulse/** tree already path-matches its
# constants (e.g. lib/pulse/domain/scoring_config.rb => Pulse::Domain::ScoringConfig),
# so the FIRST and ONLY constant eager_load! trips on is RedminePulse::Hooks — making
# this assertion specific to the hook path/constant mismatch and not a sink for
# unrelated zeitwerk noise.
class EagerLoadSafetyTest < ActiveSupport::TestCase
  # The faithful, minimal production-condition assertion: eager-loading the whole
  # application (what RAILS_ENV=production does at boot) must raise nothing.
  # Fails until the lib/redmine_pulse/hooks.rb path/constant mismatch is fixed.
  def test_application_eager_loads_without_raising
    assert_nothing_raised do
      Rails.application.eager_load!
    end
  end

  # Positive half: the hook constant the plugin actually relies on must resolve.
  # This holds NOW (init.rb's explicit require defines it) and MUST keep holding
  # after the fix — it guards against a fix that renames the constant out from
  # under the hook registration instead of fixing the file/constant alignment.
  def test_hook_constant_resolves
    assert defined?(RedminePulseHooks),
           'RedminePulseHooks must be defined after the plugin loads (used by the view-hook registration)'
    assert RedminePulseHooks < Redmine::Hook::ViewListener,
           'RedminePulseHooks must be a Redmine view-hook listener'
  end
end
