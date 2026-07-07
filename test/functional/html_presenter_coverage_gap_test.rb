# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))

# Presentation (HTML side) — HtmlPresenter renders an enabled coverage_gap as
# PLANNING COVERAGE = 100 × (1 − raw_value) (NOT the raw gap fraction), and OMITS the
# coverage_gap row when it is absent from the breakdown.
#
# HARNESS lane: HtmlPresenter references plugin constants (MainConcernLabels,
# JsonSerializer, SignalResult) resolved by Zeitwerk, so it must load under the Redmine
# test harness, not standalone. Requires HtmlPresenter.SIGNAL_KEYS to include coverage_gap
# and to render the planning-coverage value.
class HtmlPresenterCoverageGapTest < ActiveSupport::TestCase
  HP = Pulse::Adapters::HtmlPresenter
  SR = Pulse::Domain::SignalResult

  # A lightweight fake projection: HtmlPresenter.signal_rows reads .health.breakdown and,
  # for drill_url, .project.identifier. We stub only what the method touches.
  FakeProject = Struct.new(:id, :identifier, :name)
  FakeHealth = Struct.new(:breakdown)
  FakeProjection = Struct.new(:health, :project, :risk_tracker_ids)

  # A HealthResult breakdown whose 5 default rows are inactive and a coverage_gap row is ACTIVE
  # with raw_value = r (the gap fraction). planning coverage == 100 × (1 − r).
  def breakdown_with_coverage_gap(raw_value:)
    c1 = %i[staleness progress momentum risk_load blocked_load].map do |k|
      SR.new(key: k, active: false, raw_value: nil, n: nil,
             effective_weight: nil, contribution: nil)
    end
    cg = SR.new(key: :coverage_gap, active: true, raw_value: raw_value,
                n: 1.0 - raw_value, effective_weight: 0.15, contribution: 12.0)
    c1 + [cg]
  end

  def breakdown_without_coverage_gap
    %i[staleness progress momentum risk_load blocked_load].map do |k|
      SR.new(key: k, active: false, raw_value: nil, n: nil,
             effective_weight: nil, contribution: nil)
    end
  end

  def projection_for(breakdown)
    FakeProjection.new(FakeHealth.new(breakdown),
                       FakeProject.new(1, 'demo', 'Demo'), [])
  end

  def coverage_gap_row(rows)
    rows.find { |r| r.key.to_s == 'coverage_gap' }
  end

  # --- coverage_gap ENABLED+active => planning-coverage percentage 100×(1−raw_value) ----
  def test_signal_rows_render_planning_coverage_when_enabled
    r = 0.25 # gap fraction => planning coverage 75%
    rows = HP.signal_rows(projection_for(breakdown_with_coverage_gap(raw_value: r)))
    row = coverage_gap_row(rows)
    refute_nil row, 'signal_rows must include a coverage_gap row when it is in the breakdown'
    assert row.active, 'the coverage_gap row is active'
    # The DISPLAYED value must be the planning-coverage percentage 100×(1−r) == 75, NOT r.
    rendered = row.raw_value.to_s
    assert_match(/75/, rendered,
                 "coverage_gap row must display planning coverage 100×(1−raw_value)=75%, got #{rendered.inspect}")
    refute_match(/0\.25/, rendered,
                 'coverage_gap row must NOT display the raw gap fraction (0.25)')
  end

  # --- coverage_gap ABSENT => no coverage_gap row (default-OFF byte-identical panel) ----
  def test_signal_rows_omit_coverage_gap_when_absent
    rows = HP.signal_rows(projection_for(breakdown_without_coverage_gap))
    assert_nil coverage_gap_row(rows),
               'signal_rows must NOT include a coverage_gap row when it is absent from the breakdown'
    assert_equal 5, rows.size, 'only the 5 default rows render when coverage_gap is off'
  end
end
