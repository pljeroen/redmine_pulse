# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'pulse/domain/scoring'
require 'pulse/domain/scoring_config'

# Enable-path six-signal scoring.
#
# When coverage_gap is ENABLED (a 6-signal ScoringConfig with renormalized weights Σ==1.0):
#   (a) enabled_in_canonical_order returns 6 keys with coverage_gap LAST;
#   (b) Scoring.compute_signal dispatches :coverage_gap to Signals.coverage_gap;
#   (c) coverage_gap participates in health_score / effective_weight / contribution and
#       signal_completeness denominator == 6 — via the GENERIC machinery (no special-case);
#   (d) dominant_signal can select coverage_gap when it is the argmin n;
#   (e) the at_risk lens is UNCHANGED (coverage_gap at_risk? == false).
class CoverageGapEnableTest < Minitest::Test
  include ScoringSupport

  # A 6-signal enabled config: the 5 base weights renormalized to make room for coverage_gap
  # (0.15), all six summing to 1.0. (0.25+0.25+0.20+0.15+0.15+0.15 = 1.15; scale by 1/1.15.)
  def six_signal_config
    raw = { staleness: 0.25, progress: 0.25, momentum: 0.20,
            risk_load: 0.15, blocked_load: 0.15, coverage_gap: 0.15 }
    total = raw.values.sum
    weights = raw.transform_values { |w| w / total }
    Pulse::Domain::ScoringConfig.new(weights: weights)
  end

  # A metrics object where coverage_gap is ACTIVE (open_issue_count > 0) and other signals
  # are healthy-ish, so coverage_gap can be the worst (argmin n) for the dominant test.
  def active_metrics(**over)
    metrics(
      project_id: 5,
      reference_date: ScoringSupport::TODAY - 5,  # fresh => high staleness n
      effort_open: 1.0, effort_total: 10.0,       # progress n 0.90
      risk_raw: 0.0, blocked_count: 0,
      risk_mapped: true, effort_mapped: true,
      event_series: events_for(opened: 2, closed: 8),
      open_issue_count: 4, covered_sum: 1.0,      # coverage mean 0.25 => n 0.25 (worst)
      **over
    )
  end

  # --- (a) enabled_in_canonical_order: 6 keys, coverage_gap LAST -----------------------
  def test_enabled_order_places_coverage_gap_last
    order = Pulse::Domain::Scoring.enabled_in_canonical_order(six_signal_config)
    assert_equal 6, order.size, 'six enabled signals'
    assert_equal :coverage_gap, order.last, 'coverage_gap is last in canonical order'
  end

  # --- (b)(c) coverage_gap scores with the correct n / effective_weight / contribution --
  def test_coverage_gap_participates_in_scoring
    cfg = six_signal_config
    h = Pulse::Domain::Scoring.score(active_metrics, fixed_clock, cfg)
    cg = h.breakdown.find { |s| s.key == :coverage_gap }
    refute_nil cg, 'coverage_gap appears in the breakdown when enabled'
    assert cg.active, 'coverage_gap active (open_issue_count > 0)'
    assert_equal 0.25, cg.n, 'coverage_gap n == covered_sum/open_issue_count == 0.25'

    # effective_weight == w_cg / Σ_active w ; contribution == 100 * eff * n.
    active = h.breakdown.select(&:active)
    active_weight_sum = active.sum { |s| cfg.weights[s.key] }
    expected_eff = cfg.weights[:coverage_gap] / active_weight_sum
    assert_in_delta expected_eff, cg.effective_weight, 1e-12,
                    'effective_weight normalized over the active subset'
    assert_in_delta 100.0 * expected_eff * cg.n, cg.contribution, 1e-9,
                    'contribution == 100 * effective_weight * n'
  end

  # --- (c) signal_completeness denominator == 6 when six signals are enabled -----------
  def test_signal_completeness_denominator_is_six
    h = Pulse::Domain::Scoring.score(active_metrics, fixed_clock, six_signal_config)
    active_count = h.breakdown.count(&:active)
    assert_in_delta active_count / 6.0, h.signal_completeness, 1e-12,
                    'completeness = active_count / 6 (enabled set of 6)'
  end

  # --- (d) dominant_signal can select coverage_gap when it is the argmin n -------------
  def test_dominant_signal_can_be_coverage_gap
    h = Pulse::Domain::Scoring.score(active_metrics, fixed_clock, six_signal_config)
    assert_equal :coverage_gap, h.dominant_signal,
                 'coverage_gap (n 0.25, the worst) is the severity-first dominant signal'
  end

  # --- (e) the at_risk lens is UNCHANGED by coverage_gap's presence --------------------
  def test_at_risk_lens_unchanged_by_coverage_gap
    m = active_metrics
    with_cg = Pulse::Domain::Scoring.score(m, fixed_clock, six_signal_config)

    # The same metrics scored under the DEFAULT 5-signal config: the at_risk lens value
    # must be identical (coverage_gap does not enter the at_risk summation; at_risk? false).
    five = Pulse::Domain::ScoringConfig.new
    without_cg = Pulse::Domain::Scoring.score(m, fixed_clock, five)
    assert_equal without_cg.lens_keys[:at_risk], with_cg.lens_keys[:at_risk],
                 'at_risk lens value unchanged whether or not coverage_gap is enabled'
  end
end
