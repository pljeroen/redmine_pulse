# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'
require 'pulse/domain/scoring_config'
require 'pulse/domain/timeline'
require 'pulse/domain/retrospective_bucket'
require 'pulse/domain/milestone_marker'

# TL-01, TL-02, TL-08, TL-16 / TC-01, TC-02, TC-08, TC-16.
# Full pure-domain composition: a real ProjectMetrics (seeded event_series +
# version_due_dates) + a fixed Clock + a real ScoringConfig produce a frozen
# TimelineResult with concrete bucket counts/boundaries/tallies and forward markers.
# Asserts observable POST-STATE (DbC), not just non-nil. RED until Timeline exists.
class TimelineIntegrationTest < Minitest::Test
  class FixedClock
    attr_reader :today_calls

    def initialize(date)
      @date = date
      @today_calls = 0
    end

    def today
      @today_calls += 1
      @date
    end
  end

  TODAY = Date.new(2026, 6, 20)

  def seeded_metrics
    Pulse::Domain::ProjectMetrics.new(
      project_id: 42,
      reference_date: TODAY,
      effort_open: 3.0, effort_total: 10.0, risk_raw: 5.0,
      blocked_count: 0, risk_mapped: true, effort_mapped: true,
      event_series: [
        { date: TODAY - 1,  type: :issue_created },  # most-recent bucket [today-7, today)
        { date: TODAY - 2,  type: :issue_closed },   # most-recent bucket
        { date: TODAY - 8,  type: :issue_created },  # second-most-recent bucket
        { date: TODAY - 35, type: :issue_closed },   # oldest bucket [today-35, today-28)
        { date: TODAY,      type: :issue_created },   # @ today => NO bucket (excluded)
        { date: TODAY - 40, type: :issue_closed }     # older than window => NO bucket
      ],
      version_due_dates: [
        { version_id: 9, name: 'GA',     due_date: TODAY + 14 },
        { version_id: 4, name: 'Beta',   due_date: TODAY - 3 },   # past-due, kept
        { version_id: 4 + 1, name: 'RC', due_date: TODAY + 14 }    # tie on due_date w/ v9
      ],
      open_issue_count: 0, covered_sum: 0.0 # C2 additive-required (inactive baseline)
    )
  end

  def build
    clock = FixedClock.new(TODAY)
    result = Pulse::Domain::Timeline.build(seeded_metrics, clock, Pulse::Domain::ScoringConfig.new(activity_window_days: 30))
    [result, clock]
  end

  # --- TC-16: frozen result composing retrospective + forward ---
  def test_result_is_frozen_with_frozen_axes
    result, = build
    assert result.frozen?, 'TimelineResult must be frozen'
    assert result.retrospective.frozen?, 'retrospective array must be frozen'
    assert result.forward.frozen?, 'forward array must be frozen'
    assert_raises(FrozenError) { result.retrospective << :x }
    assert_raises(FrozenError) { result.forward << :x }
  end

  # --- TC-02 / TC-16: retrospective length == ceil(30/7) == 5 ---
  def test_retrospective_length_is_five_for_default_window
    result, = build
    assert_equal 5, result.retrospective.length, 'ceil(30/7) == 5 buckets'
  end

  # --- TC-16: forward length == version_due_dates count ---
  def test_forward_length_matches_version_due_dates_count
    result, = build
    assert_equal 3, result.forward.length, 'one marker per version_due_dates entry'
  end

  # --- TC-05 depth: concrete bucket boundaries + tallies (observable post-state) ---
  def test_bucket_boundaries_and_event_tallies_are_concrete
    result, = build
    buckets = result.retrospective
    # oldest-first: index 0 == [today-35, today-28), index 4 == [today-7, today).
    assert_equal TODAY - 35, buckets[0].start[:at]
    assert_equal TODAY - 28, buckets[0].end[:at]
    assert_equal TODAY - 7,  buckets[4].start[:at]
    assert_equal TODAY,      buckets[4].end[:at]
    # tallies: oldest bucket holds the today-35 event; newest holds today-1 + today-2.
    assert_equal 1, buckets[0].event_count, 'oldest bucket holds the today-35 event'
    assert_equal 2, buckets[4].event_count, 'newest bucket holds today-1 + today-2'
    # second-most-recent [today-14, today-7) holds today-8.
    assert_equal 1, buckets[3].event_count, 'today-8 lands in [today-14, today-7)'
    # today + today-40 events are excluded from EVERY bucket.
    assert_equal 4, buckets.sum(&:event_count), 'today and out-of-window events excluded from total'
  end

  # --- TC-16 + TC-12 depth: forward markers concrete, sorted, name present ---
  def test_forward_markers_concrete_sorted_with_name
    result, = build
    fwd = result.forward
    # sorted [due_date ASC, version_id ASC]: Beta(today-3) < v9(today+14) < RC(today+14, vid5)
    assert_equal [4, 5, 9], fwd.map(&:version_id),
                 'sorted by due_date ASC then version_id ASC'
    assert_equal [TODAY - 3, TODAY + 14, TODAY + 14], fwd.map { |mk| mk.due_date[:date] }
    assert_equal %w[Beta RC GA], fwd.map(&:name), 'names passed through in sorted order'
    fwd.each do |mk|
      assert_equal :version_due_date, mk.due_date[:provenance]
      refute_empty mk.name
    end
  end

  # --- TC-01: clock.today is the sole 'now' source ---
  def test_today_read_only_through_injected_clock
    _result, clock = build
    assert_operator clock.today_calls, :>=, 1,
                    'build must obtain the anchor day from the injected clock.today'
  end

  # --- TC-08: deterministic across invocations (deep equality of observable state) ---
  def test_deterministic_deep_equality_across_invocations
    m = seeded_metrics
    cfg = Pulse::Domain::ScoringConfig.new(activity_window_days: 30)
    a = Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), cfg)
    b = Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), cfg)
    assert_equal a.retrospective.map { |x| [x.start[:at], x.end[:at], x.event_count] },
                 b.retrospective.map { |x| [x.start[:at], x.end[:at], x.event_count] }
    assert_equal a.forward.map { |x| [x.version_id, x.name, x.due_date[:date]] },
                 b.forward.map { |x| [x.version_id, x.name, x.due_date[:date]] }
  end
end
