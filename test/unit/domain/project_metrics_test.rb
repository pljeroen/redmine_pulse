# frozen_string_literal: true

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/project_metrics'

# FR-01, FR-37, FR-38 / FC-12, FC-28, FC-31, FC-21.
# ProjectMetrics is an immutable value object carrying ALREADY-SUPPLIED,
# ALREADY-VISIBILITY-SCOPED input aggregates for one project. No AR/Rails types.
class ProjectMetricsTest < Minitest::Test
  def build(**overrides)
    defaults = {
      project_id: 11,
      reference_date: Date.new(2026, 1, 21),
      effort_open: 7.0,
      effort_total: 10.0,
      risk_raw: 40.0,
      blocked_count: 12,
      risk_mapped: true,
      effort_mapped: true,
      event_series: [{ date: Date.new(2026, 6, 10), type: :issue_closed }],
      version_due_dates: [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }]
    }
    Pulse::Domain::ProjectMetrics.new(**defaults.merge(overrides))
  end

  # --- FR-01: construction, field types, reference_date NON-NIL Date ---
  def test_construction_frozen_field_types_and_non_nil_reference_date
    m = build
    assert m.frozen?, 'ProjectMetrics must be frozen at construction (FC-31)'
    assert_kind_of Integer, m.project_id
    assert_kind_of Date, m.reference_date
    refute_nil m.reference_date, 'reference_date is NON-NIL (CR-04 / FR-01)'
    assert_kind_of Numeric, m.effort_open
    assert_kind_of Numeric, m.effort_total
    assert_operator m.effort_open, :>=, 0
    assert_operator m.effort_total, :>=, 0
    assert_kind_of Numeric, m.risk_raw
    assert_kind_of Integer, m.blocked_count
    assert_includes [true, false], m.risk_mapped
    assert_includes [true, false], m.effort_mapped
    assert_kind_of Array, m.event_series
    assert_kind_of Array, m.version_due_dates
  end

  def test_reference_date_must_not_be_nil
    # CR-04: reference_date is outside the valid state space if nil; construction must fail loud.
    assert_raises(ArgumentError) { build(reference_date: nil) }
  end

  def test_mutation_raises_frozen_error
    m = build
    assert_raises(FrozenError) { m.instance_variable_set(:@project_id, 99) } if m.frozen?
  end

  # --- FR-37 + momentum-broaden: event_series shape; the broadened type set ---
  # EVENT_TYPES now = %i[issue_created issue_closed issue_commented commit] (momentum-broaden
  # §6). The VO accepts all four; an unknown type is still rejected (below).
  ALLOWED_EVENT_TYPES = %i[issue_created issue_closed issue_commented commit].freeze

  def test_event_series_shape_and_arbitrary_length
    cycle = ALLOWED_EVENT_TYPES
    series = (1..50).map { |i| { date: Date.new(2026, 6, 1) + i, type: cycle[i % cycle.length] } }
    m = build(event_series: series)
    assert_equal 50, m.event_series.length
    m.event_series.each do |e|
      assert_kind_of Date, e[:date]
      assert_kind_of Symbol, e[:type]
      assert_includes ALLOWED_EVENT_TYPES, e[:type]
    end
  end

  # --- momentum-broaden §6: :issue_commented and :commit are accepted event types ---
  def test_event_series_accepts_issue_commented_type
    m = build(event_series: [{ date: Date.new(2026, 6, 10), type: :issue_commented }])
    assert_equal :issue_commented, m.event_series.first[:type]
  end

  def test_event_series_accepts_commit_type
    m = build(event_series: [{ date: Date.new(2026, 6, 10), type: :commit }])
    assert_equal :commit, m.event_series.first[:type]
  end

  def test_event_series_still_rejects_unknown_type
    bad = [{ date: Date.new(2026, 6, 10), type: :issue_reopened }]
    assert_raises(ArgumentError) { build(event_series: bad) }
  end

  def test_empty_event_series_allowed
    m = build(event_series: [])
    assert_equal [], m.event_series
  end

  # --- FR-38: version_due_dates are plain Date; empty axis when none ---
  def test_version_due_dates_are_plain_dates_and_empty_axis
    m = build(version_due_dates: [{ version_id: 3, name: 'v1.0', due_date: Date.new(2026, 7, 1) }])
    vd = m.version_due_dates.first
    assert_kind_of Integer, vd[:version_id]
    assert_kind_of Date, vd[:due_date]
    refute_kind_of DateTime, vd[:due_date], 'due_date must be a plain Date, not DateTime (FC-28)'
    # D-TL-C (TC-11c): each entry carries a non-empty String :name.
    assert_kind_of String, vd[:name]
    refute_empty vd[:name], 'version_due_dates entry :name must be a non-empty String (TC-11c)'

    empty = build(version_due_dates: [])
    assert_equal [], empty.version_due_dates, 'zero entries => empty array (empty forward axis)'
  end

  # --- TC-11c (D-TL-C / OSI-01 Path A): version_due_dates :name is REQUIRED + non-empty.
  # RED until validate_version_due_dates! gains the :name check (A9 amendment). ---
  def test_version_due_dates_entry_missing_name_rejected
    assert_raises(ArgumentError) do
      build(version_due_dates: [{ version_id: 4, due_date: Date.new(2026, 7, 1) }])
    end
  end

  def test_version_due_dates_entry_blank_name_rejected
    assert_raises(ArgumentError) do
      build(version_due_dates: [{ version_id: 4, name: '   ', due_date: Date.new(2026, 7, 1) }])
    end
  end

  # --- FR-18 backstop / FC-21: field surface contains only visibility-scoped aggregates ---
  def test_field_surface_contains_no_blocker_encoding_fields
    m = build
    permitted = %i[project_id reference_date effort_open effort_total risk_raw
                   blocked_count risk_mapped effort_mapped event_series version_due_dates]
    permitted.each { |f| assert_respond_to m, f }
    # No field that could encode a non-visible blocker (e.g. raw issue ids/relations).
    forbidden = %i[issue_relations blockers hidden_blockers raw_issues issues]
    forbidden.each { |f| refute_respond_to m, f, "ProjectMetrics must not expose #{f} (FC-21)" }
  end
end
