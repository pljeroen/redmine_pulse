# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# round_half_up(Σ active contributions) == health_score; all contributions >= 0;
# holds across active/inactive combos, edge n, and tuned configs.
class ExplainabilityTest < Minitest::Test
  include ScoringSupport

  def round_half_up(x)
    (x + 0.5).floor
  end

  def reconstruct(h)
    raw = h.breakdown.select(&:active).sum(&:contribution)
    [round_half_up(raw), 0].max.then { |v| [v, 100].min }
  end

  def test_score_reconstruction_and_breakdown_shape
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal h.health_score, reconstruct(h)
    assert_equal 5, h.breakdown.length
    h.breakdown.each { |s| assert_operator s.contribution, :>=, 0.0 if s.active }
  end

  def test_exact_reconstruction_all_combos
    combos = [
      kernel_aios_metrics,
      pdfree_metrics,
      metrics(risk_mapped: false, effort_open: 0.0, effort_total: 0.0, blocked_count: 1), # only 3 active (non-empty: a blocker; not no-data)
      metrics(reference_date: ScoringSupport::TODAY, effort_open: 0.0, effort_total: 10.0,
              risk_mapped: true, risk_raw: 0.0, blocked_count: 0, event_series: []), # near-healthy
      metrics(reference_date: ScoringSupport::TODAY - 365, effort_open: 10.0, effort_total: 10.0,
              risk_mapped: true, risk_raw: 100.0, blocked_count: 50,
              event_series: events_for(opened: 50, closed: 0)) # near-zero (worst)
    ]
    clocks = [fixed_clock, fixed_clock(ScoringSupport::TODAY + 5)]
    configs = [
      config,
      config(weights: { staleness: 0.1, progress: 0.1, momentum: 0.3, risk_load: 0.2, blocked_load: 0.3 }),
      config(weights: { staleness: 0.4, progress: 0.2, momentum: 0.2, risk_load: 0.1, blocked_load: 0.1 })
    ]
    combos.each do |m|
      clocks.each do |c|
        configs.each do |cfg|
          h = Pulse::Domain::Scoring.score(m, c, cfg)
          assert_equal h.health_score, reconstruct(h),
                       "reconstruction mismatch for pid=#{m.project_id}"
          h.breakdown.select(&:active).each do |s|
            assert_operator s.contribution, :>=, 0.0
          end
        end
      end
    end
  end

  def test_no_hidden_base_term_when_all_zero_contributions
    # Force all active n == 0 => all contributions 0 => health_score 0 (no base term).
    # staleness 365d, progress 0 done, risk maxed, 50 blocked all drive n==0; momentum is
    # IDLE (no in-window events => activity 0 => n 0.0) under the broadened formula, since a
    # busy project is no longer zero-momentum.
    m = metrics(reference_date: ScoringSupport::TODAY - 365, effort_open: 10.0, effort_total: 10.0,
                risk_mapped: true, risk_raw: 100.0, blocked_count: 50,
                event_series: [])
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config)
    # momentum: activity 0 => base 0, direction 0 => n 0.0 -> all five active n == 0.0.
    assert_equal 0, h.health_score
    assert_equal 0, reconstruct(h)
  end
end
