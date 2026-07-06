# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'yaml'

# FR-C1-08 / AC-C1-01 / FC-C1-13 — the RELEASE-CRITICAL byte-identical golden gate.
#
# The DEFAULT ScoringConfig — constructed via the NEW registry-backed default path
# (Pulse::Domain::SignalRegistry-resolved enabled set + default weights) — MUST
# produce a HealthResult EXACTLY equal (==, NO epsilon) to a captured pre-C1
# full-precision baseline on ALL eight fields, over a representative fixture set.
#
# Baseline provenance (A-DATA-01): captured from the CURRENT (pre-C1) Scoring.score
# with the DEFAULT config, serialized at full Float precision (Ruby Float#to_s =
# shortest round-trippable string). Reparsing reconstructs bit-identical Floats, so
# the comparison below is EXACT bit-equality (assert_equal on Floats), DISTINCT from
# the display-rounded golden_portfolio.yaml (which uses tolerances — FormulaFixturesTest).
#
# RED NOW: the "NEW registry-backed default path" does not exist yet
# (Pulse::Domain::SignalRegistry is absent), so `default_config` raises NameError.
# GREEN AFTER A9 reproduces exact values on the default enabled set.
class BackwardCompatGoldenTest < Minitest::Test
  include ScoringSupport

  BASELINE = File.expand_path('../../../fixtures/scoring/pre_c1_baseline_full_precision.yaml', __FILE__)

  def baseline
    YAML.safe_load_file(BASELINE)['cases']
  end

  # The DEFAULT config MUST be built through the NEW registry-backed default path —
  # NOT the literal ScoringConfig.new — so the gate exercises the C1 default plumbing
  # (SignalRegistry.keys as enabled set, SignalRegistry.default_weights as weights).
  # This is what makes the test RED before A9 wires the registry default path.
  def default_config
    Pulse::Domain::ScoringConfig.new(
      enabled_signals: Pulse::Domain::SignalRegistry.keys,
      weights: Pulse::Domain::SignalRegistry.default_weights
    )
  end

  # Reconstruct a bit-identical Float from the baseline's shortest-round-trip string.
  def num(v)
    return nil if v.nil?
    return v if v.is_a?(Integer)
    return Float(v) if v.is_a?(String) # a serialized Float -> exact reparse
    v
  end

  def metrics_from(inp)
    today = ScoringSupport::TODAY
    metrics(
      project_id: inp['project_id'],
      reference_date: today - inp['days_stale'],
      effort_open: inp['effort_open'].to_f,
      effort_total: inp['effort_total'].to_f,
      risk_raw: inp['risk_raw'].to_f,
      blocked_count: inp['blocked_count'],
      risk_mapped: inp['risk_mapped'],
      effort_mapped: inp['effort_mapped'],
      event_series: mixed_events(inp)
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

  # Portable exact-equality that also handles the nil baseline values (no-data path,
  # nil dominant, all-nil lens). Under minitest 6.x `assert_equal(nil, actual)` is a
  # hard error, so branch to assert_nil when the expected value is nil; otherwise keep
  # EXACT assert_equal (Float bit-equality, NO epsilon). Passes under minitest 5.x too.
  def assert_exact(expected, actual, msg)
    if expected.nil?
      assert_nil actual, msg
    else
      assert_equal expected, actual, msg
    end
  end

  # === The exact-equality gate ==============================================
  def test_default_output_byte_identical_to_pre_c1_baseline
    baseline.each do |name, row|
      h = Pulse::Domain::Scoring.score(metrics_from(row['inputs']), fixed_clock, default_config)
      exp = row['expected']

      assert_equal exp['project_id'], h.project_id, "#{name}: project_id"
      assert_exact exp['health_score'], h.health_score, "#{name}: health_score (exact)"
      assert_equal exp['rag'].to_sym, h.rag, "#{name}: rag"
      assert_exact sym_or_nil(exp['dominant_signal']), h.dominant_signal, "#{name}: dominant_signal"

      # EXACT Float bit-equality — assert_exact (assert_equal on non-nil), NOT assert_in_delta.
      assert_exact num(exp['signal_completeness']), h.signal_completeness,
                   "#{name}: signal_completeness (EXACT, no epsilon)"
      assert_exact num(exp['effort_open']), h.effort_open, "#{name}: effort_open (exact)"

      lk = exp['lens_keys']
      assert_exact lk['health'], h.lens_keys[:health], "#{name}: lens health"
      assert_exact num(lk['at_risk']), h.lens_keys[:at_risk], "#{name}: lens at_risk (EXACT)"
      assert_exact lk['stale'], h.lens_keys[:stale], "#{name}: lens stale"
      assert_exact num(lk['done']), h.lens_keys[:done], "#{name}: lens done (EXACT)"
      assert_exact lk['blocked'], h.lens_keys[:blocked], "#{name}: lens blocked"

      # breakdown: same length, same order, every SignalResult field EXACT.
      exp_bd = exp['breakdown']
      assert_equal exp_bd.size, h.breakdown.size, "#{name}: breakdown length"
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

  # FC-C1-12: the default no-data path is byte-identical (5 inactive SignalResults in
  # canonical order, rag :no_data, nil score/dominant, completeness 0.0, all-nil lens).
  def test_no_data_default_path_byte_identical
    nd = baseline.select { |_, row| row['expected']['rag'] == 'no_data' }
    refute_empty nd, 'baseline must carry at least one no-data fixture (FC-C1-12)'
    nd.each do |name, row|
      h = Pulse::Domain::Scoring.score(metrics_from(row['inputs']), fixed_clock, default_config)
      assert_equal :no_data, h.rag, "#{name}: no_data rag"
      assert_nil h.health_score, "#{name}: no_data health_score nil"
      assert_nil h.dominant_signal, "#{name}: no_data dominant nil"
      assert_equal 0.0, h.signal_completeness, "#{name}: no_data completeness 0.0"
      assert_equal %i[staleness progress momentum risk_load blocked_load],
                   h.breakdown.map(&:key), "#{name}: no_data breakdown canonical order"
      refute h.breakdown.any?(&:active), "#{name}: no_data breakdown all inactive"
      h.lens_keys.each_value { |v| assert_nil v, "#{name}: no_data lens value nil" }
    end
  end
end
