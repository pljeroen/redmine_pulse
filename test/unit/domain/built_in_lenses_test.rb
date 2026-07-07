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
require 'pulse/domain/built_in_lenses'

# BuiltInLenses.all — the v1 seed catalog: EXACTLY 2 frozen CustomLens entries, in order:
#   [0] "Delivery risk": {risk_load: 0.5, blocked_load: 0.3, staleness: 0.2}, :asc, threshold nil
#   [1] "Momentum":      {momentum: 0.6, progress: 0.4},                       :asc, threshold nil
# .all is frozen; each entry is a frozen CustomLens; no stale/done/blocked entries; each
# entry is LensRanking-computable (returns Float or nil, never raises).
class BuiltInLensesTest < Minitest::Test
  BIL = Pulse::Domain::BuiltInLenses
  CL = Pulse::Domain::CustomLens
  LR = Pulse::Domain::LensRanking
  SR = Pulse::Domain::SignalResult
  HR = Pulse::Domain::HealthResult

  # === EXACTLY 2 entries; array frozen ===========================
  def test_catalog_has_exactly_two_entries
    assert_equal 2, BIL.all.size
  end

  def test_catalog_array_is_frozen
    assert BIL.all.frozen?, 'BuiltInLenses.all must be a frozen Array'
  end

  def test_every_entry_is_a_frozen_custom_lens
    BIL.all.each do |l|
      assert_instance_of CL, l
      assert l.frozen?, 'each catalog entry must be a frozen CustomLens'
    end
  end

  # === entry [0] "Delivery risk" pinned exactly ==================
  def test_delivery_risk_entry_pinned
    dl = BIL.all[0]
    assert_equal 'Delivery risk', dl.name
    assert_equal({ risk_load: 0.5, blocked_load: 0.3, staleness: 0.2 }, dl.weight_set.to_h)
    assert_equal :asc, dl.sort_direction
    assert_nil dl.threshold
    assert dl.frozen?
  end

  # === entry [1] "Momentum" pinned exactly ======================
  def test_momentum_entry_pinned
    mo = BIL.all[1]
    assert_equal 'Momentum', mo.name
    assert_equal({ momentum: 0.6, progress: 0.4 }, mo.weight_set.to_h)
    assert_equal :asc, mo.sort_direction
    assert_nil mo.threshold
    assert mo.frozen?
  end

  # === no raw-metric (stale/done/blocked) entries =======
  def test_no_raw_metric_lenses_in_catalog
    assert BIL.all.none? { |l| %w[stale done blocked].include?(l.name) },
           'the catalog holds only weighted-signal-score lenses, not raw-metric passthroughs'
    assert BIL.all.none? { |l| %w[stale done blocked].include?(l.name.downcase) }
  end

  # === each entry is LensRanking-computable ============
  # Every catalog lens must be rankable by the same machinery a user/saved-view lens uses:
  # LensRanking.score returns a Float or nil, NEVER raises.
  def test_every_entry_is_lens_ranking_computable_float
    hr = fully_active_health
    c = full_config
    BIL.all.each do |l|
      score = LR.score(l, hr, c)
      assert(score.is_a?(Float) || score.nil?,
             "#{l.name} must be LensRanking-computable (Float or nil), got #{score.inspect}")
      refute_nil score, "#{l.name} over fully-active signals must be a Float (not nil)"
    end
  end

  def test_every_entry_returns_nil_when_all_signals_inactive
    hr = fully_inactive_health
    c = full_config
    BIL.all.each do |l|
      assert_nil LR.score(l, hr, c), "#{l.name} over all-inactive signals must be nil (unrankable)"
    end
  end

  private

  # All six registered signals ACTIVE with n = 0.5. Covers every catalog lens's chosen keys.
  def fully_active_health
    breakdown = Pulse::Domain::SignalRegistry.keys.map do |k|
      SR.new(key: k, active: true, raw_value: 1.0, n: 0.5, effective_weight: 0.2, contribution: 0.1)
    end
    build_health(breakdown)
  end

  def fully_inactive_health
    breakdown = Pulse::Domain::SignalRegistry.keys.map do |k|
      SR.new(key: k, active: false, raw_value: nil, n: nil, effective_weight: nil, contribution: nil)
    end
    build_health(breakdown)
  end

  def build_health(breakdown)
    HR.new(project_id: 1, health_score: 50, rag: :amber, dominant_signal: :staleness,
           signal_completeness: 1.0, breakdown: breakdown,
           lens_keys: { health: 50, at_risk: 50, stale: 0, done: 0, blocked: 0 },
           effort_open: 0.0)
  end

  # A config enabling ALL six registered signals (so no catalog signal is disabled).
  def full_config
    keys = Pulse::Domain::SignalRegistry.keys
    w = keys.each_with_object({}) { |k, acc| acc[k] = 0.0 }
    w[:staleness] = 1.0   # always-active anchor; sum 1.0
    Pulse::Domain::ScoringConfig.new(enabled_signals: keys, weights: w)
  end
end
