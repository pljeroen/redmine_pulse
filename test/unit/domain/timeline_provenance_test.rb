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
require 'pulse/domain/timeline'
require 'pulse/domain/retrospective_bucket'
require 'pulse/domain/milestone_marker'

# Closed-provenance enforcement: the domain emits ONLY {:derived_bucket,
# :version_due_date}; :projected / :estimated NEVER appear; no :computed and no
# computed_at field anywhere in Timeline output.
class TimelineProvenanceTest < Minitest::Test
  class FixedClock
    def initialize(date)
      @date = date
    end

    def today
      @date
    end
  end

  TODAY = Date.new(2026, 6, 20)
  CLOSED_SET = %i[redmine_timestamp version_due_date computed derived_bucket].freeze
  EMITTED_BY_DOMAIN = %i[derived_bucket version_due_date].freeze
  FORBIDDEN = %i[projected estimated].freeze

  # The timeline source files (static-literal complement).
  ROOT = File.expand_path('../../../..', __FILE__)
  TIMELINE_SOURCES = %w[
    lib/pulse/domain/timeline.rb
    lib/pulse/domain/retrospective_bucket.rb
    lib/pulse/domain/milestone_marker.rb
  ].map { |p| File.join(ROOT, p) }.freeze

  def build_result
    m = Pulse::Domain::ProjectMetrics.new(
      project_id: 1,
      reference_date: TODAY,
      effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0,
      blocked_count: 0, risk_mapped: true, effort_mapped: true,
      event_series: [
        { date: TODAY - 1, type: :issue_created },
        { date: TODAY - 9, type: :issue_closed }
      ],
      version_due_dates: [
        { version_id: 3, name: 'Sprint 3', due_date: TODAY + 5 },
        { version_id: 7, name: 'Sprint 7', due_date: TODAY - 2 }
      ],
      open_issue_count: 0, covered_sum: 0.0 # additive coverage inputs (inactive baseline)
    )
    Pulse::Domain::Timeline.build(m, FixedClock.new(TODAY), Pulse::Domain::ScoringConfig.new)
  end

  def reachable_provenance(result)
    provs = []
    result.retrospective.each do |b|
      provs << b.start[:provenance] << b.end[:provenance]
    end
    result.forward.each { |mk| provs << mk.due_date[:provenance] }
    provs
  end

  # --- every reachable provenance is in the emitted-by-domain set ---
  def test_reachable_provenance_subset_of_domain_emitted_set
    provs = reachable_provenance(build_result).uniq
    refute_empty provs, 'expected some provenance-tagged boundaries/markers'
    provs.each do |p|
      assert_includes EMITTED_BY_DOMAIN, p,
                      "provenance #{p.inspect} must be one of #{EMITTED_BY_DOMAIN.inspect}"
    end
  end

  def test_reachable_provenance_within_closed_set
    reachable_provenance(build_result).uniq.each do |p|
      assert_includes CLOSED_SET, p, "provenance #{p.inspect} outside closed set"
    end
  end

  def test_no_forbidden_provenance_in_output
    provs = reachable_provenance(build_result)
    FORBIDDEN.each do |bad|
      refute_includes provs, bad, ":#{bad} provenance must NEVER appear (class does not exist)"
    end
  end

  def test_domain_does_not_emit_redmine_timestamp_or_computed
    provs = reachable_provenance(build_result)
    refute_includes provs, :redmine_timestamp, ':redmine_timestamp is a metrics-source concern'
    refute_includes provs, :computed, ':computed is an adapter concern, not emitted by the domain'
  end

  # --- static-literal scan — :projected / :estimated never in source ---
  def test_no_forbidden_provenance_literals_in_timeline_source
    TIMELINE_SOURCES.each do |f|
      next unless File.exist?(f)

      src = File.read(f)
      refute_match(/:projected\b/, src, "#{File.basename(f)} must not contain :projected")
      refute_match(/:estimated\b/, src, "#{File.basename(f)} must not contain :estimated")
    end
  end

  # --- no :computed provenance, no computed_at field anywhere ---
  def test_no_computed_at_field_on_any_value_object
    result = build_result
    refute_respond_to result, :computed_at, 'TimelineResult must not expose computed_at'
    result.retrospective.each do |b|
      refute_respond_to b, :computed_at, 'RetrospectiveBucket must not expose computed_at'
      refute b.start.key?(:computed_at), 'no :computed_at key on bucket start'
      refute b.end.key?(:computed_at), 'no :computed_at key on bucket end'
    end
    result.forward.each do |mk|
      refute_respond_to mk, :computed_at, 'MilestoneMarker must not expose computed_at'
      refute mk.due_date.key?(:computed_at), 'no :computed_at key on marker due_date'
    end
  end
end
