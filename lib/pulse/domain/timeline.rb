# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'date'
require 'pulse/domain/retrospective_bucket'
require 'pulse/domain/milestone_marker'

module Pulse
  module Domain
    # Immutable composite timeline result for one project: a retrospective sparkline
    # axis (rolling 7-day buckets) and a forward milestone-marker axis. Both arrays are
    # frozen so the exposed collections raise FrozenError on mutation (TC-16). Carries
    # NO computed_at / :computed (TC-15). Pure data — stdlib types only.
    class TimelineResult
      attr_reader :retrospective, :forward

      def initialize(retrospective:, forward:)
        @retrospective = retrospective.freeze
        @forward = forward.freeze

        freeze
      end
    end

    # Pure-domain timeline construction over already-supplied, already-visibility-scoped
    # aggregates. Reads 'today' ONLY via clock.today (TC-01/TC-17); event dates ONLY via
    # metrics.event_series; due dates ONLY via metrics.version_due_dates. Deterministic /
    # referentially transparent (TC-08): no system time, no entropy, no global state.
    module Timeline
      BUCKET_WIDTH_DAYS = 7
      BOUNDARY_PROVENANCE = :derived_bucket
      MILESTONE_PROVENANCE = :version_due_date

      module_function

      # Timeline.build(metrics, clock, config) -> TimelineResult.
      #   metrics: ProjectMetrics (visibility-scoped pure-domain VO)
      #   clock:   duck-typed Clock (#today -> Date) — the SOLE 'now' source
      #   config:  ScoringConfig (supplies activity_window_days)
      def build(metrics, clock, config)
        today = clock.today
        TimelineResult.new(
          retrospective: build_retrospective(metrics, today, config),
          forward: build_forward(metrics)
        )
      end

      # ── Retrospective axis (D-TL-A half-open today-exclusive; D-TL-B oldest-first) ──

      # ceil(W / 7) buckets, each [start, end) of width 7, contiguous, anchored so the
      # most-recent bucket is [today-7, today) (today exclusive). Oldest-first array.
      def build_retrospective(metrics, today, config)
        n = bucket_count(config.activity_window_days)
        (0...n).map do |k|
          # k == 0 is the OLDEST bucket (D-TL-B): start == today - 7*(n-k).
          start_at = today - BUCKET_WIDTH_DAYS * (n - k)
          end_at = start_at + BUCKET_WIDTH_DAYS
          RetrospectiveBucket.new(
            start: { at: start_at, provenance: BOUNDARY_PROVENANCE },
            end: { at: end_at, provenance: BOUNDARY_PROVENANCE },
            event_count: count_events_in(metrics.event_series, start_at, end_at)
          )
        end
      end

      # ceil(W / 7) by integer arithmetic. W is validated >= 1 by ScoringConfig.
      def bucket_count(window_days)
        (window_days + BUCKET_WIDTH_DAYS - 1) / BUCKET_WIDTH_DAYS
      end

      # Sparkline event types (momentum-broaden D3): the timeline/sparkline counts ONLY
      # issue lifecycle events — the broadened momentum activity types (:issue_commented,
      # :commit) are deliberately EXCLUDED so the sparkline output is preserved exactly.
      SPARKLINE_EVENT_TYPES = %i[issue_created issue_closed].freeze

      # Half-open membership: start <= e[:date] < end (start inclusive, end exclusive).
      # Counts ONLY SPARKLINE_EVENT_TYPES (momentum-broaden D3 behaviour-preserving guard:
      # broadening the sparkline is a separate opt-in, NOT in this contract). Real aggregate
      # (no smoothing, no interpolation) over THIS bucket's interval only.
      def count_events_in(event_series, start_at, end_at)
        event_series.count do |e|
          next false unless SPARKLINE_EVENT_TYPES.include?(e[:type])

          date = e[:date]
          date >= start_at && date < end_at
        end
      end

      # ── Forward axis (TC-10 bijective / TC-12 [due_date ASC, version_id ASC] / TC-13) ──

      # One MilestoneMarker per version_due_dates entry; empty axis => []. NO past-due
      # filtering (TC-13). Sorted [due_date ASC, version_id ASC] by the domain (TC-12).
      def build_forward(metrics)
        metrics.version_due_dates
               .map { |entry| to_marker(entry) }
               .sort_by { |mk| [mk.due_date[:date], mk.version_id] }
      end

      def to_marker(entry)
        MilestoneMarker.new(
          version_id: entry[:version_id],
          name: entry[:name],
          due_date: { date: entry[:due_date], provenance: MILESTONE_PROVENANCE }
        )
      end
    end
  end
end
