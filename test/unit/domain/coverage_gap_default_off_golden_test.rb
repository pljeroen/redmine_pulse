# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'yaml'

# The release-critical default-OFF byte-identical golden gate (the designated evidence
# pointer for the coverage_gap backward-compatibility guarantee).
#
# With coverage_gap DISABLED (the default: enabled set == the 5 original built-ins), the
# HealthResult produced for ANY ProjectMetrics input — INCLUDING arbitrary values of the
# NEW open_issue_count/covered_sum fields — MUST be EXACTLY equal (==, NO epsilon on any
# field) to the captured baseline full-precision result for the same scalar inputs. All
# eight HealthResult fields, each breakdown SignalResult field, exact.
#
# Baseline provenance: the SAME full-precision baseline captured for the backward-compat
# gate (test/fixtures/scoring/pre_c1_baseline_full_precision.yaml). The original default
# config produced these values; the DEFAULT config (default_on 5-signal set, coverage_gap
# default_on:false) must reproduce them bit-for-bit — the new oic/cs fields are
# present-but-UNREAD on the default path. The fixtures below EXTEND each input with
# arbitrary non-zero oic/cs (e.g. oic:7, cs:3.5) to PROVE the new fields do NOT affect the
# 5-signal score when coverage_gap is OFF.
class CoverageGapDefaultOffGoldenTest < Minitest::Test
  include ScoringSupport

  BASELINE = File.expand_path('../../../fixtures/scoring/pre_c1_baseline_full_precision.yaml', __FILE__)

  # Arbitrary non-zero coverage inputs injected into EVERY golden fixture to prove they are
  # present-but-unread on the default (coverage_gap OFF) path. Cycled per fixture so the
  # gate is not accidentally satisfied by a single oic/cs value.
  COVERAGE_INJECTS = [[7, 3.5], [4, 4.0], [10, 0.0], [3, 1.0], [5, 2.5]].freeze

  def baseline
    YAML.safe_load_file(BASELINE)['cases']
  end

  # The DEFAULT config — built through the default_on-scoped default path. weights: nil
  # => SignalRegistry.default_weights (the 5 default_on signals, Σ==1.0). This exercises the
  # exact default plumbing coverage_gap must NOT perturb.
  def default_config
    Pulse::Domain::ScoringConfig.new
  end

  def num(v)
    return nil if v.nil?
    return v if v.is_a?(Integer)
    return Float(v) if v.is_a?(String)

    v
  end

  # Build metrics from a baseline row, INJECTING arbitrary oic/cs to prove they are unread.
  def metrics_from(inp, idx)
    today = ScoringSupport::TODAY
    oic, cs = COVERAGE_INJECTS[idx % COVERAGE_INJECTS.size]
    metrics(
      project_id: inp['project_id'],
      reference_date: today - inp['days_stale'],
      effort_open: inp['effort_open'].to_f,
      effort_total: inp['effort_total'].to_f,
      risk_raw: inp['risk_raw'].to_f,
      blocked_count: inp['blocked_count'],
      risk_mapped: inp['risk_mapped'],
      effort_mapped: inp['effort_mapped'],
      event_series: mixed_events(inp),
      open_issue_count: oic,
      covered_sum: cs
    )
  end

  def mixed_events(inp)
    date = ScoringSupport::TODAY - 1
    Array.new(inp['opened'].to_i)    { { date: date, type: :issue_created } } +
      Array.new(inp['closed'].to_i)    { { date: date, type: :issue_closed } } +
      Array.new(inp.fetch('commented', 0).to_i) { { date: date, type: :issue_commented } } +
      Array.new(inp.fetch('commits', 0).to_i)   { { date: date, type: :commit } }
  end

  def sym_or_nil(v)
    v.nil? ? nil : v.to_sym
  end

  def assert_exact(expected, actual, msg)
    if expected.nil?
      assert_nil actual, msg
    else
      assert_equal expected, actual, msg
    end
  end

  # === the exact-equality default-OFF gate =========================
  def test_default_off_output_byte_identical_to_pre_c2_baseline
    baseline.each_with_index do |(name, row), idx|
      h = Pulse::Domain::Scoring.score(metrics_from(row['inputs'], idx), fixed_clock, default_config)
      exp = row['expected']

      assert_equal exp['project_id'], h.project_id, "#{name}: project_id"
      assert_exact exp['health_score'], h.health_score, "#{name}: health_score (exact)"
      assert_equal exp['rag'].to_sym, h.rag, "#{name}: rag"
      assert_exact sym_or_nil(exp['dominant_signal']), h.dominant_signal, "#{name}: dominant_signal"

      assert_exact num(exp['signal_completeness']), h.signal_completeness,
                   "#{name}: signal_completeness (EXACT, no epsilon)"
      assert_exact num(exp['effort_open']), h.effort_open, "#{name}: effort_open (exact)"

      lk = exp['lens_keys']
      assert_exact lk['health'], h.lens_keys[:health], "#{name}: lens health"
      assert_exact num(lk['at_risk']), h.lens_keys[:at_risk], "#{name}: lens at_risk (EXACT)"
      assert_exact lk['stale'], h.lens_keys[:stale], "#{name}: lens stale"
      assert_exact num(lk['done']), h.lens_keys[:done], "#{name}: lens done (EXACT)"
      assert_exact lk['blocked'], h.lens_keys[:blocked], "#{name}: lens blocked"

      # breakdown: EXACTLY the 5 original rows, coverage_gap ABSENT, every field exact.
      assert_equal %i[staleness progress momentum risk_load blocked_load],
                   h.breakdown.map(&:key), "#{name}: breakdown == 5 original rows (coverage_gap absent)"
      exp_bd = exp['breakdown']
      assert_equal exp_bd.size, h.breakdown.size, "#{name}: breakdown length (5, not 6)"
      exp_bd.each_with_index do |es, i|
        s = h.breakdown[i]
        assert_equal es['key'].to_sym, s.key, "#{name}: breakdown[#{i}] key/order"
        assert_equal es['active'], s.active, "#{name}: breakdown[#{i}] active"
        assert_exact num(es['raw_value']), s.raw_value, "#{name}: breakdown[#{i}] raw_value (EXACT)"
        assert_exact num(es['n']), s.n, "#{name}: breakdown[#{i}] n (EXACT)"
        assert_exact num(es['effective_weight']), s.effective_weight, "#{name}: breakdown[#{i}] effective_weight (EXACT)"
        assert_exact num(es['contribution']), s.contribution, "#{name}: breakdown[#{i}] contribution (EXACT)"
      end
    end
  end

  # A focused proof: two default-OFF results for the SAME inputs but DIFFERENT oic/cs are
  # byte-identical — the new fields are unread on the default path.
  def test_new_fields_do_not_affect_default_off_output
    row = baseline.values.first
    a = Pulse::Domain::Scoring.score(
      metrics_from(row['inputs'].merge, 0), fixed_clock, default_config
    )
    # Same inputs, wildly different coverage aggregate.
    b_inputs = row['inputs']
    b = Pulse::Domain::Scoring.score(
      metrics(
        project_id: b_inputs['project_id'],
        reference_date: ScoringSupport::TODAY - b_inputs['days_stale'],
        effort_open: b_inputs['effort_open'].to_f, effort_total: b_inputs['effort_total'].to_f,
        risk_raw: b_inputs['risk_raw'].to_f, blocked_count: b_inputs['blocked_count'],
        risk_mapped: b_inputs['risk_mapped'], effort_mapped: b_inputs['effort_mapped'],
        event_series: mixed_events(b_inputs),
        open_issue_count: 99, covered_sum: 0.0 # very different coverage
      ), fixed_clock, default_config
    )
    assert_equal a.health_score, b.health_score, 'health_score independent of oic/cs when OFF'
    assert_equal a.signal_completeness, b.signal_completeness, 'completeness independent of oic/cs'
    assert_equal a.breakdown.map(&:key), b.breakdown.map(&:key), 'breakdown keys unchanged'
    assert_equal a.lens_keys, b.lens_keys, 'lens_keys independent of oic/cs when OFF'
  end
end
