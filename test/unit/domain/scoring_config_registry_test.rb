# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'pulse/domain/scoring_config'
require 'pulse/domain/signal_registry'

# FR-C1-02 / FR-C1-03 — FC-C1-04, FC-C1-05, FC-C1-06, FC-C1-07, FC-C1-08.
# ScoringConfig generalized to an ENABLED signal set: the enabled set is the DOMAIN
# of `weights`. Validation generalizes from "exactly the 5 REQUIRED keys" to:
#   - weights keys are a subset of registered signals, non-empty;
#   - dom(w) == enabled set (exact cover of the declared enabled_signals);
#   - each weight is a finite real Numeric >= 0 (type+finiteness BEFORE the sum);
#   - Σ weights == 1.0 within 1e-9;
#   - Σ_{enabled ∩ always-active} w > 0 (generalized RC-07).
# Default construction (no args) == the 5 built-ins with today's weights.
#
# RED NOW: Pulse::Domain::SignalRegistry is absent AND ScoringConfig does not accept
# an enabled_signals: kwarg / does not validate against the registry -> these raise
# NameError/ArgumentError (unknown keyword) before the real assertion. GREEN after A9.
class ScoringConfigRegistryTest < Minitest::Test
  CFG = Pulse::Domain::ScoringConfig
  R = Pulse::Domain::SignalRegistry

  def default_weights
    R.default_weights.dup
  end

  def build(weights:, enabled: nil)
    if enabled.nil?
      CFG.new(weights: weights)
    else
      CFG.new(enabled_signals: enabled, weights: weights)
    end
  end

  # === Default construction == the 5 built-ins with today's weights ===========
  def test_default_construction_uses_registry_default_weights
    cfg = CFG.new
    assert_equal R.default_weights, cfg.weights, 'no-arg default == registry default_weights'
    assert_equal R.default_enabled_keys.sort, cfg.enabled_signals.sort,
                 'no-arg enabled_signals == the 5 built-ins'
  end

  def test_enabled_signals_equals_weights_domain
    cfg = CFG.new
    assert_equal cfg.weights.keys.sort, cfg.enabled_signals.sort,
                 'the enabled set is the domain of weights'
  end

  # === FC-C1-04: dom(w) == enabled set (exact cover) ==========================
  def test_registry_backed_default_via_enabled_kwarg
    cfg = CFG.new(enabled_signals: R.keys, weights: R.default_weights)
    assert_equal R.default_weights, cfg.weights
  end

  def test_weights_missing_an_enabled_key_raises
    # declare 5 enabled, provide only 4 weights -> under-cover.
    w = default_weights
    w.delete(:blocked_load)
    assert_raises(ArgumentError) { CFG.new(enabled_signals: R.keys, weights: w) }
  end

  def test_weights_extra_key_not_in_enabled_raises
    # enable only 3, but provide a 4th weight not in the enabled set -> over-cover.
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.4, momentum: 0.3, blocked_load: 0.3, progress: 0.0 }
    assert_raises(ArgumentError) { CFG.new(enabled_signals: enabled, weights: w) }
  end

  def test_weight_key_not_a_registered_signal_raises
    # a weight key that is not any registered signal at all.
    w = default_weights
    w[:not_a_signal] = 0.0
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  def test_empty_weights_raises
    assert_raises(ArgumentError) { CFG.new(enabled_signals: [], weights: {}) }
  end

  # === FC-C1-05: type + finiteness BEFORE the sum (fail loud, not TypeError) ==
  def test_nan_weight_raises_argument_error
    w = default_weights
    w[:staleness] = Float::NAN
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err, 'NaN weight must fail loud as ArgumentError (not slip past tolerance)'
  end

  def test_infinite_weight_raises_argument_error
    w = default_weights
    w[:staleness] = Float::INFINITY
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err
  end

  def test_complex_weight_raises_argument_error
    w = default_weights
    w[:staleness] = Complex(1, 1)
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err,
                       'Complex weight must fail loud as ArgumentError (not NoMethodError/TypeError at `< 0`)'
  end

  def test_string_weight_raises_argument_error
    w = default_weights
    w[:staleness] = '0.25'
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err
  end

  def test_nil_weight_raises_argument_error
    w = default_weights
    w[:staleness] = nil
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err
  end

  # === FC-C1-06: non-negative =================================================
  def test_negative_weight_raises
    # keep sum at 1.0 to isolate the non-negativity check.
    w = { staleness: 0.45, progress: 0.30, momentum: 0.20, risk_load: 0.15, blocked_load: -0.10 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  # === FC-C1-07: Σ w == 1.0 within 1e-9 =======================================
  def test_weights_over_enabled_sum_to_one
    # a map summing to 0.9 over the default 5 -> reject.
    w = { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.05 }
    assert_raises(ArgumentError) { CFG.new(weights: w) }

    # exact 1.0 constructs.
    ok = CFG.new(weights: default_weights)
    assert_equal 1.0, ok.weights.values.sum

    # within tolerance (1.0 - 5e-10) constructs.
    tuned = { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15 - 5e-10 }
    refute_nil CFG.new(weights: tuned)
  end

  def test_enabled_subset_of_three_sums_to_one
    # a NON-default enabled set (3 signals) that validly covers + sums to 1.0.
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    cfg = CFG.new(enabled_signals: enabled, weights: w)
    assert_equal enabled.sort, cfg.enabled_signals.sort
    assert_equal w, cfg.weights
  end

  # === FC-C1-08: enabled ∩ always-active subset weight-sum > 0 (generalized RC-07)
  def test_enabled_always_active_subset_positive
    # over the default 5: all weight on the NON-always-active signals
    # {progress, risk_load}; the always-active subset {staleness,momentum,blocked_load}
    # sums to 0.0 -> reject (else an empty active set is admissible; RC-07 recurs).
    w = { staleness: 0.0, progress: 0.6, momentum: 0.0, risk_load: 0.4, blocked_load: 0.0 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  def test_enabled_set_with_no_always_active_signal_but_one_positive
    # An enabled set retaining >= 1 always-active signal with positive weight constructs.
    enabled = %i[staleness progress]
    w = { staleness: 0.4, progress: 0.6 } # staleness is always-active -> subset sum 0.4 > 0
    cfg = CFG.new(enabled_signals: enabled, weights: w)
    assert_operator w[:staleness], :>, 0.0
    refute_nil cfg
  end

  def test_enabled_set_without_any_always_active_signal_raises
    # enable ONLY non-always-active signals -> the enabled ∩ always-active subset is
    # empty -> its weight-sum is 0 -> reject (generalized RC-07).
    enabled = %i[progress risk_load]
    w = { progress: 0.5, risk_load: 0.5 }
    assert_raises(ArgumentError) { CFG.new(enabled_signals: enabled, weights: w) }
  end

  # --- N-generality: config does not hardcode the number 5 --------------------
  def test_enabled_count_derived_from_config_not_literal_five
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    cfg = CFG.new(enabled_signals: enabled, weights: w)
    assert_equal 3, cfg.enabled_signals.size,
                 'enabled_signals.size reflects the config, not a hardcoded 5'
  end
end
