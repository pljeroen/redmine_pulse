# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'
require 'pulse/domain/scoring_config'
require 'pulse/domain/timeline'
require 'pulse/domain/retrospective_bucket'
require 'pulse/domain/milestone_marker'

# TL-10, TL-12, TL-13 / TC-10, TC-12, TC-13.
# Forward milestone axis: bijective from version_due_dates, empty-when-none, sorted
# [due_date ASC, version_id ASC], NO past-due filtering. RED until Timeline exists.
class TimelineForwardTest < Minitest::Test
  class FixedClock
    def initialize(date)
      @date = date
    end

    def today
      @date
    end
  end

  TODAY = Date.new(2026, 6, 20)

  # version_due_dates entries carry :name per D-TL-C.
  def metrics(version_due_dates:)
    Pulse::Domain::ProjectMetrics.new(
      project_id: 1,
      reference_date: TODAY,
      effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0,
      blocked_count: 0, risk_mapped: true, effort_mapped: true,
      event_series: [],
      version_due_dates: version_due_dates,
      open_issue_count: 0, covered_sum: 0.0 # C2 additive-required (inactive baseline)
    )
  end

  def forward(version_due_dates, today: TODAY)
    Pulse::Domain::Timeline.build(
      metrics(version_due_dates: version_due_dates),
      FixedClock.new(today),
      Pulse::Domain::ScoringConfig.new
    ).forward
  end

  # --- TC-10: empty version_due_dates ⇒ [] (an Array, not nil) ---
  def test_empty_version_due_dates_yields_empty_array
    f = forward([])
    assert_instance_of Array, f
    assert_equal [], f, 'empty version_due_dates => empty forward axis (not nil)'
  end

  # --- TC-10: one marker per entry (bijection, no synthesis, no drop) ---
  def test_forward_is_bijective_with_version_due_dates
    entries = [
      { version_id: 3, name: 'Sprint 3', due_date: TODAY + 5 },
      { version_id: 7, name: 'Sprint 7', due_date: TODAY + 9 }
    ]
    f = forward(entries)
    assert_equal entries.length, f.length, 'exactly one marker per version_due_dates entry'
    source_pairs = entries.map { |e| [e[:version_id], e[:due_date]] }.sort
    marker_pairs = f.map { |mk| [mk.version_id, mk.due_date[:date]] }.sort
    assert_equal source_pairs, marker_pairs, 'each marker corresponds to exactly one source entry'
  end

  def test_single_entry_yields_single_marker
    f = forward([{ version_id: 1, name: 'v1', due_date: TODAY + 1 }])
    assert_equal 1, f.length
    assert_equal 1, f.first.version_id
  end

  # --- TC-12: ordering [due_date ASC, version_id ASC] ---
  def test_forward_sorted_by_due_date_ascending
    entries = [
      { version_id: 1, name: 'late',  due_date: TODAY + 30 },
      { version_id: 2, name: 'soon',  due_date: TODAY + 1 },
      { version_id: 3, name: 'mid',   due_date: TODAY + 10 }
    ]
    f = forward(entries)
    dates = f.map { |mk| mk.due_date[:date] }
    assert_equal dates.sort, dates, 'markers sorted by due_date ASC (soonest first)'
    assert_equal [TODAY + 1, TODAY + 10, TODAY + 30], dates
  end

  def test_tie_break_by_version_id_ascending
    # Two entries with the SAME due_date; version_ids 9 then 3 => order [3, 9].
    entries = [
      { version_id: 9, name: 'b', due_date: TODAY + 5 },
      { version_id: 3, name: 'a', due_date: TODAY + 5 }
    ]
    f = forward(entries)
    assert_equal [3, 9], f.map(&:version_id), 'equal due_date broken by version_id ASC'
  end

  def test_ordering_is_total_and_lexicographic
    entries = [
      { version_id: 5, name: 'e', due_date: TODAY + 2 },
      { version_id: 1, name: 'a', due_date: TODAY + 2 },
      { version_id: 8, name: 'h', due_date: TODAY + 1 }
    ]
    f = forward(entries)
    keys = f.map { |mk| [mk.due_date[:date], mk.version_id] }
    keys.each_cons(2) do |a, b|
      assert_operator((a <=> b), :<=, 0, 'forward must be lexicographically ordered [due_date, version_id]')
    end
  end

  # --- TC-13: NO past-due filtering ---
  def test_past_due_markers_are_not_filtered
    entries = [
      { version_id: 1, name: 'past',   due_date: TODAY - 100 },
      { version_id: 2, name: 'today',  due_date: TODAY },
      { version_id: 3, name: 'future', due_date: TODAY + 100 }
    ]
    f = forward(entries)
    assert_equal 3, f.length, 'past-due / today / future markers ALL present (no time filter)'
    assert_equal [TODAY - 100, TODAY, TODAY + 100], f.map { |mk| mk.due_date[:date] },
                 'all three present, sorted ASC'
  end

  def test_determinism_of_forward_axis
    entries = [
      { version_id: 9, name: 'b', due_date: TODAY + 5 },
      { version_id: 3, name: 'a', due_date: TODAY + 5 }
    ]
    a = forward(entries)
    b = forward(entries)
    assert_equal a.map(&:version_id), b.map(&:version_id)
    assert_equal a.map { |mk| mk.due_date[:date] }, b.map { |mk| mk.due_date[:date] }
  end
end
