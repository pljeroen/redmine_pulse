# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'pulse/domain/signals'
require 'pulse/domain/scoring_config'

# Coverage_gap signal: active math, inactive when no open issues, n in the unit interval.
#
# Signals.coverage_gap(metrics, config): active iff metrics.open_issue_count > 0;
#   mean_cov = covered_sum / open_issue_count.to_f
#   n        = clamp(mean_cov, 0.0, 1.0)
#   raw_value = 1.0 - mean_cov  (the mean GAP fraction)
# Inactive (open_issue_count == 0): active=false, raw_value=nil, n=nil (no divide-by-zero).
# The config argument is ACCEPTED but UNUSED (3 fixed dimensions).
class CoverageGapSignalTest < Minitest::Test
  include ScoringSupport

  # A config to pass through — coverage_gap ignores it. Default construction.
  def cfg
    Pulse::Domain::ScoringConfig.new
  end

  # --- fully planned (cs == oic) => mean 1.0, n 1.0, raw 0.0 -----
  def test_fully_planned_yields_n_one_raw_zero_active
    m = metrics(open_issue_count: 2, covered_sum: 2.0)
    d = Pulse::Domain::Signals.coverage_gap(m, cfg)
    assert_equal :coverage_gap, d.key, 'signal key is :coverage_gap'
    assert d.active, 'coverage_gap active when open_issue_count > 0'
    assert_equal 1.0, d.n, 'cs == oic => n == 1.0'
    assert_equal 0.0, d.raw_value, 'cs == oic => raw_value (gap) == 0.0'
  end

  # --- worked example: 2 open, one 1.0-covered + one 0.0 ---------
  def test_half_coverage_worked_example
    # cs = 1.0 (one issue fully covered contributes 1.0, one uncovered contributes 0.0),
    # oic = 2 => mean_cov = 0.5 => n = 0.5, raw_value = 0.5.
    m = metrics(open_issue_count: 2, covered_sum: 1.0)
    d = Pulse::Domain::Signals.coverage_gap(m, cfg)
    assert d.active
    assert_equal 0.5, d.n, 'mean_cov 0.5 => n 0.5'
    assert_equal 0.5, d.raw_value, 'raw_value == 1 - mean_cov == 0.5'
  end

  # --- oic 3, cs 1.0 => n 1/3, raw 1 - 1/3 (exact Float) ------------------
  def test_third_coverage_exact_float
    m = metrics(open_issue_count: 3, covered_sum: 1.0)
    d = Pulse::Domain::Signals.coverage_gap(m, cfg)
    assert_equal (1.0 / 3.0), d.n, 'n == cs/oic exactly (1.0/3.0)'
    assert_equal (1.0 - 1.0 / 3.0), d.raw_value, 'raw_value == 1 - cs/oic exactly'
  end

  # --- inactive when open_issue_count == 0 (VALID pair 0 / 0.0) ---
  def test_inactive_when_no_open_issues_no_divide_by_zero
    m = metrics(open_issue_count: 0, covered_sum: 0.0)
    d = nil
    # Must NOT raise ZeroDivisionError / FloatDomainError on the oic == 0 path.
    d = Pulse::Domain::Signals.coverage_gap(m, cfg)
    assert_equal :coverage_gap, d.key
    refute d.active, 'coverage_gap inactive when open_issue_count == 0'
    assert_nil d.n, 'inactive => n nil'
    assert_nil d.raw_value, 'inactive => raw_value nil'
  end

  # --- n and raw_value in the unit interval on a valid sweep -----------------
  def test_n_and_raw_value_in_unit_interval_over_valid_sweep
    # Valid (oic, cs) with 0 <= cs <= oic and oic > 0. Assert n in [0,1], raw in [0,1],
    # n == cs/oic (clamp does NOT saturate on valid input), and n + raw == 1.
    [[1, 0.0], [1, 1.0], [2, 0.5], [3, 2.5], [4, 4.0], [5, 0.0], [7, 3.5]].each do |oic, cs|
      m = metrics(open_issue_count: oic, covered_sum: cs)
      d = Pulse::Domain::Signals.coverage_gap(m, cfg)
      assert_operator d.n, :>=, 0.0, "n >= 0 for (#{oic},#{cs})"
      assert_operator d.n, :<=, 1.0, "n <= 1 for (#{oic},#{cs})"
      assert_operator d.raw_value, :>=, 0.0, "raw >= 0 for (#{oic},#{cs})"
      assert_operator d.raw_value, :<=, 1.0, "raw <= 1 for (#{oic},#{cs})"
      assert_in_delta cs / oic.to_f, d.n, 1e-12, "n == cs/oic (clamp did not saturate)"
      assert_in_delta 1.0, d.n + d.raw_value, 1e-12, 'n + raw_value == 1.0'
    end
  end

  # --- config is accepted but does NOT alter the computation --
  def test_config_argument_is_ignored_dimensions_fixed
    m = metrics(open_issue_count: 4, covered_sum: 3.0)
    # Two configs differing ONLY in weights/other keys must yield IDENTICAL n / raw_value.
    cfg_a = Pulse::Domain::ScoringConfig.new(
      weights: { staleness: 0.5, momentum: 0.25, blocked_load: 0.25 }
    )
    cfg_b = Pulse::Domain::ScoringConfig.new(
      weights: { staleness: 0.25, progress: 0.25, momentum: 0.20,
                 risk_load: 0.15, blocked_load: 0.15 }
    )
    da = Pulse::Domain::Signals.coverage_gap(m, cfg_a)
    db = Pulse::Domain::Signals.coverage_gap(m, cfg_b)
    assert_equal da.n, db.n, 'config must not alter the coverage n (dimensions fixed)'
    assert_equal da.raw_value, db.raw_value, 'config must not alter raw_value'
  end
end
