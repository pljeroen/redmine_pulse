# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'date'

module Pulse
  module Adapters
    # JsonSerializer — renders a PulseProjection into the frozen portfolio.json /
    # project.json payloads (CA-14..CA-19). It performs NO scoring/timeline recompute
    # (it reads the already-computed domain HealthResult/TimelineResult off the
    # Projection) and NO re-rounding of contributions (explainability passthrough,
    # FC-CA-23). All emitted dates carry a provenance tag from the CLOSED set
    # {computed, redmine_timestamp, derived_bucket, version_due_date} — never
    # projected/estimated (INV-NO-INVENTED-DATES).
    module JsonSerializer
      SCHEMA_VERSION = '1.0'
      SIGNAL_ORDER = %w[staleness progress momentum risk_load blocked_load].freeze
      VISIBILITY_NOTE = 'Health computed from issues visible to you.'

      module_function

      # ── portfolio.json ────────────────────────────────────────────────────────
      # config/clock are passed explicitly so the projection block is well-formed even
      # for an EMPTY portfolio (no project to read them off of) — empty -> 200 + [].
      def portfolio(projections, lens:, default_lens:, pagination:, snapshot_at:, projected_at:, config:, clock:)
        {
          'schema_version' => SCHEMA_VERSION,
          'snapshot_computed_at' => ts_computed(snapshot_at),
          'projected_at' => ts_computed(projected_at),
          'projection' => projection_block_from(config, clock),
          'lens' => lens.to_s,
          'default_lens' => default_lens.to_s,
          'pagination' => pagination,
          'projects' => projections.map { |p| project_health(p) }
        }
      end

      # ── project.json ──────────────────────────────────────────────────────────
      def project(projection)
        h = projection.health
        {
          'schema_version' => SCHEMA_VERSION,
          'snapshot_computed_at' => ts_computed(projection.snapshot_computed_at),
          'projected_at' => ts_computed(projection.projected_at),
          'projection' => projection_block(projection),
          'visibility_note' => VISIBILITY_NOTE,
          'project' => project_ref(projection.project),
          'health_score' => h.health_score,
          'rag' => h.rag.to_s,
          'dominant_signal' => dominant_signal_value(h),
          'main_concern' => MainConcernLabels.label(h.dominant_signal),
          'signal_completeness' => h.signal_completeness,
          'lens_keys' => lens_keys(h),
          'thresholds' => {
            'rag_green_min' => projection.config.rag_green_min,
            'rag_amber_min' => projection.config.rag_amber_min
          },
          'weights_effective' => weights_effective(h),
          'signals' => signal_set(projection, with_drill: true),
          'timeline' => timeline(projection.timeline)
        }
      end

      # ── shared parts ──────────────────────────────────────────────────────────

      def project_health(projection)
        h = projection.health
        {
          'project_id' => projection.project.id,
          'identifier' => projection.project.identifier,
          'name' => projection.project.name,
          'url' => "/projects/#{projection.project.identifier}/pulse",
          'health_score' => h.health_score,
          'rag' => h.rag.to_s,
          'dominant_signal' => dominant_signal_value(h),
          'main_concern' => MainConcernLabels.label(h.dominant_signal),
          'signal_completeness' => h.signal_completeness,
          'lens_keys' => lens_keys(h),
          'signals' => signal_set(projection, with_drill: false),
          'last_activity' => last_activity(projection.last_activity_at),
          'sparkline' => sparkline(projection.timeline)
        }
      end

      def project_ref(project)
        {
          'project_id' => project.id,
          'identifier' => project.identifier,
          'name' => project.name,
          'url' => "/projects/#{project.identifier}/pulse"
        }
      end

      def projection_block(projection)
        projection_block_from(projection.config, projection.clock)
      end

      def projection_block_from(cfg, clock)
        {
          'clock_today' => clock.today.iso8601,
          'time_zone' => time_zone_name,
          'activity_window_days' => cfg.activity_window_days,
          'horizons' => {
            'staleness' => cfg.h_stale,
            'risk_load' => cfg.h_risk,
            'blocked_load' => cfg.h_blocked
          }
        }
      end

      # dominant_signal is a domain symbol on the normal path and nil on the no-data
      # path (THAW-RA-001). Emit the string key when present and JSON null when nil —
      # NOT "" (the old `nil.to_s`), which fails the schema enum.
      def dominant_signal_value(health)
        ds = health.dominant_signal
        ds.nil? ? nil : ds.to_s
      end

      def lens_keys(health)
        lk = health.lens_keys
        {
          'health' => lk[:health],
          'at_risk' => lk[:at_risk],
          'stale' => lk[:stale],
          'done' => lk[:done],
          'blocked' => lk[:blocked]
        }
      end

      def weights_effective(health)
        health.breakdown.select(&:active).each_with_object({}) do |s, acc|
          acc[s.key.to_s] = s.effective_weight
        end
      end

      # Exactly the 5 canonical signals, keyed by name; inactive -> active:false +
      # all-null numeric fields (+ null drill_url). Contributions emitted VERBATIM
      # (no re-round) from the domain SignalResult (FC-CA-23).
      def signal_set(projection, with_drill:)
        by_key = projection.health.breakdown.to_h { |s| [s.key.to_s, s] }
        SIGNAL_ORDER.each_with_object({}) do |key, acc|
          s = by_key[key]
          entry = {
            'active' => s.active,
            'raw_value' => s.active ? s.raw_value.to_f : nil,
            'n' => s.active ? s.n : nil,
            'effective_weight' => s.active ? s.effective_weight : nil,
            'contribution' => s.active ? s.contribution : nil
          }
          entry['drill_url'] = with_drill ? drill_url(projection, key, s) : nil if with_drill
          acc[key] = entry
        end
      end

      # Per-signal drill link into the visible Redmine issues/versions (DG-05; seed).
      # null when the signal is inactive.
      def drill_url(projection, key, signal)
        return nil unless signal.active

        ident = projection.project.identifier
        case key
        when 'staleness'
          "/projects/#{ident}/activity"
        when 'progress'
          "/projects/#{ident}/issues?set_filter=1&status_id=*"
        when 'momentum'
          "/projects/#{ident}/issues?set_filter=1&c[]=status&c[]=closed_on"
        when 'risk_load'
          tid = Array(projection.risk_tracker_ids).first
          "/projects/#{ident}/issues?set_filter=1&tracker_id=#{tid}&status_id=o"
        when 'blocked_load'
          "/projects/#{ident}/issues?set_filter=1&status_id=o"
        end
      end

      def timeline(timeline_result)
        {
          'retrospective' => timeline_result.retrospective.map { |b| retro_bucket(b) },
          'forward' => timeline_result.forward.map { |mk| milestone(mk) }
        }
      end

      def sparkline(timeline_result)
        timeline_result.retrospective.map { |b| retro_bucket(b) }
      end

      # Retrospective bucket boundaries are midnight-UTC date-times (derived_bucket).
      def retro_bucket(bucket)
        {
          'start' => ts_bucket(bucket.start[:at]),
          'end' => ts_bucket(bucket.end[:at]),
          'value' => bucket.event_count
        }
      end

      # Forward milestone due dates are DATE-ONLY (version_due_date) — never midnight-
      # UTC (the two date encodings are deliberately distinct, MM-03).
      def milestone(marker)
        {
          'version_id' => marker.version_id,
          'name' => marker.name,
          'due_date' => { 'date' => marker.due_date[:date].iso8601, 'provenance' => 'version_due_date' }
        }
      end

      def last_activity(instant)
        return nil if instant.nil?

        { 'at' => iso_utc(instant), 'provenance' => 'redmine_timestamp' }
      end

      def ts_computed(time)
        { 'at' => iso_utc(time), 'provenance' => 'computed' }
      end

      # A derived bucket boundary Date -> midnight-UTC date-time string.
      def ts_bucket(date)
        { 'at' => "#{date.iso8601}T00:00:00Z", 'provenance' => 'derived_bucket' }
      end

      def iso_utc(time)
        t = time.respond_to?(:utc) ? time.utc : time
        t.strftime('%Y-%m-%dT%H:%M:%SZ')
      end

      def time_zone_name
        zone = Time.zone
        name = zone&.tzinfo&.name || zone&.name
        name.to_s.empty? ? 'UTC' : name
      end
    end
  end
end
