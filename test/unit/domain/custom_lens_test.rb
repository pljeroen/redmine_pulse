# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/weight_set'
require 'pulse/domain/custom_lens'

# CustomLens frozen VO = { name (non-empty String), weight_set (a WeightSet),
# sort_direction (:asc | :desc), threshold (Numeric or nil) }. Fails loud
# (ArgumentError) on invalid input. Frozen; mutation => FrozenError.
class CustomLensTest < Minitest::Test
  CL = Pulse::Domain::CustomLens
  WS = Pulse::Domain::WeightSet

  def valid_ws
    WS.new(staleness: 0.6, progress: 0.4)
  end

  def lens(**over)
    defaults = { name: 'Delivery risk', weight_set: valid_ws, sort_direction: :asc, threshold: nil }
    CL.new(**defaults.merge(over))
  end

  # === valid construction ============================================
  def test_valid_construction_asc_no_threshold
    l = lens
    assert_equal 'Delivery risk', l.name
    assert_equal valid_ws.to_h, l.weight_set.to_h
    assert_equal :asc, l.sort_direction
    assert_nil l.threshold
  end

  def test_valid_construction_desc_with_numeric_threshold
    l = lens(sort_direction: :desc, threshold: 50)
    assert_equal :desc, l.sort_direction
    assert_equal 50, l.threshold
  end

  def test_valid_construction_float_threshold
    l = lens(threshold: 0.75)
    assert_equal 0.75, l.threshold
  end

  # === name must be a non-empty String =====================
  def test_empty_name_raises
    assert_raises(ArgumentError) { lens(name: '') }
  end

  def test_blank_whitespace_name_raises
    assert_raises(ArgumentError) { lens(name: '   ') }
  end

  def test_nil_name_raises
    assert_raises(ArgumentError) { lens(name: nil) }
  end

  def test_non_string_name_raises
    assert_raises(ArgumentError) { lens(name: 123) }
    assert_raises(ArgumentError) { lens(name: :delivery_risk) }
  end

  # === sort_direction in {:asc, :desc} =====================
  def test_bad_sort_direction_symbol_raises
    assert_raises(ArgumentError) { lens(sort_direction: :up) }
  end

  def test_string_sort_direction_raises
    assert_raises(ArgumentError) { lens(sort_direction: 'asc') }
  end

  def test_nil_sort_direction_raises
    assert_raises(ArgumentError) { lens(sort_direction: nil) }
  end

  # === threshold is nil OR a finite real Numeric =====================
  def test_non_numeric_threshold_raises
    assert_raises(ArgumentError) { lens(threshold: 'x') }
  end

  # threshold must be a FINITE REAL Numeric — NaN/Inf/Complex rejected.
  def test_nan_threshold_raises
    assert_raises(ArgumentError) { lens(threshold: Float::NAN) }
  end

  def test_infinite_threshold_raises
    assert_raises(ArgumentError) { lens(threshold: Float::INFINITY) }
    assert_raises(ArgumentError) { lens(threshold: -Float::INFINITY) }
  end

  def test_complex_threshold_raises
    err = assert_raises(StandardError) { lens(threshold: Complex(1, 1)) }
    assert_instance_of ArgumentError, err,
                       'Complex threshold must fail loud as ArgumentError (type-before-compare)'
  end

  def test_valid_integer_float_and_nil_thresholds_accepted
    assert_equal 50, lens(threshold: 50).threshold
    assert_equal 0.75, lens(threshold: 0.75).threshold
    assert_equal Rational(1, 2), lens(threshold: Rational(1, 2)).threshold
    assert_nil lens(threshold: nil).threshold
  end

  # === weight_set must be a WeightSet (a raw Hash is rejected) =========
  def test_raw_hash_weight_set_raises
    assert_raises(ArgumentError) do
      CL.new(name: 'x', weight_set: { staleness: 1.0 }, sort_direction: :asc, threshold: nil)
    end
  end

  def test_nil_weight_set_raises
    assert_raises(ArgumentError) { lens(weight_set: nil) }
  end

  # === frozen VO; mutation => FrozenError ==================
  def test_lens_is_frozen
    assert lens.frozen?, 'CustomLens must be frozen'
  end

  def test_mutation_raises_frozen_error
    l = lens
    assert_raises(FrozenError) { l.instance_variable_set(:@name, 'other') }
  end

  # The caller-owned name String must not be able to mutate lens.name after construction —
  # the classic dup.freeze immutability hole. Store @name = name.dup.freeze.
  def test_name_is_isolated_from_caller_string_mutation
    original = +'Delivery risk'   # unary + => an explicitly mutable String
    l = CL.new(name: original, weight_set: valid_ws, sort_direction: :asc, threshold: nil)
    original << ' MUTATED'
    assert_equal 'Delivery risk', l.name,
                 'lens.name must be isolated from post-construction mutation of the caller String'
    assert l.name.frozen?, 'lens.name must itself be frozen'
  end

  # === no DSL / expression surface — declarative fields only ===
  def test_no_eval_or_expression_surface_in_source
    src = File.read(File.expand_path('../../../../lib/pulse/domain/custom_lens.rb', __FILE__))
    %w[eval instance_eval class_eval module_eval binding].each do |tok|
      refute_match(/\b#{tok}\b/, src, "custom_lens.rb must contain no #{tok} (no DSL)")
    end
  end
end
