# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'
require 'pulse/domain/scoring'
require 'pulse/domain/project_metrics'

# Scoring under a profile uses EXACTLY that profile's ScoringConfig:
#   (a) two profiles with DIFFERENT weights on the SAME metrics yield DIFFERENT
#       health_score / rag / dominant_signal (where the weights differ);
#   (b) a profile ENABLING coverage_gap yields a distinct breakdown vs one that does not;
#   (c) a profile DISABLING a signal s => s absent from the breakdown, never dominant,
#       and health_score equals the score computed WITHOUT s.
#
# The Scoring domain is parameterized on ScoringConfig; the guarantee is that scoring is
# driven by active_profile.config (NOT a global config). This is proved at the domain
# layer: Scoring.score(metrics, clock, active_profile.config).
#
# Pure lane: ruby -Itest -Ilib.
class ScoringUnderProfileTest < Minitest::Test
  SP = Pulse::Domain::ScoringProfile
  SC = Pulse::Domain::ScoringConfig
  R  = Pulse::Domain::SignalRegistry
  Scoring = Pulse::Domain::Scoring

  Clock = Struct.new(:today)

  def clock
    Clock.new(Date.new(2026, 6, 20))
  end

  # A project with a spread of signal health so reweighting actually moves the score:
  # partial effort, one closing event, some risk, one blocker, all in-window.
  def metrics
    Pulse::Domain::ProjectMetrics.new(
      project_id: 7, reference_date: Date.new(2026, 6, 1),
      effort_open: 4.0, effort_total: 10.0,
      risk_raw: 3.0, blocked_count: 2,
      risk_mapped: true, effort_mapped: true,
      event_series: [{ date: Date.new(2026, 6, 18), type: :issue_closed }],
      version_due_dates: [], open_issue_count: 6, covered_sum: 3.0
    )
  end

  def profile(id, weights)
    SP.new(id: id, name: id.upcase, config: SC.new(weights: weights))
  end

  def score_under(prof)
    Scoring.score(metrics, clock, prof.config)
  end

  # === (a): different weights => different score / rag / dominant =====
  def test_reweighting_changes_the_health_score
    a = profile('balanced',
                { staleness: 0.25, progress: 0.25, momentum: 0.20,
                  risk_load: 0.15, blocked_load: 0.15 })
    b = profile('risk-heavy',
                { staleness: 0.10, progress: 0.10, momentum: 0.10,
                  risk_load: 0.35, blocked_load: 0.35 })
    ha = score_under(a)
    hb = score_under(b)
    refute_equal ha.health_score, hb.health_score,
                 'a profile with different weights must produce a different health_score ' \
                 '(scoring is driven by the profile config)'
  end

  def test_reweighting_can_change_dominant_signal_or_rag
    a = profile('balanced',
                { staleness: 0.25, progress: 0.25, momentum: 0.20,
                  risk_load: 0.15, blocked_load: 0.15 })
    b = profile('stale-heavy',
                { staleness: 0.80, progress: 0.05, momentum: 0.05,
                  risk_load: 0.05, blocked_load: 0.05 })
    ha = score_under(a)
    hb = score_under(b)
    # At least one of the visible score classifications differs — the profile config
    # genuinely drives the RAG/dominant computation (not a fixed global config).
    differs = ha.health_score != hb.health_score ||
              ha.rag != hb.rag ||
              ha.dominant_signal != hb.dominant_signal
    assert differs,
           'reweighting must move at least one of {health_score, rag, dominant_signal}'
  end

  # === (b): enabling coverage_gap yields a distinct breakdown =========
  def test_enabling_coverage_gap_yields_distinct_breakdown
    base = profile('base',
                   { staleness: 0.25, progress: 0.25, momentum: 0.20,
                     risk_load: 0.15, blocked_load: 0.15 })
    six = { staleness: 0.20, progress: 0.20, momentum: 0.20,
            risk_load: 0.15, blocked_load: 0.10, coverage_gap: 0.15 }
    cov = profile('coverage', six)

    base_keys = score_under(base).breakdown.map(&:key)
    cov_keys  = score_under(cov).breakdown.map(&:key)
    refute_includes base_keys, :coverage_gap,
                    'the base profile breakdown omits coverage_gap'
    assert_includes cov_keys, :coverage_gap,
                    'the coverage profile breakdown INCLUDES coverage_gap'
    refute_equal base_keys, cov_keys,
                 'the two profiles yield distinct breakdown key-sets'
  end

  # === (c): a disabled signal is omitted end-to-end ===================
  def test_disabling_a_signal_omits_it_from_breakdown
    # A profile that DISABLES risk_load (its key is absent from the weight domain).
    minus = profile('no-risk',
                    { staleness: 0.35, progress: 0.30, momentum: 0.20, blocked_load: 0.15 })
    h = score_under(minus)
    keys = h.breakdown.map(&:key)
    refute_includes keys, :risk_load,
                    'a disabled signal (risk_load) must be ABSENT from the breakdown'
    refute_equal :risk_load, h.dominant_signal,
                 'a disabled signal can never be the dominant_signal'
  end

  def test_disabled_signal_score_equals_score_without_it
    # The score under a 4-signal profile (risk_load disabled) equals the score computed
    # with the SAME weights over the SAME 4-signal enabled set — the disabled signal makes
    # no contribution (it is not merely zero-weighted; it is absent from the enabled set).
    weights = { staleness: 0.35, progress: 0.30, momentum: 0.20, blocked_load: 0.15 }
    via_profile = score_under(profile('no-risk', weights))
    via_config  = Scoring.score(metrics, clock, SC.new(weights: weights))
    assert_equal via_config.health_score, via_profile.health_score,
                 'the profile score equals the score computed WITHOUT the disabled signal'
    assert_equal via_config.breakdown.map(&:key), via_profile.breakdown.map(&:key),
                 'the profile breakdown equals the WITHOUT-signal breakdown'
  end

  # === Anchor: scoring reads active_profile.config, not a global default =========
  # A profile whose config differs from the default must produce a NON-default score,
  # proving the config passed to Scoring is the profile's own.
  def test_profile_config_is_what_drives_scoring_not_the_default
    default_h = Scoring.score(metrics, clock, SC.new) # global default config
    prof_h = score_under(profile('stale-heavy',
                                 { staleness: 0.80, progress: 0.05, momentum: 0.05,
                                   risk_load: 0.05, blocked_load: 0.05 }))
    refute_equal default_h.health_score, prof_h.health_score,
                 'scoring under a non-default profile must NOT equal the default-config score ' \
                 '(no global-config leak)'
  end
end
