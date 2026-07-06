# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'pulse/domain/scoring_config'
require 'pulse/domain/signal_registry'

# FR-C3-01, FR-C3-07 / FC-C3-11, FC-C3-12, FC-C3-13.
# Behavior-preservation guard for the ScoringConfig-adopts-WeightSet refactor (OBL-C3-01).
# ScoringConfig constructs a WeightSet INTERNALLY for base validation, then sets
# @weights = weight_set.to_h (a plain frozen Hash) and layers its own sum==1.0 +
# enabled∩always-active constraints on top. The PUBLIC attr_reader :weights MUST continue
# to return a plain frozen Hash — byte-identical to the input — after the refactor.
#
# STATUS: this test is GREEN NOW (against the C1 as-built plain-Hash weights) and MUST
# stay GREEN after A9's refactor — it is the behavior-preservation gate. It does NOT
# duplicate the existing scoring_config_registry_test.rb:39 assertion (that file is
# UNCHANGED); it pins the additional #weights-is-a-plain-frozen-Hash + fail-loud invariants
# that the WeightSet adoption must not weaken. The byte-identical golden gates
# (backward_compat_golden_test, coverage_gap_default_off_golden_test) remain the ultimate
# guard and run UNCHANGED.
class ScoringConfigWeightsetAdoptionTest < Minitest::Test
  CFG = Pulse::Domain::ScoringConfig
  R = Pulse::Domain::SignalRegistry

  # === FC-C3-11: #weights is a PLAIN Hash (not a WeightSet) =====================
  def test_weights_is_a_plain_hash
    assert_instance_of Hash, CFG.new.weights,
                       'ScoringConfig#weights must return a plain Hash, not a WeightSet (FC-C3-11)'
  end

  def test_weights_equals_registry_default_weights_hash
    # Mirrors the intent of scoring_config_registry_test.rb:39 without editing that file:
    # Hash == Hash holds byte-identically after the WeightSet adoption.
    assert_equal R.default_weights, CFG.new.weights
  end

  # === FC-C3-11: byte-identical Float values at each key (store-as-is) ==========
  def test_default_weight_values_byte_identical
    w = CFG.new.weights
    { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15 }.each do |k, v|
      assert_in_delta v, w[k], 0.0, "weights[#{k}] must be byte-identical (#{v})"
    end
  end

  def test_weight_hash_preserves_insertion_order
    assert_equal R.default_weights.keys, CFG.new.weights.keys,
                 'insertion order preserved (no reordering by WeightSet adoption)'
  end

  # === FC-C3-11: #weights is a FROZEN Hash; [] access + values.sum unchanged =====
  def test_weights_is_frozen
    assert CFG.new.weights.frozen?, '#weights must be a frozen Hash'
  end

  def test_weights_indexed_read_unchanged
    assert_in_delta 0.25, CFG.new.weights[:staleness], 0.0
  end

  def test_weights_values_sum_to_one
    assert_in_delta 1.0, CFG.new.weights.values.sum, 1e-9
  end

  def test_mutating_weights_raises_frozen_error
    assert_raises(FrozenError) { CFG.new.weights[:staleness] = 0.9 }
  end

  # === FC-C3-11: fail-loud ArgumentErrors PRESERVED after the refactor ==========
  def test_unregistered_key_still_raises
    w = R.default_weights.dup
    w[:not_a_signal] = 0.0
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  def test_nan_weight_still_raises_argument_error
    w = R.default_weights.dup
    w[:staleness] = Float::NAN
    err = assert_raises(StandardError) { CFG.new(weights: w) }
    assert_instance_of ArgumentError, err
  end

  def test_negative_weight_still_raises
    w = { staleness: 0.45, progress: 0.30, momentum: 0.20, risk_load: 0.15, blocked_load: -0.10 }
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  def test_sum_not_one_still_raises
    # ScoringConfig's OWN layered constraint (NOT WeightSet's): Σ != 1.0 => ArgumentError.
    w = { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.05 }
    assert_raises(ArgumentError) { CFG.new(weights: w) }
  end

  def test_empty_weights_still_raises
    assert_raises(ArgumentError) { CFG.new(enabled_signals: [], weights: {}) }
  end
end
