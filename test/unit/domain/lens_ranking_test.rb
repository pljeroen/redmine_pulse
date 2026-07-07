# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/signal_result'
require 'pulse/domain/health_result'
require 'pulse/domain/weight_set'
require 'pulse/domain/custom_lens'
require 'pulse/domain/lens_ranking'

# LensRanking.score(lens, health_result, config) = normalized weighted mean
#   Σ_{k∈INCLUDED}(wₖ·nₖ) / Σ_{k∈INCLUDED}(wₖ)
# over the lens's chosen signals that are BOTH ENABLED (k ∈ config.enabled_signals) AND
# ACTIVE (the SignalResult for k in health_result.breakdown has active==true and non-nil n).
# A chosen signal that is disabled OR inactive is EXCLUDED from BOTH numerator AND
# denominator. When the included-weight sum is 0 => nil (unrankable; never NaN/raise).
class LensRankingTest < Minitest::Test
  LR = Pulse::Domain::LensRanking
  WS = Pulse::Domain::WeightSet
  CL = Pulse::Domain::CustomLens
  SR = Pulse::Domain::SignalResult
  HR = Pulse::Domain::HealthResult

  # An ACTIVE SignalResult with the given normalized health score n. The other numeric
  # fields must be non-nil for an active result; values are irrelevant to ranking
  # (LensRanking consumes only #n, not #effective_weight).
  def active_signal(key, n)
    SR.new(key: key, active: true, raw_value: 1.0, n: n, effective_weight: 0.2, contribution: 0.2)
  end

  # An INACTIVE SignalResult: all numeric fields nil.
  def inactive_signal(key)
    SR.new(key: key, active: false, raw_value: nil, n: nil, effective_weight: nil, contribution: nil)
  end

  # A HealthResult whose #breakdown carries exactly the given SignalResults. The other
  # HealthResult fields are unused by LensRanking; placeholder values keep the VO valid.
  def health(breakdown)
    HR.new(project_id: 1, health_score: 50, rag: :amber, dominant_signal: :staleness,
           signal_completeness: 1.0, breakdown: breakdown,
           lens_keys: { health: 50, at_risk: 50, stale: 0, done: 0, blocked: 0 },
           effort_open: 0.0)
  end

  # A CustomLens over the given signal-key => weight map.
  def lens(weights)
    CL.new(name: 'test', weight_set: WS.new(weights), sort_direction: :asc, threshold: nil)
  end

  # A ScoringConfig whose enabled set is exactly `enabled` (weights sum to 1.0 over it and
  # retain an always-active signal so the always-active weight-sum guard is satisfied). Used only for its
  # #enabled_signals — the LensRanking weights come from the lens, not the config.
  def cfg(enabled)
    # staleness is always-active; anchor on it. Build a valid uniform-ish weight map.
    w = enabled.each_with_object({}) { |k, acc| acc[k] = 0.0 }
    w[:staleness] = 1.0 if enabled.include?(:staleness)
    # If staleness absent but momentum/blocked_load present (always-active), anchor there.
    unless w.value?(1.0)
      anchor = enabled.find { |k| %i[momentum blocked_load].include?(k) } || enabled.first
      w[anchor] = 1.0
    end
    Pulse::Domain::ScoringConfig.new(enabled_signals: enabled, weights: w)
  end

  # === WORKED NUMERIC EXAMPLE (both active, both enabled) ===
  # lens {staleness: 0.6, progress: 0.4}; n_staleness = 0.5, n_progress = 1.0.
  # score = (0.6*0.5 + 0.4*1.0) / (0.6 + 0.4) = (0.3 + 0.4) / 1.0 = 0.7.
  def test_worked_example_weighted_mean_equals_0_7
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([active_signal(:staleness, 0.5), active_signal(:progress, 1.0)])
    c = cfg(%i[staleness progress])
    score = LR.score(l, hr, c)
    assert_in_delta 0.7, score, 1e-12, 'normalized weighted mean (0.6*0.5+0.4*1.0)/(0.6+0.4)=0.7'
  end

  def test_worked_example_is_deterministic
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([active_signal(:staleness, 0.5), active_signal(:progress, 1.0)])
    c = cfg(%i[staleness progress])
    assert_equal LR.score(l, hr, c), LR.score(l, hr, c), 'pure function: same inputs => same Float'
  end

  # === all chosen signals inactive => nil (unrankable) =====
  def test_all_chosen_inactive_returns_nil
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([inactive_signal(:staleness), inactive_signal(:progress)])
    c = cfg(%i[staleness progress])
    assert_nil LR.score(l, hr, c), 'all chosen signals inactive => nil, never 0.0/NaN/raise'
  end

  # === all chosen signals disabled => nil (unrankable) ================
  def test_all_chosen_disabled_returns_nil
    # lens over coverage_gap, but coverage_gap is NOT in the enabled set.
    l = lens(coverage_gap: 1.0)
    hr = health([active_signal(:staleness, 0.5)])          # coverage_gap not even present/active
    c = cfg(%i[staleness momentum])                        # coverage_gap disabled
    assert_nil LR.score(l, hr, c), 'chosen signal disabled => excluded => nil'
  end

  # === partial-inactivity excludes from BOTH sums ==========
  # lens {staleness: 0.6, progress: 0.4}; staleness active (n=0.5), progress INACTIVE.
  # score = (0.6*0.5) / 0.6 = 0.5  (progress excluded from BOTH sums),
  # NOT (0.6*0.5 + 0.4*0)/(0.6+0.4) = 0.3.
  def test_partial_inactive_excludes_from_denominator
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([active_signal(:staleness, 0.5), inactive_signal(:progress)])
    c = cfg(%i[staleness progress])
    score = LR.score(l, hr, c)
    assert_in_delta 0.5, score, 1e-12, 'inactive progress excluded from numerator AND denominator (0.5, not 0.3)'
    refute_in_delta 0.3, score, 1e-9, 'must NOT leave the excluded weight in the denominator'
  end

  # === a DISABLED chosen signal is excluded from BOTH sums ==
  # lens {staleness: 0.6, progress: 0.4}; progress ENABLED? no — only staleness enabled.
  # Even though progress is active, it is disabled => excluded => score = (0.6*0.5)/0.6 = 0.5.
  def test_disabled_chosen_signal_excluded
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([active_signal(:staleness, 0.5), active_signal(:progress, 1.0)])
    c = cfg(%i[staleness momentum])   # progress NOT enabled
    score = LR.score(l, hr, c)
    assert_in_delta 0.5, score, 1e-12, 'disabled progress excluded from both sums (0.5, not 0.7)'
  end

  # === purity — LensRanking does not mutate its inputs ================
  def test_score_does_not_mutate_inputs
    l = lens(staleness: 0.6, progress: 0.4)
    hr = health([active_signal(:staleness, 0.5), active_signal(:progress, 1.0)])
    c = cfg(%i[staleness progress])
    LR.score(l, hr, c)
    assert l.frozen? && hr.frozen? && c.frozen?, 'inputs remain frozen/unmutated after score'
  end

  # === no DSL / eval surface in lens_ranking.rb ==========
  def test_no_eval_or_expression_surface_in_source
    src = File.read(File.expand_path('../../../../lib/pulse/domain/lens_ranking.rb', __FILE__))
    %w[eval instance_eval class_eval module_eval binding].each do |tok|
      refute_match(/\b#{tok}\b/, src, "lens_ranking.rb must contain no #{tok} (no DSL)")
    end
  end
end
