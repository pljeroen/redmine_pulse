# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/alert_rules'
require 'pulse/domain/alert_event'
require 'pulse/domain/health_result'
require 'time'

# C6 / FR-C6-02 / FR-C6-06 / FC-C6-01/02/03 — AlertRules pure transition detection.
#
# Pulse::Domain::AlertRules.evaluate(prior_state, health_result) -> frozen Array<AlertEvent>.
#   prior_state : Hash-or-nil {last_rag, last_dominant, last_no_data, last_score} (nil = first run)
#   health_result : Pulse::Domain::HealthResult (.rag Symbol, .dominant_signal, .health_score)
#
# The RECONCILED predicates (post SAT-C6-01 / SAT-C6-02 closure) — for prior p, current c:
#   (1) rag_transition   IFF prior_rag PRESENT AND prior_rag != rag AND rag != :no_data
#   (2) dominant_change  IFF prior_dom PRESENT AND prior_dom != dom AND BOTH non-no-data
#   (3) no_data_appeared IFF prior_rag PRESENT AND prior_rag != :no_data AND rag == :no_data
#   (4) score_delta      IFF N configured (non-nil AND N>0) AND prior_score PRESENT AND
#                            CURRENT score PRESENT AND |score - prior_score| >= N
#   first-run (prior nil OR all-nil) -> [] (baseline; nothing fires; no first-cron flood).
#
# The threshold N is supplied to evaluate (canonical/global setting, DEFAULT disabled).
# The exact keyword AlertRules uses for N (e.g. score_delta_threshold:) is defined here.
#
# :no_data is a REAL RAG band (scoring.rb NO_DATA_RAG=:no_data); in it health_score AND
# dominant_signal are nil (scoring.rb no_data_result) — the grounding for both SAT fixes.
#
# Pure lane: `ruby -Itest -Ilib test/unit/domain/alert_rules_test.rb`.
# RED until lib/pulse/domain/alert_rules.rb + alert_event.rb exist (NameError).
class AlertRulesTest < Minitest::Test
  OCC = Time.utc(2026, 7, 6, 9, 0, 0)
  PID = 11

  # Build a HealthResult with just the fields AlertRules consumes; the other VO fields
  # are filled with inert-but-valid values so the frozen VO constructs.
  def hr(rag:, dominant:, score:)
    Pulse::Domain::HealthResult.new(
      project_id: PID, health_score: score, rag: rag, dominant_signal: dominant,
      signal_completeness: 1.0, breakdown: [], lens_keys: {}, effort_open: 0.0
    )
  end

  def prior(rag:, dominant:, no_data:, score:)
    { last_rag: rag, last_dominant: dominant, last_no_data: no_data, last_score: score }
  end

  def types(events)
    events.map(&:event_type)
  end

  # Evaluate; N defaults to disabled (nil) unless a test passes score_delta_threshold:.
  def evaluate(prior_state, health_result, n: nil)
    Pulse::Domain::AlertRules.evaluate(prior_state, health_result, score_delta_threshold: n)
  end

  # ── purity + determinism (FC-C6-01) ─────────────────────────────────────────
  def test_evaluate_is_deterministic_and_returns_frozen_array
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :amber, dominant: :staleness, score: 55.0)
    a = evaluate(p, c)
    b = evaluate(p, c)
    assert_equal a, b, 'same inputs => value-equal event arrays (deterministic)'
    assert a.frozen?, 'evaluate returns a FROZEN Array'
  end

  # ── first-run baseline (FC-C6-03) ───────────────────────────────────────────
  def test_first_run_nil_prior_returns_empty
    c = hr(rag: :amber, dominant: :staleness, score: 55.0)
    assert_equal [], evaluate(nil, c), 'nil prior => baseline, nothing fires'
  end

  def test_first_run_all_nil_prior_returns_empty
    p = prior(rag: nil, dominant: nil, no_data: nil, score: nil)
    c = hr(rag: :amber, dominant: :staleness, score: 55.0)
    assert_equal [], evaluate(p, c), 'all-nil prior (no prior row) => baseline, nothing fires'
  end

  def test_baseline_is_armed_on_the_second_evaluate
    # After the baseline is written, a real prior + changed current DOES fire.
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :amber, dominant: :staleness, score: 60.0)
    assert_equal [:rag_transition], types(evaluate(p, c)),
                 'baseline now armed: green->amber fires exactly one rag_transition'
  end

  # ── (1) rag_transition: green -> amber (AC-C6-02) ───────────────────────────
  def test_green_to_amber_fires_exactly_one_rag_transition
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 70.0)
    c = hr(rag: :amber, dominant: :staleness, score: 60.0)
    ev = evaluate(p, c)
    assert_equal [:rag_transition], types(ev)
    assert_equal 1, ev.size
    assert_equal PID, ev.first.project_id
  end

  # ── second run, no change => [] (FC-C6-15 idempotence at the rules layer) ────
  def test_second_run_no_change_returns_empty
    p = prior(rag: 'amber', dominant: 'staleness', no_data: false, score: 60.0)
    c = hr(rag: :amber, dominant: :staleness, score: 60.0)
    assert_equal [], evaluate(p, c), 'no band/dominant/score change => no events'
  end

  # ── (3) into-no-data: green -> :no_data => [no_data_appeared] ONLY (SAT-C6-01)
  def test_green_to_no_data_fires_only_no_data_appeared
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    # :no_data band: health_score AND dominant_signal are nil (scoring grounding).
    c = hr(rag: :no_data, dominant: nil, score: nil)
    ev = types(evaluate(p, c))
    assert_includes ev, :no_data_appeared, 'into-no-data must fire no_data_appeared'
    refute_includes ev, :rag_transition,
                    'into-no-data must NOT fire rag_transition (rag != :no_data guard, SAT-C6-01)'
    refute_includes ev, :dominant_change,
                    'into-no-data must NOT fire dominant_change (both must be non-no-data)'
    assert_equal [:no_data_appeared], ev, 'exactly [no_data_appeared] on the into-no-data step'
  end

  # ── (1) out-of-no-data recovery: :no_data -> green => [rag_transition] ───────
  def test_no_data_to_green_fires_rag_transition_recovery_not_no_data_appeared
    p = prior(rag: 'no_data', dominant: nil, no_data: true, score: nil)
    c = hr(rag: :green, dominant: :staleness, score: 85.0)
    ev = types(evaluate(p, c))
    assert_includes ev, :rag_transition,
                    'out-of-no-data recovery fires rag_transition (band recovered)'
    refute_includes ev, :no_data_appeared,
                    'recovery must NOT fire no_data_appeared (rag != :no_data)'
    assert_equal [:rag_transition], ev
  end

  # ── (2) dominant_change with both active => [dominant_change] (AC-C6-03) ─────
  def test_dominant_change_both_active
    p = prior(rag: 'amber', dominant: 'staleness', no_data: false, score: 55.0)
    c = hr(rag: :amber, dominant: :risk_load, score: 55.0)
    assert_equal [:dominant_change], types(evaluate(p, c)),
                 'dominant key change with both non-no-data and same band => one dominant_change'
  end

  def test_dominant_change_does_not_fire_when_prior_is_no_data
    # both-non-no-data guard: coming OUT of no_data must not emit dominant_change even
    # if the dominant differs (prior dominant was nil in no_data).
    p = prior(rag: 'no_data', dominant: nil, no_data: true, score: nil)
    c = hr(rag: :green, dominant: :staleness, score: 85.0)
    refute_includes types(evaluate(p, c)), :dominant_change,
                    'no dominant_change when prior state was no_data (both must be non-no-data)'
  end

  # ── (4) score_delta: fires only when N set AND both scores present ──────────
  def test_score_delta_fires_when_delta_ge_n_and_n_configured
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :green, dominant: :staleness, score: 60.0) # |delta| 20
    ev = types(evaluate(p, c, n: 15.0))
    assert_includes ev, :score_delta, '|delta| 20 >= N 15 => score_delta fires'
    assert_equal [:score_delta], ev, 'same band + same dominant: only score_delta'
  end

  def test_score_delta_does_not_fire_when_delta_below_n
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :green, dominant: :staleness, score: 72.0) # |delta| 8
    refute_includes types(evaluate(p, c, n: 15.0)), :score_delta, '|delta| 8 < N 15 => none'
  end

  def test_score_delta_never_fires_when_n_disabled_even_for_large_delta_nil_N
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 90.0)
    c = hr(rag: :green, dominant: :staleness, score: 10.0) # |delta| 80
    assert_equal [], evaluate(p, c, n: nil), 'N nil (default disabled) => no score_delta (AC-C6-08)'
  end

  def test_score_delta_never_fires_when_n_zero_even_for_large_delta
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 90.0)
    c = hr(rag: :green, dominant: :staleness, score: 10.0)
    assert_equal [], evaluate(p, c, n: 0), 'N 0 => disabled => no score_delta (AC-C6-08)'
  end

  # ── (4) nil-safety: into-no-data with N set => NO score_delta, NO raise (SAT-C6-02)
  def test_score_delta_nil_safe_on_into_no_data_current_score_nil
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :no_data, dominant: nil, score: nil) # current health_score nil
    ev = nil
    assert_silent { ev = evaluate(p, c, n: 15.0) } # must NOT raise on nil arithmetic
    refute_includes types(ev), :score_delta,
                    'current score nil (no_data) => score_delta does not fire (SAT-C6-02)'
  end

  def test_score_delta_nil_safe_on_out_of_no_data_prior_score_nil
    p = prior(rag: 'no_data', dominant: nil, no_data: true, score: nil) # prior score nil
    c = hr(rag: :green, dominant: :staleness, score: 85.0)
    ev = nil
    assert_silent { ev = evaluate(p, c, n: 15.0) }
    refute_includes types(ev), :score_delta,
                    'prior score nil (was no_data) => score_delta does not fire (SAT-C6-02)'
  end

  # ── independence: multiple events in one evaluate (FC-C6-02) ────────────────
  def test_rag_and_score_delta_fire_together_two_events
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :amber, dominant: :staleness, score: 55.0) # band changed AND |delta| 25 >= 15
    ev = types(evaluate(p, c, n: 15.0))
    assert_includes ev, :rag_transition
    assert_includes ev, :score_delta
    assert_equal 2, ev.size, 'a step tripping BOTH band and score threshold => TWO events'
  end

  def test_rag_and_dominant_change_fire_together
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :amber, dominant: :risk_load, score: 78.0) # band + dominant both change
    ev = types(evaluate(p, c))
    assert_includes ev, :rag_transition
    assert_includes ev, :dominant_change
    assert_equal 2, ev.size
  end

  # ── the emitted events carry the transition payload ─────────────────────────
  def test_rag_transition_event_carries_from_to_and_occurred_at
    p = prior(rag: 'green', dominant: 'staleness', no_data: false, score: 80.0)
    c = hr(rag: :amber, dominant: :staleness, score: 55.0)
    e = Pulse::Domain::AlertRules.evaluate(p, c, score_delta_threshold: nil,
                                           occurred_at: OCC).first
    assert_equal :rag_transition, e.event_type
    assert_equal OCC, e.occurred_at, 'occurred_at is injected (no ambient clock in the domain)'
  end
end
