# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'
require 'pulse/domain/scoring_config'
require 'pulse/domain/timeline'
require 'pulse/domain/retrospective_bucket'
require 'pulse/domain/milestone_marker'

# TL-01..TL-06, TL-08 / TC-01..TC-06, TC-08.
# Retrospective bucket construction over the rolling, half-open, today-exclusive,
# oldest-first window (D-TL-A / D-TL-B). RED until Pulse::Domain::Timeline exists.
class TimelineBucketTest < Minitest::Test
  # FixedClock: the SOLE 'now' source the domain may read (TL-01/TL-17). Records its
  # #today call count so we can assert the domain anchors on the injected clock only.
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

  # version_due_dates entries carry :name per D-TL-C (TC-11c); these fixtures keep the
  # forward axis empty unless a test needs it, so name is moot here but supplied valid.
  def metrics(event_series: [], version_due_dates: [], reference_date: TODAY)
    Pulse::Domain::ProjectMetrics.new(
      project_id: 1,
      reference_date: reference_date,
      effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0,
      blocked_count: 0, risk_mapped: true, effort_mapped: true,
      event_series: event_series,
      version_due_dates: version_due_dates
    )
  end

  def config(activity_window_days: 30)
    Pulse::Domain::ScoringConfig.new(activity_window_days: activity_window_days)
  end

  def build(event_series: [], window: 30, today: TODAY, version_due_dates: [])
    clock = FixedClock.new(today)
    result = Pulse::Domain::Timeline.build(
      metrics(event_series: event_series, version_due_dates: version_due_dates),
      clock,
      config(activity_window_days: window)
    )
    [result, clock]
  end

  def ceil_div(w, d)
    (w + d - 1) / d
  end

  # --- TC-02: bucket_count == ceil(W/7), with the edge ladder ---
  def test_bucket_count_ceil_w_over_7_edge_ladder
    ladder = { 1 => 1, 6 => 1, 7 => 1, 8 => 2, 14 => 2, 29 => 5, 30 => 5, 35 => 5, 36 => 6 }
    ladder.each do |w, expected_count|
      result, = build(window: w)
      assert_equal expected_count, result.retrospective.length,
                   "W=#{w} => ceil(W/7)=#{expected_count} buckets"
    end
  end

  def test_bucket_count_equals_integer_ceiling_over_range
    # Property over W in [1..120]: retrospective.length == (W + 6) / 7.
    (1..120).each do |w|
      result, = build(window: w)
      assert_equal ceil_div(w, 7), result.retrospective.length,
                   "W=#{w} bucket count must equal (W+6)/7"
    end
  end

  # --- TC-03: half-open contiguous 7-day boundaries anchored at clock.today,
  #            most-recent == [today-7, today), oldest-first ---
  def test_buckets_are_contiguous_seven_day_half_open_intervals
    w = 30
    result, = build(window: w)
    buckets = result.retrospective
    buckets.each do |b|
      assert_instance_of Date, b.start[:at]
      assert_instance_of Date, b.end[:at]
      refute_kind_of DateTime, b.start[:at], 'boundary must be a plain Date, not DateTime'
      assert_equal 7, (b.end[:at] - b.start[:at]).to_i, 'each bucket spans exactly 7 days'
    end
    # contiguity: bucket[k].end == bucket[k+1].start
    buckets.each_cons(2) do |a, b|
      assert_equal a.end[:at], b.start[:at], 'buckets must be contiguous (no gap/overlap)'
    end
  end

  def test_most_recent_bucket_is_today_minus_7_to_today_exclusive
    result, = build(window: 30)
    most_recent = result.retrospective.last
    assert_equal TODAY - 7, most_recent.start[:at], 'most-recent bucket starts at today-7'
    assert_equal TODAY, most_recent.end[:at],
                 'most-recent bucket ends AT clock.today (exclusive supremum, D-TL-A)'
  end

  def test_oldest_bucket_first_and_oldest_start_anchored
    w = 30
    n = ceil_div(w, 7) # 5
    result, = build(window: w)
    buckets = result.retrospective
    # D-TL-B: retrospective[0] is the OLDEST.
    assert_equal TODAY - 7 * n, buckets.first.start[:at],
                 'oldest bucket (index 0) starts at today - 7*ceil(W/7)'
    # Strictly increasing start dates => index 0 is oldest, last is most recent.
    buckets.each_cons(2) do |a, b|
      assert_operator a.start[:at], :<, b.start[:at],
                      'array must be OLDEST-FIRST (ascending start dates, D-TL-B)'
    end
  end

  # --- TC-01: clock.today is the sole 'now'; swapping today shifts every boundary ---
  def test_today_sourced_only_from_injected_clock
    result_a, clock_a = build(window: 30, today: TODAY)
    result_b, = build(window: 30, today: TODAY + 10)
    assert_operator clock_a.today_calls, :>=, 1,
                    'build must read the anchor day from the injected clock.today'
    # Every boundary in B is shifted by exactly +10 days vs A (boundary is a pure
    # function of the injected today and W).
    result_a.retrospective.each_index do |k|
      assert_equal result_a.retrospective[k].start[:at] + 10,
                   result_b.retrospective[k].start[:at],
                   "bucket[#{k}].start must shift by the clock.today delta"
      assert_equal result_a.retrospective[k].end[:at] + 10,
                   result_b.retrospective[k].end[:at],
                   "bucket[#{k}].end must shift by the clock.today delta"
    end
  end

  # --- TC-05: half-open event membership (start inclusive, end exclusive) ---
  def test_event_at_bucket_start_is_in_that_bucket
    # An event dated exactly the most-recent bucket's start (today-7) is IN it.
    result, = build(event_series: [{ date: TODAY - 7, type: :issue_created }], window: 7)
    most_recent = result.retrospective.last
    assert_equal TODAY - 7, most_recent.start[:at]
    assert_equal 1, most_recent.event_count, 'event @ bucket.start is INCLUSIVE'
  end

  def test_event_at_bucket_end_is_not_in_that_bucket
    # With W=14 there are 2 buckets. An event at the older bucket's end belongs to the
    # NEWER bucket (end is EXCLUSIVE), not the older one.
    result, = build(event_series: [{ date: TODAY - 7, type: :issue_created }], window: 14)
    older = result.retrospective.first      # [today-14, today-7)
    newer = result.retrospective.last       # [today-7, today)
    assert_equal TODAY - 7, older.end[:at]
    assert_equal 0, older.event_count, 'event @ bucket.end is NOT in that (older) bucket'
    assert_equal 1, newer.event_count, 'event @ end-of-older belongs to the next bucket'
  end

  def test_event_dated_exactly_today_is_in_no_bucket
    # D-TL-A: clock.today is the EXCLUSIVE supremum; an event @ today is unbucketed.
    result, = build(event_series: [{ date: TODAY, type: :issue_closed }], window: 30)
    total = result.retrospective.sum(&:event_count)
    assert_equal 0, total, 'event dated exactly clock.today must fall in NO bucket'
  end

  def test_event_older_than_window_is_in_no_bucket
    w = 30
    n = ceil_div(w, 7)
    oldest_start = TODAY - 7 * n
    result, = build(event_series: [{ date: oldest_start - 1, type: :issue_created }], window: w)
    total = result.retrospective.sum(&:event_count)
    assert_equal 0, total, 'event older than the oldest bucket start falls in NO bucket'
  end

  def test_in_window_events_partition_exactly_once
    # Each in-window event lands in exactly one bucket: sum of bucket counts equals the
    # number of event_series entries inside [oldest.start, today).
    w = 30
    series = [
      { date: TODAY - 1,  type: :issue_created },  # newest bucket
      { date: TODAY - 7,  type: :issue_closed },   # boundary -> newest bucket (inclusive start)
      { date: TODAY - 8,  type: :issue_created },  # second-newest bucket
      { date: TODAY - 21, type: :issue_closed }    # an older bucket
    ]
    result, = build(event_series: series, window: w)
    total = result.retrospective.sum(&:event_count)
    assert_equal 4, total, 'every in-window event counted exactly once (no drop, no double-count)'
  end

  # --- momentum-broaden D3 / §8: sparkline counts issue_created/issue_closed ONLY ---
  # event_series now also carries :issue_commented and :commit (consumed by momentum), but
  # the retrospective sparkline MUST keep counting ONLY issue_created/issue_closed. A
  # comment/commit event INSIDE the window must NOT change any bucket count (behaviour-
  # preserving guard). RED until count_events_in gains the issue-events-only type filter.
  def test_sparkline_ignores_issue_commented_and_commit_events
    issue_only = [
      { date: TODAY - 1, type: :issue_created },
      { date: TODAY - 8, type: :issue_closed }
    ]
    with_activity = issue_only + [
      { date: TODAY - 1, type: :issue_commented }, # in-window, MUST NOT be counted
      { date: TODAY - 8, type: :commit }           # in-window, MUST NOT be counted
    ]
    base, = build(event_series: issue_only, window: 30)
    broad, = build(event_series: with_activity, window: 30)

    base_counts  = base.retrospective.map(&:event_count)
    broad_counts = broad.retrospective.map(&:event_count)
    assert_equal base_counts, broad_counts,
                 'sparkline buckets must be UNCHANGED by :issue_commented/:commit events (D3 / §8)'
    assert_equal 2, broad_counts.sum,
                 'only the two issue_created/issue_closed events are bucketed (comment+commit ignored)'
  end

  def test_sparkline_total_ignores_comment_and_commit_only_series
    # A window full of comments/commits and ZERO issue events => every bucket count 0.
    series = [
      { date: TODAY - 1,  type: :issue_commented },
      { date: TODAY - 2,  type: :commit },
      { date: TODAY - 10, type: :issue_commented },
      { date: TODAY - 20, type: :commit }
    ]
    result, = build(event_series: series, window: 30)
    assert_equal 0, result.retrospective.sum(&:event_count),
                 'comment/commit-only series => zero sparkline counts (issue-events-only, §8)'
  end

  # --- TC-06: real zeros, no omission, no smoothing ---
  def test_empty_event_series_yields_real_zero_buckets_no_omission
    w = 30
    result, = build(event_series: [], window: w)
    assert_equal ceil_div(w, 7), result.retrospective.length,
                 'no empty bucket is omitted'
    result.retrospective.each do |b|
      assert_equal 0, b.event_count
      assert_instance_of Integer, b.event_count, 'empty bucket carries a real Integer 0, never nil'
    end
  end

  def test_single_event_does_not_bleed_into_neighbouring_buckets
    # A single event in one bucket => that bucket count == 1, every other bucket == 0
    # (no smoothing / no neighbour interpolation).
    result, = build(event_series: [{ date: TODAY - 8, type: :issue_created }], window: 21)
    counts = result.retrospective.map(&:event_count)
    assert_equal 1, counts.sum, 'exactly one event counted'
    assert_equal 1, counts.count { |c| c == 1 }, 'exactly one bucket holds the event'
    assert_equal counts.length - 1, counts.count { |c| c.zero? }, 'all other buckets are real zero (no bleed)'
  end

  # --- TC-08: retrospective determinism (referential transparency) ---
  def test_retrospective_is_deterministic_across_invocations
    series = [
      { date: TODAY - 1, type: :issue_created },
      { date: TODAY - 9, type: :issue_closed }
    ]
    m = metrics(event_series: series)
    cfg = config(activity_window_days: 30)
    a = Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), cfg).retrospective
    b = Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), cfg).retrospective
    assert_equal a.length, b.length
    a.each_index do |k|
      assert_equal a[k].start[:at], b[k].start[:at]
      assert_equal a[k].end[:at], b[k].end[:at]
      assert_equal a[k].event_count, b[k].event_count
    end
  end

  def test_build_does_not_mutate_inputs
    m = metrics(event_series: [{ date: TODAY - 1, type: :issue_created }])
    cfg = config(activity_window_days: 30)
    assert m.frozen?
    assert cfg.frozen?
    Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), cfg)
    assert m.frozen?, 'metrics must remain frozen/unmutated after build'
    assert cfg.frozen?, 'config must remain frozen/unmutated after build'
  end
end
