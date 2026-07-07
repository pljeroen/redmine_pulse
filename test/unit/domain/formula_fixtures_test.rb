# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'yaml'

# AC-SCORE-FORMULA — golden fixtures (validated portfolio.yaml seed math).
# Drives the REAL Scoring.score path with the supplied aggregates and asserts the
# exact domain outputs (health_score / rag / dominant_signal exact; Float fields
# within tolerance against the display-rounded seed values).
class FormulaFixturesTest < Minitest::Test
  include ScoringSupport

  FIXTURE = File.expand_path('../../../fixtures/scoring/golden_portfolio.yaml', __FILE__)

  def fixtures
    YAML.safe_load_file(FIXTURE, permitted_classes: [Symbol])['fixtures']
  end

  def metrics_from(fx)
    inp = fx['inputs']
    today = ScoringSupport::TODAY
    metrics(
      project_id: fx['project_id'],
      reference_date: today - inp['days_stale'],
      effort_open: inp['effort_open'].to_f,
      effort_total: inp['effort_total'].to_f,
      risk_raw: inp['risk_raw'].to_f,
      blocked_count: inp['blocked_count'],
      risk_mapped: inp['risk_mapped'],
      effort_mapped: inp['effort_mapped'],
      event_series: events_for(opened: inp['opened'], closed: inp['closed'])
    )
  end

  def test_golden_fixtures_exact_outputs
    fixtures.each do |fx|
      h = Pulse::Domain::Scoring.score(metrics_from(fx), fixed_clock, config)
      exp = fx['expected']
      name = fx['name']

      assert_equal exp['health_score'], h.health_score, "#{name}: health_score"
      assert_equal exp['rag'].to_sym, h.rag, "#{name}: rag"
      assert_equal exp['dominant_signal'].to_sym, h.dominant_signal, "#{name}: dominant_signal"
      assert_in_delta exp['signal_completeness'], h.signal_completeness, 1e-9, "#{name}: completeness"

      lk = exp['lens_keys']
      assert_equal lk['health'], h.lens_keys[:health], "#{name}: lens health"
      assert_in_delta lk['at_risk'], h.lens_keys[:at_risk], 0.01, "#{name}: lens at_risk"
      assert_equal lk['stale'], h.lens_keys[:stale], "#{name}: lens stale"
      assert_in_delta lk['done'], h.lens_keys[:done], 1e-6, "#{name}: lens done"
      assert_equal lk['blocked'], h.lens_keys[:blocked], "#{name}: lens blocked"

      exp['signals'].each do |key, esig|
        s = signal(h, key.to_sym)
        assert_equal esig['active'], s.active, "#{name}/#{key}: active"
        if esig['active']
          assert_in_delta esig['n'], s.n, 1e-5, "#{name}/#{key}: n"
          assert_in_delta esig['effective_weight'], s.effective_weight, 1e-5, "#{name}/#{key}: eff_weight"
          assert_in_delta esig['contribution'], s.contribution, 1e-4, "#{name}/#{key}: contribution"
          assert_in_delta esig['raw_value'].to_f, s.raw_value.to_f, 1e-6, "#{name}/#{key}: raw_value"
        else
          assert_nil s.n, "#{name}/#{key}: inactive n nil"
          assert_nil s.effective_weight
          assert_nil s.contribution
          assert_nil s.raw_value
        end
      end
    end
  end

  def test_explainability_reconstruction_on_fixtures
    fixtures.each do |fx|
      h = Pulse::Domain::Scoring.score(metrics_from(fx), fixed_clock, config)
      raw = h.breakdown.select(&:active).sum(&:contribution)
      reconstructed = [[(raw + 0.5).floor, 0].max, 100].min
      assert_equal h.health_score, reconstructed, "#{fx['name']}: Σcontribution reconstructs score"
    end
  end
end
