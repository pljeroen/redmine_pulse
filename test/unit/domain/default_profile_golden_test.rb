# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'yaml'
require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'

# IT-C4-06 (golden slice) — FR-C4-02 / AC-C4-06 / FC-C4-13 (output-identity via default).
# Scoring under the SYSTEM DEFAULT profile reproduces the pre-C1 output BYTE-IDENTICALLY —
# the default profile's config IS the global ScoringConfig (synthetic, live-read, not a
# drifting copy), so wrapping it in a ScoringProfile named "default" changes NOTHING at the
# output layer. This is the output half of AC-C4-06; the fingerprint half is
# FC-C4-05B-CHECK (test/functional/pulse_profile_cache_partition_test.rb). The standing
# C1/C2 golden gate (backward_compat_golden_test.rb) is the additional compatibility guard.
#
# RED NOW: Pulse::Domain::ScoringProfile is unimplemented -> `require` raises LoadError.
# GREEN after A9. Pure-domain lane: ruby -Itest -Ilib.
class DefaultProfileGoldenTest < Minitest::Test
  include ScoringSupport

  SP = Pulse::Domain::ScoringProfile
  BASELINE = File.expand_path('../../../fixtures/scoring/pre_c1_baseline_full_precision.yaml', __FILE__)

  def baseline
    YAML.safe_load_file(BASELINE)['cases']
  end

  # The global (default) ScoringConfig via the registry-backed default path.
  def global_config
    Pulse::Domain::ScoringConfig.new(
      enabled_signals: Pulse::Domain::SignalRegistry.default_on_keys,
      weights: Pulse::Domain::SignalRegistry.default_weights
    )
  end

  # The SYNTHETIC system default profile: id "default", config == the global config.
  def default_profile
    SP.new(id: 'default', name: 'Default', config: global_config)
  end

  def num(v)
    return nil if v.nil?
    return v if v.is_a?(Integer)
    return Float(v) if v.is_a?(String)

    v
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

  # === FC-C4-13: the default profile config IS the global config =================
  def test_default_profile_config_equals_global_config
    assert_equal global_config.weights, default_profile.config.weights,
                 'the synthetic default profile config carries the global config weights'
    assert_equal global_config.enabled_signals, default_profile.config.enabled_signals,
                 'the default profile enabled set equals the global config enabled set'
  end

  # === FC-C4-13: scoring under the default profile reproduces the pre-C1 baseline =
  def test_default_profile_scoring_is_byte_identical_to_baseline
    cfg = default_profile.config
    baseline.each do |name, row|
      h = Pulse::Domain::Scoring.score(metrics_from(row['inputs']), fixed_clock, cfg)
      exp = row['expected']
      assert_equal exp['project_id'], h.project_id, "#{name}: project_id"
      assert_exact exp['health_score'], h.health_score, "#{name}: health_score (exact)"
      assert_equal exp['rag'].to_sym, h.rag, "#{name}: rag"
      assert_exact sym_or_nil(exp['dominant_signal']), h.dominant_signal, "#{name}: dominant_signal"
      assert_exact num(exp['signal_completeness']), h.signal_completeness,
                   "#{name}: signal_completeness (EXACT)"
      exp_bd = exp['breakdown']
      assert_equal exp_bd.size, h.breakdown.size, "#{name}: breakdown length"
      exp_bd.each_with_index do |es, i|
        s = h.breakdown[i]
        assert_equal es['key'].to_sym, s.key, "#{name}: breakdown[#{i}] key/order"
        assert_exact num(es['contribution']), s.contribution,
                     "#{name}: breakdown[#{i}] contribution (EXACT)"
      end
    end
  end

  # === FC-C4-13: scoring under the default profile == scoring under the global config ===
  def test_default_profile_matches_direct_global_config_scoring
    global = global_config
    via_profile = default_profile.config
    baseline.each do |name, row|
      m = metrics_from(row['inputs'])
      hg = Pulse::Domain::Scoring.score(m, fixed_clock, global)
      hp = Pulse::Domain::Scoring.score(m, fixed_clock, via_profile)
      assert_exact hg.health_score, hp.health_score, "#{name}: default-profile score == global-config score"
      assert_equal hg.rag, hp.rag, "#{name}: default-profile rag == global-config rag"
      assert_exact hg.dominant_signal, hp.dominant_signal, "#{name}: dominant_signal parity"
    end
  end
end
