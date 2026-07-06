# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'
require 'pulse/domain/signal_registry'

# FR-C1-04 / FC-C1-09 — signal_completeness = active_count / enabled_count.
# The literal /5.0 is generalized to /enabled_count. Boundary identity: on the
# default 5-signal set, active.size/enabled_count is bit-identical to active.size/5.0.
#
# RED NOW: an enabled_signals: kwarg on ScoringConfig / SignalRegistry are absent, and
# the current Scoring divides by a hardcoded 5.0 -> the enabled_count != 5 case fails.
# GREEN after A9 drives completeness off config.enabled_signals.size.
class ScoringCompletenessTest < Minitest::Test
  include ScoringSupport

  R = Pulse::Domain::SignalRegistry

  def score(metrics, cfg)
    Pulse::Domain::Scoring.score(metrics, fixed_clock, cfg)
  end

  # === default E (|E|=5): identical to old active/5.0 =========================
  def test_default_all_active_completeness_is_one
    # kernel_aios: all 5 active -> 5/5 == 1.0.
    h = score(kernel_aios_metrics, Pulse::Domain::ScoringConfig.new)
    assert_equal 1.0, h.signal_completeness, 'all 5 active -> 5/5.0 == 1.0'
  end

  def test_default_four_active_completeness_is_four_fifths
    # pdfree: risk_load INACTIVE -> 4 active of 5 -> 4/5 == 0.8 (bit-identical to /5.0).
    h = score(pdfree_metrics, Pulse::Domain::ScoringConfig.new)
    assert_equal 4 / 5.0, h.signal_completeness, 'default 4-active completeness == 4/5.0 exactly'
  end

  def test_default_completeness_denominator_is_five_for_each_attainable_k
    # progress inactive (no effort) + risk unmapped -> 3 active of the default 5.
    m = metrics(reference_date: ScoringSupport::TODAY - 10,
                effort_open: 0.0, effort_total: 0.0, # progress inactive
                risk_raw: 0.0, blocked_count: 2, risk_mapped: false, # risk inactive
                event_series: events_for(opened: 1, closed: 3))
    h = score(m, Pulse::Domain::ScoringConfig.new)
    assert_equal 3 / 5.0, h.signal_completeness, 'default 3-active -> 3/5.0 exactly'
  end

  # === generalization: enabled_count != 5 (proves NOT hardcoded /5) ===========
  def test_completeness_denominator_is_enabled_count_not_five
    # Enable only {staleness, momentum, blocked_load} (all always-active). With normal
    # data all three are active -> completeness == 3/3 == 1.0, NOT 3/5.0 (=0.6).
    enabled = %i[staleness momentum blocked_load]
    w = { staleness: 0.5, momentum: 0.3, blocked_load: 0.2 }
    cfg = Pulse::Domain::ScoringConfig.new(enabled_signals: enabled, weights: w)
    m = metrics(reference_date: ScoringSupport::TODAY - 30,
                blocked_count: 4, event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg)
    assert_equal 3, h.breakdown.size, 'breakdown emits one per enabled signal (3)'
    refute_equal 3 / 5.0, h.signal_completeness,
                 'completeness must NOT use the hardcoded /5.0 denominator'
    assert_equal 3 / 3.0, h.signal_completeness,
                 'completeness denominator == enabled_count (3), all 3 active -> 1.0'
  end

  def test_completeness_enabled_four_with_partial_active
    # Enable 4 signals {staleness, progress, momentum, blocked_load}; make progress
    # INACTIVE (no effort). 3 of 4 enabled active -> completeness == 3/4 == 0.75.
    enabled = %i[staleness progress momentum blocked_load]
    w = { staleness: 0.3, progress: 0.2, momentum: 0.3, blocked_load: 0.2 }
    cfg = Pulse::Domain::ScoringConfig.new(enabled_signals: enabled, weights: w)
    m = metrics(reference_date: ScoringSupport::TODAY - 30,
                effort_open: 0.0, effort_total: 0.0, # progress inactive
                blocked_count: 4, event_series: events_for(opened: 2, closed: 2))
    h = score(m, cfg)
    assert_equal 4, h.breakdown.size
    assert_equal 3 / 4.0, h.signal_completeness, 'completeness == active(3)/enabled(4) == 0.75'
  end
end
