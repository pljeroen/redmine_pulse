# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'pulse/domain/weight_set'

# FR-C3-01, FR-C3-05 / FC-C3-01, FC-C3-02, FC-C3-03, FC-C3-04.
# WeightSet frozen VO: a map of registered-signal-key => weight over a SUBSET of the
# registered signals. Validates: keys registered (else ArgumentError, AC-C3-01);
# each weight a finite real Numeric >= 0, type-checked BEFORE compare (NaN/Inf/Complex/
# String/nil => ArgumentError, AC-C3-02); at least one weight > 0 (else ArgumentError);
# NO sum==1.0 requirement. Frozen (FrozenError on mutation, AC-C3-05). #to_h plain frozen
# Hash; Hash-aware #== (for C4 reuse).
#
# RED NOW: Pulse::Domain::WeightSet is unimplemented -> require raises LoadError. GREEN
# after A9 creates lib/pulse/domain/weight_set.rb to the exact public API these tests pin.
class WeightSetTest < Minitest::Test
  WS = Pulse::Domain::WeightSet
  R = Pulse::Domain::SignalRegistry

  # === FC-C3-01: valid construction over a SUBSET of registered signals =========
  def test_valid_subset_accepted
    ws = WS.new(staleness: 0.6, progress: 0.4)
    assert_instance_of WS, ws
    assert_equal({ staleness: 0.6, progress: 0.4 }, ws.to_h)
  end

  def test_single_registered_key_accepted
    ws = WS.new(momentum: 1.0)
    assert_equal({ momentum: 1.0 }, ws.to_h)
  end

  def test_all_six_registered_keys_accepted
    h = R.keys.each_with_object({}) { |k, acc| acc[k] = 1.0 }
    ws = WS.new(h)
    assert_equal R.keys.sort, ws.to_h.keys.sort
  end

  def test_integer_and_rational_weights_accepted
    ws = WS.new(staleness: 1, progress: Rational(1, 2))
    assert_equal 1, ws.to_h[:staleness]
    assert_equal Rational(1, 2), ws.to_h[:progress]
  end

  def test_zero_weight_allowed_when_another_is_positive
    # a single zero weight is fine as long as >= 1 weight is > 0.
    ws = WS.new(staleness: 0.0, progress: 1.0)
    assert_equal({ staleness: 0.0, progress: 1.0 }, ws.to_h)
  end

  # === FC-C3-01: unregistered key => ArgumentError (AC-C3-01) ===================
  def test_unregistered_key_raises
    assert_raises(ArgumentError) { WS.new(not_a_signal: 1.0) }
  end

  def test_unregistered_key_among_valid_ones_raises
    assert_raises(ArgumentError) { WS.new(staleness: 0.5, bogus: 0.5) }
  end

  # === FC-C3-01: empty Hash => ArgumentError ===================================
  def test_empty_weights_raises
    assert_raises(ArgumentError) { WS.new({}) }
  end

  # === FC-C3-01: non-finite / non-real weights => ArgumentError (AC-C3-02) ======
  # Type/finiteness checked BEFORE compare so Complex/String never leak Type/NoMethodError.
  def test_non_numeric_string_weight_raises
    err = assert_raises(StandardError) { WS.new(staleness: '0.5', progress: 0.5) }
    assert_instance_of ArgumentError, err,
                       'String weight must fail loud as ArgumentError (not TypeError at `< 0`)'
  end

  def test_nan_weight_raises
    err = assert_raises(StandardError) { WS.new(staleness: Float::NAN, progress: 0.5) }
    assert_instance_of ArgumentError, err
  end

  def test_infinite_weight_raises
    err = assert_raises(StandardError) { WS.new(staleness: Float::INFINITY, progress: 0.5) }
    assert_instance_of ArgumentError, err
  end

  def test_complex_weight_raises
    err = assert_raises(StandardError) { WS.new(staleness: Complex(1, 1), progress: 0.5) }
    assert_instance_of ArgumentError, err,
                       'Complex weight must fail loud as ArgumentError (not NoMethodError at `< 0`)'
  end

  def test_nil_weight_raises
    err = assert_raises(StandardError) { WS.new(staleness: nil, progress: 0.5) }
    assert_instance_of ArgumentError, err
  end

  # === FC-C3-01: negative weight => ArgumentError (AC-C3-02) ====================
  def test_negative_weight_raises
    assert_raises(ArgumentError) { WS.new(staleness: -0.1, progress: 0.9) }
  end

  # === FC-C3-01: all-zero weights => ArgumentError (>= 1 must be > 0) ============
  def test_all_zero_weights_raises
    assert_raises(ArgumentError) { WS.new(staleness: 0, progress: 0) }
  end

  def test_all_zero_float_weights_raises
    assert_raises(ArgumentError) { WS.new(staleness: 0.0, progress: 0.0, momentum: 0.0) }
  end

  # === FC-C3-01: NO sum==1.0 requirement ========================================
  def test_no_sum_to_one_requirement
    # A lens weight map is NOT a probability simplex; a sum != 1.0 constructs fine.
    ws = WS.new(risk_load: 0.5, blocked_load: 0.3, staleness: 0.2)  # sum 1.0 — fine
    refute_nil ws
    ws2 = WS.new(momentum: 3.0, progress: 7.0)                       # sum 10.0 — also fine
    assert_equal({ momentum: 3.0, progress: 7.0 }, ws2.to_h)
    ws3 = WS.new(staleness: 0.1, progress: 0.1)                      # sum 0.2 — also fine
    assert_equal({ staleness: 0.1, progress: 0.1 }, ws3.to_h)
  end

  # === FC-C3-02: frozen VO; #to_h plain frozen Hash (AC-C3-05) ==================
  def test_weight_set_is_frozen
    assert WS.new(staleness: 1.0).frozen?, 'WeightSet must be frozen (FC-C3-02)'
  end

  def test_mutation_raises_frozen_error
    ws = WS.new(staleness: 1.0)
    assert_raises(FrozenError) { ws.instance_variable_set(:@weights, {}) }
  end

  def test_to_h_is_a_frozen_hash
    ws = WS.new(staleness: 0.25, progress: 0.75)
    h = ws.to_h
    assert_instance_of Hash, h
    assert h.frozen?, '#to_h must return a frozen Hash (FC-C3-02/FC-C3-03)'
  end

  def test_mutating_to_h_raises_frozen_error
    ws = WS.new(staleness: 0.25, progress: 0.75)
    assert_raises(FrozenError) { ws.to_h[:staleness] = 0.9 }
  end

  # === FC-C3-03: Hash-compatible read surface + insertion order + no drift =======
  def test_to_h_preserves_input_insertion_order
    ws = WS.new(staleness: 0.25, progress: 0.75)
    assert_equal %i[staleness progress], ws.to_h.keys
    ws2 = WS.new(progress: 0.75, staleness: 0.25)
    assert_equal %i[progress staleness], ws2.to_h.keys
  end

  def test_to_h_values_byte_identical_to_input
    ws = WS.new(staleness: 0.25, progress: 0.75)
    assert_equal 0.25, ws.to_h[:staleness]
    assert_equal 0.75, ws.to_h[:progress]
  end

  # === FC-C3-04: Hash-aware, value-based #== (for C4 reuse) ======================
  def test_equality_against_plain_hash
    assert_equal({ staleness: 0.25, progress: 0.75 }, WS.new(staleness: 0.25, progress: 0.75).to_h)
    assert WS.new(staleness: 0.25, progress: 0.75) == { staleness: 0.25, progress: 0.75 }
  end

  def test_inequality_against_different_hash
    refute WS.new(staleness: 0.25, progress: 0.75) == { staleness: 0.25 }
  end

  def test_equality_is_order_independent
    a = WS.new(staleness: 0.25, progress: 0.75)
    b = WS.new(progress: 0.75, staleness: 0.25)
    assert a == b, 'WeightSet#== must be order-independent (Hash equality)'
  end

  def test_equality_against_another_weightset_same_contents
    assert WS.new(momentum: 0.6, progress: 0.4) == WS.new(momentum: 0.6, progress: 0.4)
  end

  # === FC-C3-03: formal read surface #[] / #keys / #values (A10-C3-001) ==========
  def test_index_returns_weight_for_present_key
    ws = WS.new(staleness: 0.25, progress: 0.75)
    assert_equal 0.25, ws[:staleness]
    assert_equal 0.75, ws[:progress]
  end

  def test_index_returns_nil_for_absent_key
    ws = WS.new(staleness: 0.25, progress: 0.75)
    assert_nil ws[:momentum]
    assert_nil ws[:not_a_signal]
  end

  def test_keys_preserve_insertion_order
    assert_equal %i[staleness progress], WS.new(staleness: 0.25, progress: 0.75).keys
    assert_equal %i[progress staleness], WS.new(progress: 0.75, staleness: 0.25).keys
  end

  def test_values_preserve_insertion_order
    assert_equal [0.25, 0.75], WS.new(staleness: 0.25, progress: 0.75).values
    assert_equal [0.75, 0.25], WS.new(progress: 0.75, staleness: 0.25).values
  end

  def test_keys_and_values_are_aligned
    ws = WS.new(risk_load: 0.5, blocked_load: 0.3, staleness: 0.2)
    assert_equal({ risk_load: 0.5, blocked_load: 0.3, staleness: 0.2 },
                 ws.keys.zip(ws.values).to_h)
  end

  def test_keys_collection_is_frozen
    ks = WS.new(staleness: 0.25, progress: 0.75).keys
    assert ks.frozen?, '#keys must return a frozen Array'
    assert_raises(FrozenError) { ks << :momentum }
  end

  def test_values_collection_is_frozen
    vs = WS.new(staleness: 0.25, progress: 0.75).values
    assert vs.frozen?, '#values must return a frozen Array'
    assert_raises(FrozenError) { vs << 0.5 }
  end

  def test_read_surface_does_not_mutate_internal_state
    ws = WS.new(staleness: 0.25, progress: 0.75)
    # exercise every read accessor, then prove the internal Hash is byte-unchanged.
    ws[:staleness]
    ws.keys
    ws.values
    assert_equal({ staleness: 0.25, progress: 0.75 }, ws.to_h)
    assert_equal %i[staleness progress], ws.to_h.keys
  end

  # === FC-C3-14 (structural): no DSL / expression surface — declarative Hash only ===
  def test_no_eval_or_expression_surface_in_source
    src = File.read(File.expand_path('../../../../lib/pulse/domain/weight_set.rb', __FILE__))
    %w[eval instance_eval class_eval module_eval binding].each do |tok|
      refute_match(/\b#{tok}\b/, src, "weight_set.rb must contain no #{tok} (no-DSL, FC-C3-14)")
    end
  end
end
