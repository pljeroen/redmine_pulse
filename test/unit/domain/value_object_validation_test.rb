# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'
require 'pulse/domain/scoring_config'
require 'pulse/domain/signals'
require 'pulse/domain/scoring'

# Value-object hardening tests. Pins the value-object fail-loud and deep-immutability
# (immutable value objects + deterministic scoring) guarantees that the original
# behavioural tests did not cover:
#
#   * ProjectMetrics full field validation (ArgumentError on bad input)
#   * ProjectMetrics deep immutability (defensive copy + deep freeze)
#   * ScoringConfig weight-set validity: the enabled set is dom(weights); a non-empty
#     registered SUBSET summing to 1.0 with a positive always-active intersection is valid.
class ValueObjectValidationTest < Minitest::Test
  # ---- builders -----------------------------------------------------------
  def valid_metrics_args(**overrides)
    {
      project_id: 11,
      reference_date: Date.new(2026, 1, 21),
      effort_open: 7.0,
      effort_total: 10.0,
      risk_raw: 40.0,
      blocked_count: 12,
      risk_mapped: true,
      effort_mapped: true,
      event_series: [{ date: Date.new(2026, 6, 10), type: :issue_closed }],
      version_due_dates: [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }],
      # coverage inputs. A non-zero pair exercises covered_sum
      # validation on the happy path (0 <= covered_sum <= open_issue_count).
      open_issue_count: 12,
      covered_sum: 6.0
    }.merge(overrides)
  end

  def build_metrics(**overrides)
    Pulse::Domain::ProjectMetrics.new(**valid_metrics_args(**overrides))
  end

  def valid_weights
    { staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15 }
  end

  # =====================================================================
  # ProjectMetrics full fail-loud field validation.
  # project_id Integer; reference_date Date NON-NIL; effort_open/effort_total/
  # risk_raw Numeric >= 0; blocked_count Integer >= 0; risk_mapped/effort_mapped Boolean;
  # event_series entries {date: Date, type: in [:issue_created,:issue_closed]};
  # version_due_dates entries {version_id: Integer, due_date: Date}.
  # =====================================================================

  def test_rejects_negative_effort_open
    assert_raises(ArgumentError) { build_metrics(effort_open: -1.0) }
  end

  def test_rejects_negative_effort_total
    assert_raises(ArgumentError) { build_metrics(effort_total: -0.01) }
  end

  def test_rejects_negative_risk_raw
    assert_raises(ArgumentError) { build_metrics(risk_raw: -5.0) }
  end

  def test_rejects_negative_blocked_count
    assert_raises(ArgumentError) { build_metrics(blocked_count: -1) }
  end

  def test_rejects_nil_effort_open
    assert_raises(ArgumentError) { build_metrics(effort_open: nil) }
  end

  def test_rejects_non_date_reference_date
    # A String must not pass for a Date field (probe showed it currently does).
    assert_raises(ArgumentError) { build_metrics(reference_date: '2026-01-21') }
  end

  def test_rejects_non_integer_project_id
    assert_raises(ArgumentError) { build_metrics(project_id: '11') }
    assert_raises(ArgumentError) { build_metrics(project_id: 11.0) }
  end

  def test_rejects_non_integer_blocked_count
    assert_raises(ArgumentError) { build_metrics(blocked_count: 12.0) }
  end

  def test_rejects_non_boolean_risk_mapped
    assert_raises(ArgumentError) { build_metrics(risk_mapped: nil) }
    assert_raises(ArgumentError) { build_metrics(risk_mapped: 'yes') }
  end

  def test_rejects_non_boolean_effort_mapped
    assert_raises(ArgumentError) { build_metrics(effort_mapped: 1) }
  end

  def test_rejects_non_numeric_effort_total
    assert_raises(ArgumentError) { build_metrics(effort_total: '10') }
  end

  def test_rejects_event_series_entry_with_non_date_date
    bad = [{ date: '2026-06-10', type: :issue_closed }]
    assert_raises(ArgumentError) { build_metrics(event_series: bad) }
  end

  def test_rejects_event_series_entry_with_unknown_type
    bad = [{ date: Date.new(2026, 6, 10), type: :issue_reopened }]
    assert_raises(ArgumentError) { build_metrics(event_series: bad) }
  end

  # --- EVENT_TYPES broadened to include :issue_commented + :commit ---
  # The fail-loud validation auto-covers the new symbols (positive controls); an unknown
  # type is still rejected (the negative control above).
  def test_accepts_event_series_entry_with_issue_commented_type
    good = [{ date: Date.new(2026, 6, 10), type: :issue_commented }]
    m = build_metrics(event_series: good)
    assert_equal :issue_commented, m.event_series.first[:type]
  end

  def test_accepts_event_series_entry_with_commit_type
    good = [{ date: Date.new(2026, 6, 10), type: :commit }]
    m = build_metrics(event_series: good)
    assert_equal :commit, m.event_series.first[:type]
  end

  def test_rejects_version_due_dates_entry_with_non_date_due_date
    # A Time (not a plain Date) must be rejected (no DateTime/Time/String).
    bad = [{ version_id: 3, name: 'v1.0', due_date: Time.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_rejects_version_due_dates_entry_with_non_integer_version_id
    bad = [{ version_id: '3', name: 'v1.0', due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  # =====================================================================
  # ProjectMetrics#version_due_dates entries MUST carry a REQUIRED non-empty String
  # :name, fail-loud at construction, MIRRORING the version_id (Integer) and due_date
  # (Date) checks — enforced by validate_version_due_dates! in
  # lib/pulse/domain/project_metrics.rb.
  # =====================================================================

  def test_rejects_version_due_dates_entry_missing_name
    bad = [{ version_id: 3, due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_rejects_version_due_dates_entry_with_nil_name
    bad = [{ version_id: 3, name: nil, due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_rejects_version_due_dates_entry_with_non_string_name
    bad = [{ version_id: 3, name: 7, due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_rejects_version_due_dates_entry_with_empty_name
    bad = [{ version_id: 3, name: '', due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_rejects_version_due_dates_entry_with_blank_name
    bad = [{ version_id: 3, name: "  \t ", due_date: Date.new(2026, 7, 1) }]
    assert_raises(ArgumentError) { build_metrics(version_due_dates: bad) }
  end

  def test_accepts_version_due_dates_entry_with_valid_name
    # Positive control: a valid non-empty String :name constructs.
    good = [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }]
    m = build_metrics(version_due_dates: good)
    assert_equal 'v1.0', m.version_due_dates.first[:name]
  end

  def test_accepts_empty_version_due_dates_axis
    # Positive control: empty array needs no :name.
    m = build_metrics(version_due_dates: [])
    assert_equal [], m.version_due_dates
  end

  # =====================================================================
  # ProjectMetrics deep immutability.
  # Caller-owned arrays/hashes must be defensively copied and deep-frozen so a
  # later mutation of the originals cannot change ProjectMetrics state or a
  # subsequent Scoring.score result (deterministic at the value-object boundary).
  # =====================================================================

  class FixedClock
    def initialize(date)
      @date = date
    end

    def today
      @date
    end
  end

  def test_mutating_caller_event_series_array_does_not_change_metrics
    series = [{ date: Date.new(2026, 6, 10), type: :issue_closed }]
    m = build_metrics(event_series: series)
    before = m.event_series.length
    series << { date: Date.new(2026, 6, 11), type: :issue_created } # mutate the ORIGINAL array
    assert_equal before, m.event_series.length,
                 'ProjectMetrics must defensively copy event_series'
  end

  def test_mutating_caller_event_series_element_hash_does_not_change_metrics
    entry = { date: Date.new(2026, 6, 10), type: :issue_closed }
    m = build_metrics(event_series: [entry])
    entry[:type] = :issue_created # mutate the ORIGINAL element hash
    assert_equal :issue_closed, m.event_series.first[:type],
                 'ProjectMetrics must deep-copy event_series element hashes'
  end

  def test_mutating_caller_version_due_dates_does_not_change_metrics
    vd = [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }]
    m = build_metrics(version_due_dates: vd)
    vd << { version_id: 4, name: 'v2.0', due_date: Date.new(2026, 8, 1) }
    vd.first[:version_id] = 999
    assert_equal 1, m.version_due_dates.length
    assert_equal 3, m.version_due_dates.first[:version_id],
                 'ProjectMetrics must deep-copy version_due_dates'
  end

  def test_score_is_stable_after_mutating_caller_event_series
    clock = FixedClock.new(Date.new(2026, 6, 20))
    config = Pulse::Domain::ScoringConfig.new
    # Empty in-window momentum (n == 0.5). Adding three in-window :issue_created events
    # drops momentum n and flips the integer health_score (31 -> 21) IF the array is
    # stored by reference — so this genuinely fails against an aliasing implementation.
    series = []
    m = build_metrics(event_series: series)
    before = Pulse::Domain::Scoring.score(m, clock, config).health_score
    3.times { series << { date: Date.new(2026, 6, 19), type: :issue_created } }
    after = Pulse::Domain::Scoring.score(m, clock, config).health_score
    assert_equal before, after,
                 'subsequent Scoring.score must be unaffected by caller mutation (deterministic)'
  end

  def test_exposed_event_series_collection_is_frozen
    m = build_metrics(event_series: [{ date: Date.new(2026, 6, 10), type: :issue_closed }])
    assert m.event_series.frozen?, 'exposed event_series must be frozen'
    assert_raises(FrozenError) { m.event_series << { date: Date.new(2026, 6, 11), type: :issue_created } }
  end

  def test_exposed_event_series_element_hashes_are_frozen
    m = build_metrics(event_series: [{ date: Date.new(2026, 6, 10), type: :issue_closed }])
    assert m.event_series.first.frozen?, 'event_series element hashes must be frozen'
    assert_raises(FrozenError) { m.event_series.first[:type] = :issue_created }
  end

  def test_exposed_version_due_dates_collection_is_frozen
    m = build_metrics(version_due_dates: [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }])
    assert m.version_due_dates.frozen?, 'exposed version_due_dates must be frozen'
    assert_raises(FrozenError) { m.version_due_dates << { version_id: 4, name: 'v2.0', due_date: Date.new(2026, 8, 1) } }
    assert_raises(FrozenError) { m.version_due_dates.first[:version_id] = 999 }
  end

  # --- version_due_dates :name String is frozen (deep-freeze) ---
  # Uses +"..." (mutable String) so the assertion fails against an implementation that does
  # not deep-freeze, regardless of frozen_string_literal: true in this file.
  def test_version_due_dates_name_string_is_frozen
    m = build_metrics(version_due_dates: [{ version_id: 3, name: +'v1.0', due_date: Date.new(2026, 7, 1) }])
    assert m.version_due_dates.first[:name].frozen?,
           'version_due_dates entry :name must be a frozen String (deep-freeze)'
  end

  def test_caller_mutation_of_version_due_dates_name_string_does_not_change_metrics
    orig_name = +'v1.0'  # mutable String
    vd = [{ version_id: 3, name: orig_name, due_date: Date.new(2026, 7, 1) }]
    m = build_metrics(version_due_dates: vd)
    orig_name << '-MUTATED'
    assert_equal 'v1.0', m.version_due_dates.first[:name],
                 'ProjectMetrics must defensively copy :name Strings — caller mutation must not reach stored entry'
  end

  # =====================================================================
  # ScoringConfig weight-set validity.
  # The ENABLED set is the DOMAIN of weights: a NON-EMPTY SUBSET of the REGISTERED
  # signals is VALID, provided the weights sum to 1.0 (±1e-9) and the enabled ∩
  # always-active weight-sum is > 0. So a proper subset does not fail loud. The
  # still-invalid cases are: empty weights; an UNREGISTERED key; a sum != 1.0; and a
  # subset whose always-active intersection weight-sum is 0.
  # =====================================================================

  def test_accepts_valid_subset_of_registered_signals
    # a 3-signal subset (all registered, sum 1.0, includes always-active
    # staleness/momentum/blocked_load) is VALID — it does NOT raise. The enabled set is
    # dom(weights); construction succeeds and enabled_signals == the weight keys.
    w = { staleness: 0.5, momentum: 0.25, blocked_load: 0.25 }
    assert_in_delta 1.0, w.values.sum, 1e-9
    cfg = Pulse::Domain::ScoringConfig.new(weights: w)
    assert_equal %i[staleness momentum blocked_load].sort, cfg.enabled_signals.sort,
                 'enabled_signals == dom(weights) for a valid subset'
  end

  def test_rejects_empty_weights
    # an EMPTY weights hash is not a valid (non-empty) enabled set.
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: {}) }
  end

  def test_rejects_weights_subset_summing_not_to_one
    # a subset that does NOT sum to 1.0 (±1e-9) still fails loud.
    w = { staleness: 0.30, progress: 0.30, momentum: 0.25 } # Σ 0.85 != 1.0
    refute_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_subset_with_zero_always_active_weight
    # an enabled subset {progress, risk_load} whose
    # always-active intersection is EMPTY (weight-sum 0) still fails loud — otherwise
    # the active set could be empty and completeness divide-by-zero.
    w = { progress: 0.5, risk_load: 0.5 } # neither is always-active
    assert_in_delta 1.0, w.values.sum, 1e-9
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_weights_with_extra_bogus_key
    # an UNREGISTERED weight key (not in the SignalRegistry) still fails loud.
    w = valid_weights.merge(bogus: 0.0)
    assert_in_delta 1.0, w.values.select { |v| v }.sum, 1e-9
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_weights_with_nil_value
    w = valid_weights.merge(blocked_load: nil)
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_weights_with_non_numeric_value
    w = valid_weights.merge(risk_load: '0.15')
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  # =====================================================================
  # ProjectMetrics non-finite / unordered Numeric fail-loud.
  # effort_open/effort_total/risk_raw must be FINITE REAL Numeric >= 0.
  # Float::NAN is Numeric but (NaN < 0) is false, so the naive `return unless value < 0`
  # check lets it through; Float::INFINITY likewise passes. A Complex is Numeric but
  # UNORDERED, so `value < 0` raises NoMethodError instead of the required ArgumentError.
  # All of these are invalid states and MUST raise ArgumentError at
  # construction (NOT NoMethodError, NOT FloatDomainError, NOT silently construct).
  # =====================================================================

  def test_rejects_nan_effort_open
    assert_raises(ArgumentError) { build_metrics(effort_open: Float::NAN) }
  end

  def test_rejects_nan_effort_total
    assert_raises(ArgumentError) { build_metrics(effort_total: Float::NAN) }
  end

  def test_rejects_nan_risk_raw
    assert_raises(ArgumentError) { build_metrics(risk_raw: Float::NAN) }
  end

  def test_rejects_infinity_effort_open
    assert_raises(ArgumentError) { build_metrics(effort_open: Float::INFINITY) }
  end

  def test_rejects_infinity_effort_total
    assert_raises(ArgumentError) { build_metrics(effort_total: Float::INFINITY) }
  end

  def test_rejects_infinity_risk_raw
    assert_raises(ArgumentError) { build_metrics(risk_raw: Float::INFINITY) }
  end

  def test_rejects_complex_effort_open
    # Complex is Numeric but unordered: `< 0` must NOT leak NoMethodError.
    assert_raises(ArgumentError) { build_metrics(effort_open: Complex(1, 2)) }
  end

  def test_rejects_complex_effort_total
    assert_raises(ArgumentError) { build_metrics(effort_total: Complex(1, 2)) }
  end

  def test_rejects_complex_risk_raw
    assert_raises(ArgumentError) { build_metrics(risk_raw: Complex(1, 2)) }
  end

  # =====================================================================
  # ScoringConfig non-finite / unordered Numeric weight fail-loud.
  # Each weight must be a FINITE REAL numeric. A Float::NAN weight makes the
  # sum NaN, and (NaN - 1.0).abs >= 1e-9 is false, so the naive sum check lets it
  # through. A Complex weight is Numeric but unordered: when its real part keeps the
  # sum at 1.0 it reaches `w < 0.0` and raises NoMethodError instead of ArgumentError.
  # Both MUST raise ArgumentError at construction.
  # =====================================================================

  def test_rejects_nan_weight
    # NaN weight => sum is NaN; the tolerance check must reject it as ArgumentError.
    w = valid_weights.merge(staleness: Float::NAN)
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_complex_weight
    # Complex real part keeps the nominal sum == 1.0 so it reaches the `< 0.0`
    # comparison — which must NOT leak NoMethodError; it must be ArgumentError.
    w = valid_weights.merge(staleness: Complex(0.25, 0))
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  def test_rejects_infinity_weight
    w = valid_weights.merge(staleness: Float::INFINITY)
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(weights: w) }
  end

  # =====================================================================
  # ScoringConfig non-weight field fail-loud validation.
  # rag_green_min, rag_amber_min, h_stale, h_risk, h_blocked and activity_window_days
  # are Integer configuration fields. Accepting strings/nil/Float for these either
  # crashes later in Scoring.score (Integer/String comparison, Date arithmetic) or
  # silently distorts the formulas (to_f / zero-like behaviour). They MUST fail loud
  # (ArgumentError) at construction at the value-object boundary.
  #   * all six are Integer.
  #   * h_stale/h_risk/h_blocked are denominators in n = 1 - x/H  => must be > 0.
  #   * activity_window_days is the window size                   => must be > 0.
  #   * coherent RAG bands require rag_green_min >= rag_amber_min, both in [0,100].
  # =====================================================================

  NON_WEIGHT_INTEGER_FIELDS = %i[
    rag_green_min rag_amber_min h_stale h_risk h_blocked activity_window_days
  ].freeze

  # ---- TYPE / nil: each field must be a plain Integer ----
  def test_rejects_string_for_each_non_weight_field
    NON_WEIGHT_INTEGER_FIELDS.each do |field|
      assert_raises(ArgumentError, "#{field}='30' must raise") do
        Pulse::Domain::ScoringConfig.new(field => '30')
      end
    end
  end

  def test_rejects_nil_for_each_non_weight_field
    NON_WEIGHT_INTEGER_FIELDS.each do |field|
      assert_raises(ArgumentError, "#{field}=nil must raise") do
        Pulse::Domain::ScoringConfig.new(field => nil)
      end
    end
  end

  def test_rejects_float_for_each_non_weight_field
    # A Float (even an integral-valued one like 30.5) is NOT an Integer.
    NON_WEIGHT_INTEGER_FIELDS.each do |field|
      assert_raises(ArgumentError, "#{field}=30.5 must raise") do
        Pulse::Domain::ScoringConfig.new(field => 30.5)
      end
    end
  end

  # ---- RANGE: horizons are denominators => must be > 0 ----
  def test_rejects_zero_horizons
    %i[h_stale h_risk h_blocked].each do |field|
      assert_raises(ArgumentError, "#{field}=0 must raise (divisor)") do
        Pulse::Domain::ScoringConfig.new(field => 0)
      end
    end
  end

  def test_rejects_negative_horizons
    %i[h_stale h_risk h_blocked].each do |field|
      assert_raises(ArgumentError, "#{field}=-1 must raise (divisor)") do
        Pulse::Domain::ScoringConfig.new(field => -1)
      end
    end
  end

  # ---- RANGE: activity_window_days is the window size => must be > 0 ----
  def test_rejects_zero_activity_window_days
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(activity_window_days: 0) }
  end

  def test_rejects_negative_activity_window_days
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(activity_window_days: -5) }
  end

  # ---- RANGE: RAG band bounds must be in [0,100] ----
  def test_rejects_rag_green_min_out_of_range
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(rag_green_min: -1) }
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(rag_green_min: 101) }
  end

  def test_rejects_rag_amber_min_out_of_range
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(rag_amber_min: -1) }
    assert_raises(ArgumentError) { Pulse::Domain::ScoringConfig.new(rag_amber_min: 101) }
  end

  # ---- RANGE: incoherent ordering rag_amber_min > rag_green_min ----
  def test_rejects_incoherent_rag_band_ordering
    # amber band would be empty/inverted: green_min must be >= amber_min for coherent bands.
    assert_raises(ArgumentError) do
      Pulse::Domain::ScoringConfig.new(rag_green_min: 40, rag_amber_min: 60)
    end
  end

  # ---- POSITIVE CONTROL: defaults and a valid custom config still construct ----
  def test_defaults_construct_with_valid_non_weight_fields
    cfg = Pulse::Domain::ScoringConfig.new
    assert_equal 67, cfg.rag_green_min
    assert_equal 34, cfg.rag_amber_min
    assert_equal 180, cfg.h_stale
    assert_equal 50, cfg.h_risk
    assert_equal 20, cfg.h_blocked
    assert_equal 30, cfg.activity_window_days
  end

  def test_valid_custom_non_weight_config_constructs
    cfg = Pulse::Domain::ScoringConfig.new(
      rag_green_min: 80, rag_amber_min: 50,
      h_stale: 90, h_risk: 25, h_blocked: 10, activity_window_days: 14
    )
    assert_equal 80, cfg.rag_green_min
    assert_equal 50, cfg.rag_amber_min
    assert_equal 90, cfg.h_stale
    assert_equal 25, cfg.h_risk
    assert_equal 10, cfg.h_blocked
    assert_equal 14, cfg.activity_window_days
    # boundary-coherent equal bounds are allowed (green_min == amber_min).
    refute_nil Pulse::Domain::ScoringConfig.new(rag_green_min: 50, rag_amber_min: 50)
  end
end
