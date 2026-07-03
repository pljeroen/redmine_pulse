# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'pulse/domain/signal_result'

# FR-03 / FC-08, FC-31, FC-32.
# SignalResult VO: nil-consistency invariant (active<=>all-numerics-non-nil),
# immutability, fail-loud construction on mixed state.
class SignalResultTest < Minitest::Test
  def active_result
    Pulse::Domain::SignalResult.new(
      key: :staleness, active: true, raw_value: 150, n: 0.16667,
      effective_weight: 0.25, contribution: 4.1667
    )
  end

  def inactive_result
    Pulse::Domain::SignalResult.new(
      key: :risk_load, active: false, raw_value: nil, n: nil,
      effective_weight: nil, contribution: nil
    )
  end

  def test_active_result_all_numerics_non_nil
    s = active_result
    assert s.active
    refute_nil s.raw_value
    refute_nil s.n
    refute_nil s.effective_weight
    refute_nil s.contribution
    assert s.frozen?, 'SignalResult must be frozen (FC-31)'
  end

  def test_inactive_result_all_numerics_nil
    s = inactive_result
    refute s.active
    assert_nil s.raw_value
    assert_nil s.n
    assert_nil s.effective_weight
    assert_nil s.contribution
  end

  def test_key_in_canonical_enum
    %i[staleness progress momentum risk_load blocked_load].each do |k|
      s = Pulse::Domain::SignalResult.new(key: k, active: false, raw_value: nil, n: nil,
                                          effective_weight: nil, contribution: nil)
      assert_equal k, s.key
    end
  end

  # --- FC-32: fail-loud construction on mixed/partial nil state ---
  def test_active_with_any_nil_numeric_rejected
    assert_raises(ArgumentError) do
      Pulse::Domain::SignalResult.new(key: :staleness, active: true, raw_value: 1,
                                      n: nil, effective_weight: 0.25, contribution: 4.0)
    end
  end

  def test_inactive_with_any_non_nil_numeric_rejected
    assert_raises(ArgumentError) do
      Pulse::Domain::SignalResult.new(key: :risk_load, active: false, raw_value: nil,
                                      n: 0.5, effective_weight: nil, contribution: nil)
    end
  end

  def test_mutation_raises_frozen_error
    s = active_result
    assert_raises(FrozenError) { s.instance_variable_set(:@active, false) } if s.frozen?
  end
end
