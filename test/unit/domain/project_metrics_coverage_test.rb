# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'

# ProjectMetrics additive coverage-field validity.
#
# Two REQUIRED keyword fields:
#   open_issue_count : non-negative Integer (validate_non_negative_integer!)
#   covered_sum      : finite real Numeric, 0 <= covered_sum <= open_issue_count
# Additive + required (no Ruby defaults) so a MISSED construction site fails LOUD.
# Existing fields are byte-unchanged (their validators are covered by the existing
# ProjectMetricsTest / ValueObjectValidationTest, which stay verbatim).
class ProjectMetricsCoverageTest < Minitest::Test
  # The original field set (WITHOUT the two new keys). This must raise ArgumentError
  # (missing required keyword) — catching any construction site that forgot the new fields.
  PRE_C2_ARGS = {
    project_id: 11,
    reference_date: Date.new(2026, 1, 21),
    effort_open: 7.0, effort_total: 10.0, risk_raw: 40.0,
    blocked_count: 12, risk_mapped: true, effort_mapped: true,
    event_series: [{ date: Date.new(2026, 6, 10), type: :issue_closed }],
    version_due_dates: [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }]
  }.freeze

  def build(**overrides)
    Pulse::Domain::ProjectMetrics.new(**PRE_C2_ARGS.merge(open_issue_count: 3, covered_sum: 2.5).merge(overrides))
  end

  # --- (a) open_issue_count must be a non-negative Integer -----------------------------
  def test_rejects_negative_open_issue_count
    assert_raises(ArgumentError) { build(open_issue_count: -1, covered_sum: 0.0) }
  end

  def test_rejects_float_open_issue_count
    assert_raises(ArgumentError) { build(open_issue_count: 1.5, covered_sum: 0.0) }
  end

  def test_rejects_string_open_issue_count
    assert_raises(ArgumentError) { build(open_issue_count: '3', covered_sum: 0.0) }
  end

  # --- (b) covered_sum must be a finite real Numeric, 0 <= covered_sum <= open_issue_count
  def test_rejects_negative_covered_sum
    assert_raises(ArgumentError) { build(open_issue_count: 3, covered_sum: -0.1) }
  end

  def test_rejects_nan_covered_sum
    assert_raises(ArgumentError) { build(open_issue_count: 3, covered_sum: Float::NAN) }
  end

  def test_rejects_infinity_covered_sum
    assert_raises(ArgumentError) { build(open_issue_count: 3, covered_sum: Float::INFINITY) }
  end

  def test_rejects_covered_sum_greater_than_open_issue_count
    # cs 3.0 with oic 2 => mean_cov 1.5 > 1: invalid (the max sum is oic).
    assert_raises(ArgumentError) { build(open_issue_count: 2, covered_sum: 3.0) }
  end

  def test_rejects_complex_covered_sum
    assert_raises(ArgumentError) { build(open_issue_count: 3, covered_sum: Complex(1, 1)) }
  end

  # --- (c) a valid pair constructs; readers return the values --------------------------
  def test_valid_pair_constructs_and_readers_return_values
    m = build(open_issue_count: 3, covered_sum: 2.5)
    assert_equal 3, m.open_issue_count
    assert_equal 2.5, m.covered_sum
  end

  def test_boundary_pairs_construct
    # cs == 0.0 (fully uncovered) and cs == oic (fully covered) are the valid extremes.
    assert_equal 0.0, build(open_issue_count: 4, covered_sum: 0.0).covered_sum
    assert_equal 4.0, build(open_issue_count: 4, covered_sum: 4.0).covered_sum
    # oic == 0 requires cs == 0.0 (the only valid aggregate when there are no open issues).
    zero = build(open_issue_count: 0, covered_sum: 0.0)
    assert_equal 0, zero.open_issue_count
    assert_equal 0.0, zero.covered_sum
  end

  # --- (d) the original field set (minus the two new keys) fails LOUD --------------------
  def test_construction_without_new_keys_raises
    # This is the loud-failure requirement: a missed site must ArgumentError, not silently build.
    assert_raises(ArgumentError) { Pulse::Domain::ProjectMetrics.new(**PRE_C2_ARGS) }
  end

  # --- existing fields byte-unchanged (spot check the original validators still fire) -----
  def test_existing_field_validators_unchanged
    assert_raises(ArgumentError) { build(effort_open: -1.0) }
    assert_raises(ArgumentError) { build(blocked_count: 12.0) }
    assert_raises(ArgumentError) { build(reference_date: '2026-01-21') }
  end
end
