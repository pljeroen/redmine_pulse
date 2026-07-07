# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/signal_registry'
require 'pulse/domain/scoring_config'

# coverage_gap registration, the default_on field totality, and default_weights +
# default_on_keys scoped to default_on:true (a no-arg ScoringConfig enables exactly 5).
#
# TARGET API:
#   - SIGNALS gains coverage_gap AFTER blocked_load: key :coverage_gap, always_active false,
#     default_weight 0.15, at_risk false, canonical_order 5, default_on false.
#   - Signal gains a default_on Boolean present on EVERY record (5 built-ins true).
#   - SignalRegistry.default_on_keys returns ONLY default_on:true keys in canonical order.
#   - SignalRegistry.default_weights returns ONLY default_on:true weights (Σ == 1.0, NOT 1.15).
class SignalRegistryCoverageGapTest < Minitest::Test
  R = Pulse::Domain::SignalRegistry

  DEFAULT_ON = %i[staleness progress momentum risk_load blocked_load].freeze
  DEFAULT_WEIGHTS = {
    staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15
  }.freeze

  # --- coverage_gap registered AFTER blocked_load, canonical_order 5 ---------
  def test_coverage_gap_registered_with_pinned_metadata
    assert R.registered?(:coverage_gap), 'coverage_gap must be a registered signal'
    s = R.fetch(:coverage_gap)
    assert_equal :coverage_gap, s.key
    assert_equal false, s.always_active?, 'coverage_gap is NOT always-active'
    assert_equal 0.15, s.default_weight, 'coverage_gap default_weight == 0.15'
    assert_equal false, s.at_risk?, 'coverage_gap at_risk? == false'
    assert_equal 5, s.canonical_order, 'coverage_gap canonical_order == 5 (sixth entry)'
  end

  def test_keys_place_coverage_gap_last
    assert_equal %i[staleness progress momentum risk_load blocked_load coverage_gap],
                 R.keys, 'keys == 6-key sequence with coverage_gap last'
    assert_equal :coverage_gap, R.canonical_order_keys.last,
                 'coverage_gap is last in canonical order'
  end

  # --- coverage_gap does NOT leak into the at_risk / always-active subsets ----
  def test_coverage_gap_absent_from_at_risk_and_always_active_subsets
    assert_equal %i[blocked_load risk_load staleness], R.at_risk_keys.sort,
                 'at_risk_keys unchanged — coverage_gap absent'
    refute_includes R.always_active_keys, :coverage_gap,
                    'coverage_gap is not always-active'
  end

  # --- default_on field present + typed on EVERY record ----------------------
  def test_every_record_carries_a_boolean_default_on
    R.keys.each do |key|
      s = R.fetch(key)
      dv = s.respond_to?(:default_on?) ? s.default_on? : s.default_on
      assert_includes [true, false], dv, "#{key}: default_on is Boolean (never nil/missing)"
    end
  end

  def test_default_on_values_pinned_per_signal
    DEFAULT_ON.each do |key|
      s = R.fetch(key)
      dv = s.respond_to?(:default_on?) ? s.default_on? : s.default_on
      assert_equal true, dv, "#{key}: default_on == true"
    end
    cg = R.fetch(:coverage_gap)
    cgv = cg.respond_to?(:default_on?) ? cg.default_on? : cg.default_on
    assert_equal false, cgv, 'coverage_gap: default_on == false'
  end

  # --- default_weights + default_on_keys scope to default_on:true ------------
  def test_default_weights_scope_to_default_on_and_sum_to_one
    assert_equal DEFAULT_WEIGHTS, R.default_weights,
                 'default_weights == the 5 default_on weights (coverage_gap EXCLUDED)'
    refute_includes R.default_weights.keys, :coverage_gap,
                    'coverage_gap MUST NOT appear in default_weights'
    assert_equal 1.0, R.default_weights.values.sum,
                 'Σ default_weights == 1.0 EXACTLY (NOT 1.15) — the sum-preservation guard'
  end

  def test_default_on_keys_are_the_five_builtins_in_canonical_order
    assert_equal DEFAULT_ON, R.default_on_keys,
                 'default_on_keys == the 5 built-ins in canonical order (coverage_gap absent)'
  end

  # --- no-arg ScoringConfig enables exactly 5 (NOT 6, NOT Σ 1.15) --
  def test_no_arg_scoring_config_enables_exactly_the_five_builtins
    cfg = Pulse::Domain::ScoringConfig.new # weights: nil => default_weights
    assert_equal DEFAULT_ON.sort, cfg.enabled_signals.sort,
                 'default ScoringConfig enables exactly the 5 default_on signals'
    refute_includes cfg.enabled_signals, :coverage_gap,
                    'default construction does NOT enable coverage_gap'
    assert_equal 5, cfg.enabled_signals.size, 'default enabled set is 5, not 6'
  end

  def test_no_arg_scoring_config_does_not_raise_on_sum_regression
    # The 1.15-sum regression would make no-arg construction raise; it MUST NOT.
    refute_nil Pulse::Domain::ScoringConfig.new,
               'no-arg ScoringConfig must construct without raising (Σ == 1.0 preserved)'
  end
end
