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
    # PulseProjection — the cache read-miss + per-request projection engine wired by
    # the controllers (the composition root). It implements the cache/clock split
    # (FC-CA-20/21):
    #
    #   * The STATIC, non-time-dependent ProjectMetrics aggregate (+ the static
    #     last_activity instant) is content-addressed by (project_id,
    #     visibility_context_id, snapshot_fingerprint) and cached in pulse_snapshots.
    #     The Clock is NOT part of the key (DEC-11).
    #   * The TIME-DERIVED part (staleness, momentum, sparkline, health_score, RAG,
    #     lens_keys, timeline, projection) is recomputed EVERY request from the
    #     injected Clock — so a clock advance with zero data change re-projects WITHOUT
    #     a recompute and WITHOUT a new snapshot row.
    #
    # snapshot_computed_at derives from the stored pulse_snapshots.computed_at (the
    # snapshot instant); projected_at derives from this request's clock (Time.now) —
    # two distinct sources, both provenance 'computed' (FC-CA-15).
    #
    # A `Projection` value carries everything the JSON serializer / HTML presenter
    # needs; neither recomputes anything (COND-A4-001).
    #
    # Wrapped in a PulseProjection module so the file name matches its primary
    # constant (Zeitwerk autoload-naming under Rails 7.2 / Redmine 6).
    module PulseProjection
      Projection = Struct.new(
        :project, :metrics, :health, :timeline, :config,
        :snapshot_computed_at, :projected_at, :last_activity_at, :clock,
        :risk_tracker_ids,
        keyword_init: true
      )

      # The cache read-miss + per-request projection engine (composition-root helper).
      class Engine
        def initialize(metrics_source:, store:, settings_provider:, clock:)
          @metrics_source = metrics_source
          @store = store
          @settings_provider = settings_provider
          @clock = clock
        end

        # Compute one project's full projection through the cache. Returns Projection.
        def project_projection(user, project)
          ctx_id = VisibilityContext.new(user, project).id
          fingerprint = SnapshotFingerprint.new(user, project, settings_provider: @settings_provider).value

          max_age = @settings_provider.snapshot_max_age_minutes
          row = @store.fetch_row(project.id, ctx_id, fingerprint)
          row = if row.nil?
                  warm(user, project, ctx_id, fingerprint)
                elsif age_stale?(row[:computed_at], max_age)
                  refresh(user, project, ctx_id, fingerprint)
                else
                  row
                end

          build_projection(project, row[:payload], row[:computed_at])
        end

        # Compute every visible+permitted project's projection (portfolio set). The warm
        # path does ONE bulk snapshot SELECT for the whole portfolio (CA-30 SOFT-PERF),
        # falling back to a per-project warm only on a cache miss.
        def portfolio_projections(user)
          pids = @metrics_source.portfolio_project_ids(user)
          projects = Project.visible(user).where(id: pids).order(:id)

          keys = {}
          projects.each do |project|
            ctx_id = VisibilityContext.new(user, project).id
            fingerprint = SnapshotFingerprint.new(user, project, settings_provider: @settings_provider).value
            keys[project.id] = [project.id, ctx_id, fingerprint]
          end

          rows = @store.fetch_rows(keys.values)
          max_age = @settings_provider.snapshot_max_age_minutes

          projects.map do |project|
            key = keys[project.id]
            row = rows[key]
            row = if row.nil?
                    warm(user, project, key[1], key[2])
                  elsif age_stale?(row[:computed_at], max_age)
                    refresh(user, project, key[1], key[2])
                  else
                    row
                  end
            build_projection(project, row[:payload], row[:computed_at])
          end
        end

        private

        # True iff the freshness cap is ON (> 0) AND the row is at least max_age minutes
        # old (inclusive at the boundary: exactly max_age => stale => refresh). Reads the
        # injectable @clock.now (never a bare Time.now) so the age check is testable.
        def age_stale?(computed_at, max_age_minutes)
          max_age_minutes.to_i > 0 &&
            (@clock.now - computed_at) >= max_age_minutes.to_i * 60
        end

        # Age-refresh: rebuild the static payload and OVERWRITE the keyed row in place
        # (fresh computed_at), then read it back so the returned computed_at is the
        # persisted fresh instant. Mirrors #warm but takes the deliberate-overwrite path.
        def refresh(user, project, ctx_id, fingerprint)
          metrics = @metrics_source.metrics_for(user, project_ids: [project.id]).first
          payload = build_payload(metrics, user, project)
          @store.refresh(project.id, ctx_id, fingerprint, payload, computed_at: @clock.now)
          @store.fetch_row(project.id, ctx_id, fingerprint) ||
            { payload: payload, computed_at: @clock.now }
        end

        # Cold-miss warm: compute the static aggregate, store it (idempotent), and read it
        # back so the returned computed_at is the persisted snapshot instant (FC-CA-15).
        def warm(user, project, ctx_id, fingerprint)
          metrics = @metrics_source.metrics_for(user, project_ids: [project.id]).first
          payload = build_payload(metrics, user, project)
          @store.store(project.id, ctx_id, fingerprint, payload)
          @store.fetch_row(project.id, ctx_id, fingerprint) ||
            { payload: payload, computed_at: Time.now.utc }
        end

        # The STATIC payload stored in pulse_snapshots: the serialized ProjectMetrics
        # plus the static last_activity instant (a real Redmine timestamp, NOT clock-
        # derived). computed_at is set by the store at write time.
        def build_payload(metrics, user, project)
          payload = @store.serialize_metrics(metrics)
          payload['last_activity_at'] = last_activity_instant(user, project)
          payload
        end

        # Re-hydrate the static cached payload and re-derive the time-dependent score /
        # timeline through the pure domain (FC-CA-20/21). A corrupt snapshot payload or a
        # Scoring/Timeline raise would otherwise surface as a bare Redmine 500 with no
        # provenance; log the project_id + exception (class/message/backtrace head) so the
        # failure is diagnosable, then re-raise so observable behavior is UNCHANGED (the
        # request still 500s — this adds an audit line, it does not swallow the error).
        def build_projection(project, payload, computed_at)
          metrics = @store.deserialize_metrics(payload)
          config = @settings_provider.scoring_config
          health = Pulse::Domain::Scoring.score(metrics, @clock, config)
          timeline = Pulse::Domain::Timeline.build(metrics, @clock, config)

          Projection.new(
            project: project,
            metrics: metrics,
            health: health,
            timeline: timeline,
            config: config,
            snapshot_computed_at: (computed_at ? computed_at.utc : Time.now.utc),
            projected_at: Time.now.utc,
            last_activity_at: parse_instant(payload['last_activity_at']),
            clock: @clock,
            risk_tracker_ids: safe_risk_tracker_ids
          )
        rescue StandardError => e
          log_projection_error(project, e)
          raise
        end

        # Emit a structured error line for a projection failure (corrupt snapshot payload
        # or a domain Scoring/Timeline raise). Best-effort: a logger that is absent or
        # itself raises must NEVER mask the original exception (the caller re-raises it).
        def log_projection_error(project, error)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          pid = project.respond_to?(:id) ? project.id : project
          head = Array(error.backtrace).first(5).join("\n")
          Rails.logger.error(
            "[redmine_pulse] projection failed for project_id=#{pid}: " \
            "#{error.class}: #{error.message}\n#{head}"
          )
        rescue StandardError
          nil
        end

        # The newest visible issue.updated_on / eligible changeset.committed_on for the
        # project — a real Redmine instant (provenance redmine_timestamp). nil when the
        # project has no visible activity. Read-only.
        def last_activity_instant(user, project)
          candidates = []
          issue_at = Issue.where(project_id: project.id).visible(user).maximum(:updated_on)
          candidates << issue_at if issue_at

          if project.module_enabled?(:repository) &&
             user.allowed_to?(:view_changesets, project) && project.repository
            cs_at = Changeset.where(repository_id: project.repository.id).maximum(:committed_on)
            candidates << cs_at if cs_at
          end

          max = candidates.compact.max
          max&.utc&.iso8601
        end

        def safe_risk_tracker_ids
          return [] unless @settings_provider.respond_to?(:risk_tracker_ids)

          @settings_provider.risk_tracker_ids
        end

        def parse_instant(value)
          return nil if value.nil?

          Time.iso8601(value)
        rescue ArgumentError
          Time.parse(value.to_s)
        end
      end
    end
  end
end
