# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'pulse/domain/signal_registry'
require 'pulse/domain/scoring_config'

# FC-C2-04 (registration), FC-C2-05 (default_on field totality), FC-C2-06 (default_weights
# + default_on_keys scoped to default_on:true; no-arg ScoringConfig enables exactly 5).
# Discharges FR-C2-01, FR-C2-05, AC-C2-05.
#
# TARGET API (A9 implements to match):
#   - SIGNALS gains coverage_gap AFTER blocked_load: key :coverage_gap, always_active false,
#     default_weight 0.15, at_risk false, canonical_order 5, default_on false.
#   - Signal gains a default_on Boolean present on EVERY record (5 built-ins true).
#   - SignalRegistry.default_on_keys returns ONLY default_on:true keys in canonical order.
#   - SignalRegistry.default_weights returns ONLY default_on:true weights (Σ == 1.0, NOT 1.15).
#
# RED NOW: coverage_gap is not registered and default_on/default_on_keys do not exist —
# fetch(:coverage_gap) raises KeyError, default_on_keys raises NoMethodError. GREEN after A9.
class SignalRegistryCoverageGapTest < Minitest::Test
  R = Pulse::Domain::SignalRegistry

  DEFAULT_ON = %i[staleness progress momentum risk_load blocked_load].freeze
  DEFAULT_WEIGHTS = {
    staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15
  }.freeze

  # --- FC-C2-04: coverage_gap registered AFTER blocked_load, canonical_order 5 ---------
  def test_coverage_gap_registered_with_pinned_metadata
    assert R.registered?(:coverage_gap), 'coverage_gap must be a registered signal (FC-C2-04)'
    s = R.fetch(:coverage_gap)
    assert_equal :coverage_gap, s.key
    assert_equal false, s.always_active?, 'coverage_gap is NOT always-active'
    assert_equal 0.15, s.default_weight, 'coverage_gap default_weight == 0.15 (AA-03)'
    assert_equal false, s.at_risk?, 'coverage_gap at_risk? == false (OI-01 resolved)'
    assert_equal 5, s.canonical_order, 'coverage_gap canonical_order == 5 (sixth entry)'
  end

  def test_keys_place_coverage_gap_last
    assert_equal %i[staleness progress momentum risk_load blocked_load coverage_gap],
                 R.keys, 'keys == 6-key sequence with coverage_gap last (FC-C2-04)'
    assert_equal :coverage_gap, R.canonical_order_keys.last,
                 'coverage_gap is last in canonical order'
  end

  # --- FC-C2-04: coverage_gap does NOT leak into the at_risk / always-active subsets ----
  def test_coverage_gap_absent_from_at_risk_and_always_active_subsets
    assert_equal %i[blocked_load risk_load staleness], R.at_risk_keys.sort,
                 'at_risk_keys unchanged — coverage_gap absent (FC-C2-04)'
    refute_includes R.always_active_keys, :coverage_gap,
                    'coverage_gap is not always-active'
  end

  # --- FC-C2-05: default_on field present + typed on EVERY record ----------------------
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

  # --- FC-C2-06: default_weights + default_on_keys scope to default_on:true ------------
  def test_default_weights_scope_to_default_on_and_sum_to_one
    assert_equal DEFAULT_WEIGHTS, R.default_weights,
                 'default_weights == the 5 default_on weights (coverage_gap EXCLUDED)'
    refute_includes R.default_weights.keys, :coverage_gap,
                    'coverage_gap MUST NOT appear in default_weights (FC-C2-06)'
    assert_equal 1.0, R.default_weights.values.sum,
                 'Σ default_weights == 1.0 EXACTLY (NOT 1.15) — the sum-preservation guard'
  end

  def test_default_on_keys_are_the_five_builtins_in_canonical_order
    assert_equal DEFAULT_ON, R.default_on_keys,
                 'default_on_keys == the 5 built-ins in canonical order (coverage_gap absent)'
  end

  # --- FC-C2-06 consequence: no-arg ScoringConfig enables exactly 5 (NOT 6, NOT Σ 1.15) --
  def test_no_arg_scoring_config_enables_exactly_the_five_builtins
    cfg = Pulse::Domain::ScoringConfig.new # weights: nil => default_weights
    assert_equal DEFAULT_ON.sort, cfg.enabled_signals.sort,
                 'default ScoringConfig enables exactly the 5 default_on signals (FC-C2-06)'
    refute_includes cfg.enabled_signals, :coverage_gap,
                    'default construction does NOT enable coverage_gap'
    assert_equal 5, cfg.enabled_signals.size, 'default enabled set is 5, not 6'
  end

  def test_no_arg_scoring_config_does_not_raise_on_sum_regression
    # The 1.15-sum regression (R2 / RC-C2-01) would make no-arg construction raise; it MUST NOT.
    refute_nil Pulse::Domain::ScoringConfig.new,
               'no-arg ScoringConfig must construct without raising (Σ == 1.0 preserved)'
  end
end
