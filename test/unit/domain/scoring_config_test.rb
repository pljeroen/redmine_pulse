# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/scoring_config'

# ScoringConfig: immutable VO; defaults; weight-sum==1.0(1e-9); weights>=0;
# always-active weight-sum guard (always-active subset {staleness,momentum,blocked_load} sum > 0).
class ScoringConfigTest < Minitest::Test
  # --- defaults ---
  def test_defaults_and_weight_sum_and_type_constraints
    cfg = Pulse::Domain::ScoringConfig.new
    assert cfg.frozen?, 'ScoringConfig must be frozen'
    assert_in_delta 0.25, cfg.weights[:staleness], 1e-12
    assert_in_delta 0.25, cfg.weights[:progress], 1e-12
    assert_in_delta 0.20, cfg.weights[:momentum], 1e-12
    assert_in_delta 0.15, cfg.weights[:risk_load], 1e-12
    assert_in_delta 0.15, cfg.weights[:blocked_load], 1e-12
    assert_in_delta 1.0, cfg.weights.values.sum, 1e-9

    assert_equal 67, cfg.rag_green_min
    assert_equal 34, cfg.rag_amber_min
    assert_equal 180, cfg.h_stale
    assert_equal 50, cfg.h_risk
    assert_equal 20, cfg.h_blocked
    assert_equal 30, cfg.activity_window_days
  end

  def test_weights_are_floats
    cfg = Pulse::Domain::ScoringConfig.new
    cfg.weights.each_value { |w| assert_kind_of Float, w }
  end

  def test_mutation_raises_frozen_error
    cfg = Pulse::Domain::ScoringConfig.new
    assert_raises(FrozenError) { cfg.weights[:staleness] = 0.9 }
  end

  # --- weight-sum must be 1.0 within 1e-9; weights >= 0 ---
  def test_accepts_weight_sum_one_within_tolerance
    w = { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15 }
    cfg = Pulse::Domain::ScoringConfig.new(weights: w)
    assert_in_delta 1.0, cfg.weights.values.sum, 1e-9
  end

  def test_rejects_weight_sum_not_one
    w = { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.05 } # sum 0.90
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_negative_weight
    # one clearly negative weight, sum kept at 1.0 to isolate the non-negativity check.
    w = { staleness: 0.45, progress: 0.30, momentum: 0.20, risk_load: 0.15, blocked_load: -0.10 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  # --- always-active subset weight-sum must be > 0 ---
  def test_rejects_zero_always_active_subset_weight_sum
    # staleness=momentum=blocked_load=0, sum kept 1.0 via progress+risk_load.
    w = { staleness: 0.0, progress: 0.6, momentum: 0.0, risk_load: 0.4, blocked_load: 0.0 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_accepts_minimal_positive_always_active_subset
    # A tuned-but-valid config where the always-active subset sum > 0.
    w = { staleness: 0.01, progress: 0.49, momentum: 0.005, risk_load: 0.49, blocked_load: 0.005 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    cfg = Pulse::Domain::ScoringConfig.new(weights: w)
    assert_operator(w[:staleness] + w[:momentum] + w[:blocked_load], :>, 0.0)
    refute_nil cfg
  end

  # === promoted momentum/on-track shape constants ============================
  # 3 momentum/on-track shape constants promoted to ScoringConfig kwargs:
  #   momentum_activity_half  default 8.0  range > 0 (strictly positive)
  #   momentum_direction_bias default 0.15 range [0.0, 0.5] inclusive
  #   on_track_threshold      default 0.5  range [0.0, 1.0] inclusive
  # These are FLOAT fields (Integer input is acceptable; NaN/Infinity/non-numeric
  # rejected). Defaults preserve today's behaviour exactly.

  # --- defaults (8.0 / 0.15 / 0.5) -------------------------------------------
  def test_momentum_onctrack_defaults
    cfg = Pulse::Domain::ScoringConfig.new
    assert_in_delta 8.0, cfg.momentum_activity_half, 1e-12,
                    'momentum_activity_half default is 8.0 (preserves the old MOMENTUM_ACTIVITY_HALF)'
    assert_in_delta 0.15, cfg.momentum_direction_bias, 1e-12,
                    'momentum_direction_bias default is 0.15 (preserves the old MOMENTUM_DIRECTION_BIAS)'
    assert_in_delta 0.5, cfg.on_track_threshold, 1e-12,
                    'on_track_threshold default is 0.5 (preserves the old ON_TRACK_THRESHOLD)'
  end

  # --- range rejections (ArgumentError, fail-loud at the VO boundary) --------
  # Each reject test FIRST asserts a VALID value constructs cleanly. That guard means the
  # test cannot pass on a spurious "unknown keyword" ArgumentError; it passes only once the
  # kwarg exists AND the range guard rejects the bad value.
  def assert_field_rejected(field, bad_value, good_value)
    # The good value must construct cleanly (no exception). Plain Minitest has no
    # assert_nothing_raised, so we assert the constructed object exists instead — any
    # raise (incl. a stray "unknown keyword" ArgumentError) propagates and fails.
    cfg = Pulse::Domain::ScoringConfig.new(field => good_value)
    refute_nil cfg, "#{field}=#{good_value.inspect} must be accepted (in-range)"
    assert_raises(ArgumentError, "#{field}=#{bad_value.inspect} must be rejected (out of range/invalid)") do
      Pulse::Domain::ScoringConfig.new(field => bad_value)
    end
  end

  def test_rejects_momentum_activity_half_zero
    # strictly positive: 0 (a denominator-shifting half) must be rejected.
    assert_field_rejected(:momentum_activity_half, 0.0, 8.0)
  end

  def test_rejects_momentum_activity_half_negative
    assert_field_rejected(:momentum_activity_half, -1.0, 8.0)
  end

  def test_rejects_momentum_direction_bias_below_zero
    assert_field_rejected(:momentum_direction_bias, -0.01, 0.15)
  end

  def test_rejects_momentum_direction_bias_above_half
    assert_field_rejected(:momentum_direction_bias, 0.51, 0.15)
  end

  def test_rejects_on_track_threshold_below_zero
    assert_field_rejected(:on_track_threshold, -0.01, 0.5)
  end

  def test_rejects_on_track_threshold_above_one
    assert_field_rejected(:on_track_threshold, 1.01, 0.5)
  end

  # --- type guards (non-numeric / NaN / Infinity rejected) -------------------
  def test_rejects_non_numeric_momentum_field
    assert_field_rejected(:momentum_activity_half, 'eight', 8.0)
  end

  def test_rejects_nan_momentum_field
    assert_field_rejected(:momentum_direction_bias, Float::NAN, 0.15)
  end

  def test_rejects_infinity_momentum_field
    assert_field_rejected(:momentum_activity_half, Float::INFINITY, 8.0)
  end

  def test_rejects_nan_on_track_threshold
    assert_field_rejected(:on_track_threshold, Float::NAN, 0.5)
  end

  # --- Integer input accepted for a float field ------------------------------
  def test_accepts_integer_for_float_field
    cfg = Pulse::Domain::ScoringConfig.new(momentum_activity_half: 8) # Integer, not 8.0
    assert_in_delta 8.0, cfg.momentum_activity_half, 1e-12,
                    'a user-entered Integer (8) is acceptable for the float momentum_activity_half'
  end

  # --- inclusive boundary values accepted ------------------------------------
  def test_accepts_direction_bias_boundaries
    lo = Pulse::Domain::ScoringConfig.new(momentum_direction_bias: 0.0)
    hi = Pulse::Domain::ScoringConfig.new(momentum_direction_bias: 0.5)
    assert_in_delta 0.0, lo.momentum_direction_bias, 1e-12, 'bias 0.0 is the inclusive lower bound'
    assert_in_delta 0.5, hi.momentum_direction_bias, 1e-12, 'bias 0.5 is the inclusive upper bound'
  end

  def test_accepts_on_track_threshold_boundaries
    lo = Pulse::Domain::ScoringConfig.new(on_track_threshold: 0.0)
    hi = Pulse::Domain::ScoringConfig.new(on_track_threshold: 1.0)
    assert_in_delta 0.0, lo.on_track_threshold, 1e-12, 'threshold 0.0 is the inclusive lower bound'
    assert_in_delta 1.0, hi.on_track_threshold, 1e-12, 'threshold 1.0 is the inclusive upper bound'
  end
end
