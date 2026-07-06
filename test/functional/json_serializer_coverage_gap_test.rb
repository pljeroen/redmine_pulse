# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))

# FC-C2-15 (presentation, JSON side) — JsonSerializer.signal_set includes a 'coverage_gap'
# entry (raw_value emitted VERBATIM, FC-CA-23 passthrough) when coverage_gap is in the
# breakdown, and OMITS the key when absent. Discharges FR-C2-07.
#
# HARNESS lane (RED-by-construction): JsonSerializer resolves plugin constants via Zeitwerk.
# RED until A9 extends JsonSerializer.SIGNAL_ORDER to include coverage_gap.
class JsonSerializerCoverageGapTest < ActiveSupport::TestCase
  JS = Pulse::Adapters::JsonSerializer
  SR = Pulse::Domain::SignalResult

  FakeProject = Struct.new(:id, :identifier, :name)
  FakeHealth = Struct.new(:breakdown)
  FakeProjection = Struct.new(:health, :project, :risk_tracker_ids)

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

  # --- coverage_gap ENABLED => 'coverage_gap' entry present, raw_value verbatim ---------
  def test_signal_set_includes_coverage_gap_when_enabled
    r = 0.4
    set = JS.signal_set(projection_for(breakdown_with_coverage_gap(raw_value: r)), with_drill: false)
    assert_includes set.keys, 'coverage_gap',
                    "signal_set must include a 'coverage_gap' entry when it is in the breakdown"
    entry = set['coverage_gap']
    assert_equal true, entry['active'], 'coverage_gap entry active == true'
    # raw_value emitted VERBATIM (the gap fraction), NOT the planning-coverage percentage.
    assert_in_delta r, entry['raw_value'].to_f, 1e-12,
                    'JSON raw_value is the verbatim gap fraction (FC-CA-23 passthrough)'
  end

  # --- coverage_gap ABSENT => no 'coverage_gap' key (default-OFF byte-identical payload) -
  def test_signal_set_omits_coverage_gap_when_absent
    set = JS.signal_set(projection_for(breakdown_without_coverage_gap), with_drill: false)
    refute_includes set.keys, 'coverage_gap',
                    "signal_set must NOT include a 'coverage_gap' key when it is absent"
    assert_equal 5, set.size, 'only the 5 C1 entries appear when coverage_gap is off'
  end
end
