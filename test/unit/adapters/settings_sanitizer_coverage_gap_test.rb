# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# C1 lesson: a bare `require 'pulse/...'` fails under the harness without -Ilib. This is a
# pure-adapter unit test, so add lib/ to $LOAD_PATH before requiring the adapter.
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative '../../../lib/pulse/adapters/settings_sanitizer'

# FC-C2-14 / IMPL-OBL-C2-001 — the concrete 6-key enable/disable sanitizer contract.
# Discharges FR-C2-06. The enable_coverage_gap flag is AUTHORITATIVE:
#   (a) DEFAULT (no/'0'/blank enable): required weight-key set = the 5 default_on keys; a
#       5-key POST is accepted; NO coverage_gap key persisted.
#   (b) ENABLE ('1'): required set = {5 + coverage_gap}; a 6-key POST summing 1.0 accepted.
#   (c) DISABLE (previously enabled, incoming falsy): coverage_gap DROPPED + remaining 5
#       renormalized to Σ==1.0 — regardless of what previous/incoming weights still carry.
#   (d) STALE (falsy enable, coverage_gap weight present, previous already the valid 5-key
#       set): the 6-key incoming set is REJECTED; previous 5-key weights retained; the stale
#       coverage_gap weight is NOT persisted.
# INVARIANT: coverage_gap MUST NEVER appear in the sanitized weights while disabled.
#
# RED NOW: the sanitizer sources WEIGHT_KEYS statically from SignalRegistry.keys (which will
# include coverage_gap after C2) and does NOT read enable_coverage_gap — so the enable path,
# the drop-on-disable, and the never-persist-while-disabled invariant are all absent. GREEN
# after A9 threads enable_coverage_gap through sanitize per FC-C2-14.
class SettingsSanitizerCoverageGapTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  FIVE = {
    'staleness' => 0.25, 'progress' => 0.25, 'momentum' => 0.20,
    'risk_load' => 0.15, 'blocked_load' => 0.15
  }.freeze

  # A 6-key set summing to 1.0 (the 5 scaled by 1/1.15 + coverage_gap 0.15/1.15).
  SIX = begin
    raw = FIVE.merge('coverage_gap' => 0.15)
    total = raw.values.sum
    raw.transform_values { |w| w / total }.freeze
  end

  # A minimal valid `previous` disabled (5-key) settings hash.
  def previous_disabled
    { 'rag_green_min' => 67, 'rag_amber_min' => 34, 'h_stale' => 180, 'h_risk' => 50,
      'h_blocked' => 20, 'activity_window_days' => 30, 'weights' => FIVE.dup }
  end

  # A `previous` ENABLED (6-key) settings hash.
  def previous_enabled
    previous_disabled.merge('enable_coverage_gap' => '1', 'weights' => SIX.dup)
  end

  def weights_of(result)
    result.first['weights']
  end

  def string_keys(hash)
    hash.keys.map(&:to_s)
  end

  # === (a) DEFAULT — no enable flag, 5-key POST accepted, no coverage_gap ============
  def test_case_a_default_five_key_accepted_no_coverage_gap
    incoming = previous_disabled.merge('weights' => FIVE.dup) # no enable_coverage_gap
    result, errors = S.sanitize(incoming, previous_disabled)
    w = result['weights']
    refute_includes string_keys(w), 'coverage_gap',
                    'default path must NOT persist a coverage_gap weight (FC-C2-14 a)'
    refute_includes errors, 'weights',
                    'a valid 5-key POST must not be rejected for a missing coverage_gap weight'
    assert_in_delta 1.0, w.values.map(&:to_f).sum, 1e-9, 'the 5 weights sum to 1.0'
  end

  # === (b) ENABLE — '1' + 6-key weights summing 1.0 accepted with coverage_gap ======
  def test_case_b_enable_six_key_accepted_with_coverage_gap
    incoming = previous_disabled.merge('enable_coverage_gap' => '1', 'weights' => SIX.dup)
    result, errors = S.sanitize(incoming, previous_disabled)
    w = result['weights']
    assert_includes string_keys(w), 'coverage_gap',
                    'enable path accepts the coverage_gap weight (FC-C2-14 b)'
    refute_includes errors, 'weights', 'a valid 6-key POST must be accepted when enabled'
    assert_in_delta 1.0, w.values.map(&:to_f).sum, 1e-9, 'the 6 weights sum to 1.0'
  end

  # === (c) DISABLE — enable flag falsy is AUTHORITATIVE: drop + renormalize to 5 =====
  def test_case_c_disable_drops_coverage_gap_and_renormalizes
    # previous is ENABLED (6-key); incoming disables. coverage_gap must be dropped and the
    # remaining 5 renormalized to Σ==1.0 — even though incoming still carries coverage_gap.
    incoming = previous_enabled.merge('enable_coverage_gap' => '0', 'weights' => SIX.dup)
    result, = S.sanitize(incoming, previous_enabled)
    w = result['weights']
    refute_includes string_keys(w), 'coverage_gap',
                    'disable drops coverage_gap regardless of incoming/previous (FC-C2-14 c)'
    assert_equal 5, w.size, 'exactly the 5 default_on weights remain'
    assert_in_delta 1.0, w.values.map(&:to_f).sum, 1e-9, 'remaining 5 renormalized to Σ==1.0'
  end

  def test_case_c_disable_when_incoming_weights_are_already_five_key
    # Same authoritative outcome even if incoming weights are the 5-key set: no coverage_gap.
    incoming = previous_enabled.merge('enable_coverage_gap' => '0', 'weights' => FIVE.dup)
    result, = S.sanitize(incoming, previous_enabled)
    w = result['weights']
    refute_includes string_keys(w), 'coverage_gap',
                    'disable never persists coverage_gap (FC-C2-14 c)'
    assert_in_delta 1.0, w.values.map(&:to_f).sum, 1e-9
  end

  # === (d) STALE — falsy enable + stale coverage_gap weight, previous already 5-key ==
  def test_case_d_stale_coverage_gap_weight_rejected_previous_retained
    # No/'0' enable, but incoming weights carry a stray coverage_gap key; previous is the
    # valid disabled 5-key set. The 6-key incoming set is rejected (fails the 5-key exact
    # check); previous 5-key weights are retained; the stale coverage_gap is NOT persisted.
    stale = FIVE.merge('coverage_gap' => 0.15)
    incoming = previous_disabled.merge('weights' => stale) # no enable flag
    result, errors = S.sanitize(incoming, previous_disabled)
    w = result['weights']
    refute_includes string_keys(w), 'coverage_gap',
                    'a stale coverage_gap weight is never persisted while disabled (FC-C2-14 d)'
    assert_includes errors, 'weights',
                    'the 6-key incoming set is rejected against the 5-key required set'
    assert_equal FIVE, w, 'previous valid 5-key weights are retained on rejection'
  end
end
