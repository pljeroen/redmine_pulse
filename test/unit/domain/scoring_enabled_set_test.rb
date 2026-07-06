# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'pulse/domain/signal_registry'

# FR-C1-05 / FC-C1-10 (dominant severity-first over enabled active in canonical order,
#   tie -> earliest canonical, on_track override preserved) and
# FR-C1-06 / FC-C1-11 (breakdown one-per-enabled in canonical order restricted to E;
#   disabled signals OMITTED entirely; |breakdown| == |E|).
#
# RED NOW: enabled_signals: kwarg / SignalRegistry are absent, and the current Scoring
# iterates the fixed CANONICAL_ORDER of 5 -> a 3-enabled config still yields 5 breakdown
# rows / can name a disabled dominant. GREEN after A9 drives off the enabled set.
class ScoringEnabledSetTest < Minitest::Test
  include ScoringSupport

  def cfg(enabled, weights, **over)
    Pulse::Domain::ScoringConfig.new(enabled_signals: enabled, weights: weights, **over)
  end

  def score(metrics, config)
    Pulse::Domain::Scoring.score(metrics, fixed_clock, config)
  end

  # === FC-C1-11: breakdown is one-per-enabled, canonical order, disabled omitted
  def test_breakdown_default_canonical_order
    h = score(kernel_aios_metrics, Pulse::Domain::ScoringConfig.new)
    assert_equal %i[staleness progress momentum risk_load blocked_load],
                 h.breakdown.map(&:key), 'default breakdown canonical order (pre-C1 identical)'
  end

  def test_breakdown_one_per_enabled_signal
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    m = metrics(reference_date: ScoringSupport::TODAY - 30, blocked_count: 4,
                event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg(enabled, w))
    assert_equal 3, h.breakdown.size, '|breakdown| == |enabled|'
  end

  def test_breakdown_canonical_order_restricted_to_enabled
    # enable a non-contiguous canonical subset {staleness, momentum, blocked_load}:
    # order must be staleness -> momentum -> blocked_load (canonical, progress/risk_load omitted).
    enabled = %i[blocked_load staleness momentum] # deliberately unsorted input order
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    m = metrics(reference_date: ScoringSupport::TODAY - 30, blocked_count: 4,
                event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg(enabled, w))
    assert_equal %i[staleness momentum blocked_load], h.breakdown.map(&:key),
                 'breakdown ordered by registry canonical_order restricted to E'
  end

  def test_disabled_signal_omitted_from_breakdown
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    m = metrics(reference_date: ScoringSupport::TODAY - 30, blocked_count: 4,
                effort_open: 5.0, effort_total: 10.0, risk_raw: 10.0, risk_mapped: true,
                event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg(enabled, w))
    keys = h.breakdown.map(&:key)
    refute_includes keys, :progress, 'disabled progress omitted (not emitted inactive)'
    refute_includes keys, :risk_load, 'disabled risk_load omitted'
  end

  # === FC-C1-10: dominant iterates enabled set, tie -> earliest canonical =====
  def test_dominant_iterates_only_enabled_active
    # A disabled signal that WOULD have been the worst must not be selected.
    # risk_load has the worst n (very high risk_raw) but is DISABLED -> dominant is
    # the worst among the enabled {staleness, momentum, blocked_load}.
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    m = metrics(reference_date: ScoringSupport::TODAY - 90, # staleness n = 1 - 90/180 = 0.5
                risk_raw: 49.0, risk_mapped: true, # risk_load worst but disabled
                blocked_count: 4, # blocked n = 1 - 4/20 = 0.8
                event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg(enabled, w))
    refute_equal :risk_load, h.dominant_signal, 'a disabled signal can never be dominant'
    assert_includes enabled + [:on_track], h.dominant_signal
  end

  def test_dominant_tie_resolves_to_earliest_canonical_over_enabled
    # staleness n = 1 - 108/180 = 0.4 ; blocked_load n = 1 - 12/20 = 0.4 (tie).
    # both enabled; earliest canonical (staleness) wins. on_track_threshold is the
    # DEFAULT 0.5 (ABOVE 0.4), so — since the override is INCLUSIVE (n >= threshold ->
    # :on_track) — 0.4 < 0.5 is a NAMED concern, not on_track.
    enabled = %i[staleness blocked_load]
    w = { staleness: 0.5, blocked_load: 0.5 }
    m = metrics(reference_date: ScoringSupport::TODAY - 108, blocked_count: 12,
                event_series: [])
    h = score(m, cfg(enabled, w))
    assert_equal :staleness, h.dominant_signal, 'equal-n tie -> earliest canonical-order (staleness)'
  end

  # === A10-C1-001 (FC-C1-12): no-data breakdown tracks the ENABLED set ==========
  # PRE-fix, no_data_result ignored the config and always emitted the 5 canonical keys.
  # Under C1 a NON-DEFAULT 3-signal enabled config must yield a 3-row no-data breakdown
  # (exactly the enabled signals, canonical order, all inactive) — NOT 5 rows.
  def test_no_data_breakdown_tracks_non_default_enabled_set
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.25, blocked_load: 0.25 }
    # No-data input: no effort (total 0), empty event_series, blocked 0, risk_raw 0.
    m = metrics(effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0,
                blocked_count: 0, event_series: [])
    h = score(m, cfg(enabled, w))

    assert_equal :no_data, h.rag, 'no-data input -> rag :no_data'
    assert_nil h.health_score, 'no-data -> health_score nil'
    assert_equal 0.0, h.signal_completeness, 'no-data -> completeness 0.0'

    assert_equal 3, h.breakdown.size, 'no-data breakdown == |enabled| (3), NOT 5'
    assert_equal %i[staleness momentum blocked_load], h.breakdown.map(&:key),
                 'no-data breakdown == enabled signals in canonical order'
    refute_includes h.breakdown.map(&:key), :progress, 'disabled progress not in no-data breakdown'
    refute_includes h.breakdown.map(&:key), :risk_load, 'disabled risk_load not in no-data breakdown'
    assert h.breakdown.none?(&:active), 'every no-data breakdown row is inactive'
  end

  def test_on_track_override_preserved_over_enabled_set
    # all enabled signals healthy (worst n >= on_track_threshold) -> :on_track.
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.4, momentum: 0.3, blocked_load: 0.3 }
    m = metrics(reference_date: ScoringSupport::TODAY - 5, blocked_count: 0,
                event_series: events_for(opened: 1, closed: 20)) # very healthy momentum
    h = score(m, cfg(enabled, w))
    assert_equal :on_track, h.dominant_signal,
                 'worst active n >= on_track_threshold -> :on_track (override preserved)'
  end
end
