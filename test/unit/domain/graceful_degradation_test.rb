# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# FR-10, FR-16, FR-32, FR-33 / FC-10, FC-11, FC-16, FC-19, FC-26.
# Graceful degradation: inactive signals present (active:false, nil numerics),
# weight redistributed, signal_completeness 0.8/0.6, dominant_signal never nil.
class GracefulDegradationTest < Minitest::Test
  include ScoringSupport

  def test_progress_zero_denominator_inactive
    # blocked_count:1 keeps the project NON-EMPTY (a real blocker) so it is a minimal-active
    # project, NOT the no-data state (THAW-RA-001 no_data? now keys on per-project risk_raw==0,
    # not the global risk_mapped flag). progress stays inactive (effort_total==0); the
    # always-active signals (incl. blocked_load) renormalize over the active set.
    h = Pulse::Domain::Scoring.score(
      metrics(effort_open: 0.0, effort_total: 0.0, blocked_count: 1), fixed_clock, config)
    prog = signal(h, :progress)
    refute prog.active
    assert_nil prog.raw_value
    assert_nil prog.n
    assert_nil prog.effective_weight
    assert_nil prog.contribution
    # active weights still renormalize to 1.0.
    assert_in_delta 1.0, h.breakdown.select(&:active).sum(&:effective_weight), 1e-9
  end

  def test_risk_load_inactive_when_unmapped
    h = Pulse::Domain::Scoring.score(metrics(risk_mapped: false, effort_total: 10.0, effort_open: 1.0),
                                     fixed_clock, config)
    risk = signal(h, :risk_load)
    refute risk.active
    assert_nil risk.raw_value
    assert_nil risk.effective_weight
    assert_nil risk.contribution
    assert_in_delta 1.0, h.breakdown.select(&:active).sum(&:effective_weight), 1e-9
  end

  def test_inactive_signals_present_not_omitted
    # blocked_count:1 keeps the project NON-EMPTY (real blocker) so it is a minimal-active
    # project (3 always-active signals), NOT the no-data state (THAW-RA-001): the
    # always-active signals are genuinely active and present here.
    h = Pulse::Domain::Scoring.score(
      metrics(risk_mapped: false, effort_total: 0.0, effort_open: 0.0, blocked_count: 1),
      fixed_clock, config)
    assert_equal 5, h.breakdown.length, 'breakdown always length 5'
    assert_equal ScoringSupport::CANONICAL_ORDER, h.breakdown.map(&:key)
    # progress + risk_load inactive but PRESENT.
    refute signal(h, :progress).active
    refute signal(h, :risk_load).active
    # always-active still active.
    assert signal(h, :staleness).active
    assert signal(h, :momentum).active
    assert signal(h, :blocked_load).active
  end

  def test_standard_fields_only_valid_score
    # risk unmapped, progress active (effort_total>0): completeness 0.8.
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    assert_kind_of Integer, h.health_score
    assert_operator h.health_score, :>=, 0
    assert_operator h.health_score, :<=, 100
    assert_in_delta 0.8, h.signal_completeness, 1e-12
    refute_nil h.dominant_signal
    assert signal(h, :staleness).active
    assert signal(h, :momentum).active
    assert signal(h, :blocked_load).active
    refute signal(h, :risk_load).active
  end

  def test_standard_fields_only_progress_inactive_completeness_06
    # blocked_count:1 => non-empty minimal-active project (NOT no-data; THAW-RA-001):
    # 3 always-active signals, progress + risk inactive => completeness 0.6, dominant set.
    h = Pulse::Domain::Scoring.score(
      metrics(risk_mapped: false, effort_total: 0.0, effort_open: 0.0, blocked_count: 1),
      fixed_clock, config)
    assert_in_delta 0.6, h.signal_completeness, 1e-12
    refute_nil h.dominant_signal
    assert_includes ScoringSupport::CANONICAL_ORDER, h.dominant_signal
  end

  def test_dominant_signal_never_nil_minimal_active_set
    # 3 always-active signals only (progress + risk inactive), all n high -> dominant still
    # set. All three active n==1 => the argmin worst is staleness (canonical tie), but its
    # n 1.0 >= ON_TRACK_THRESHOLD (0.5) so it collapses to :on_track (momentum-broaden D2).
    # Still NEVER nil — :on_track is a non-nil dominant.
    h = Pulse::Domain::Scoring.score(
      metrics(risk_mapped: false, effort_total: 0.0, effort_open: 0.0,
              reference_date: ScoringSupport::TODAY, blocked_count: 0,
              event_series: events_for(opened: 0, closed: 50)), fixed_clock, config
    )
    refute_nil h.dominant_signal
    assert_equal :on_track, h.dominant_signal
  end

  def test_dominant_signal_named_argmin_minimal_active_set_below_threshold
    # Same minimal active set (progress + risk inactive => 3 always-active signals), but the
    # worst active signal is BELOW the on_track threshold, so the NAMED argmin result is
    # returned (the never-nil-argmin path stays covered without collapsing to :on_track).
    # blocked_count 15 => n 1-15/20 = 0.25 (worst, < 0.5); staleness fresh (n 1.0); momentum
    # busy net-closing (n high). argmin => :blocked_load.
    h = Pulse::Domain::Scoring.score(
      metrics(risk_mapped: false, effort_total: 0.0, effort_open: 0.0,
              reference_date: ScoringSupport::TODAY, blocked_count: 15,
              event_series: events_for(opened: 0, closed: 50)), fixed_clock, config
    )
    refute_nil h.dominant_signal
    assert_operator signal(h, :blocked_load).n, :<, 0.5
    assert_equal :blocked_load, h.dominant_signal
  end
end
