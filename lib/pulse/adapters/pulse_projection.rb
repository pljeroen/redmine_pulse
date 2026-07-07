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
    # the controllers (the composition root). It implements the cache/clock split:
    #
    #   * The STATIC, non-time-dependent ProjectMetrics aggregate (+ the static
    #     last_activity instant) is content-addressed by (project_id,
    #     visibility_context_id, snapshot_fingerprint) and cached in pulse_snapshots.
    #     The Clock is NOT part of the key.
    #   * The TIME-DERIVED part (staleness, momentum, sparkline, health_score, RAG,
    #     lens_keys, timeline, projection) is recomputed EVERY request from the
    #     injected Clock — so a clock advance with zero data change re-projects WITHOUT
    #     a recompute and WITHOUT a new snapshot row.
    #
    # snapshot_computed_at derives from the stored pulse_snapshots.computed_at (the
    # snapshot instant); projected_at derives from this request's clock (Time.now) —
    # two distinct sources, both provenance 'computed'.
    #
    # A `Projection` value carries everything the JSON serializer / HTML presenter
    # needs; neither recomputes anything.
    #
    # Wrapped in a PulseProjection module so the file name matches its primary
    # constant (Zeitwerk autoload-naming under Rails 7.2 / Redmine 6).
    module PulseProjection
      Projection = Struct.new(
        :project, :metrics, :health, :timeline, :config,
        :snapshot_computed_at, :projected_at, :last_activity_at, :clock,
        :risk_tracker_ids,
        # The resolved active scoring profile (its config drives scoring), its display name,
        # and the published set for the switcher. nil / empty for a default-only (profile-
        # unaware) projection so the presenter degrades gracefully.
        :active_profile, :active_profile_name, :published_profiles,
        # The human-readable dangling-fallback warning surfaced by
        # the ProfileProvider when an explicit / role-bound selection referenced a profile that
        # is not published (scoring fell back to the system default). nil on a clean resolution.
        :profile_warning,
        keyword_init: true
      )

      # The cache read-miss + per-request projection engine (composition-root helper).
      #
      # An optional profile_provider resolves the ACTIVE scoring profile per viewer (transient
      # requested_id > role binding > system default). Its id folds into the SnapshotFingerprint
      # (cache partition) and its config drives Scoring/Timeline. CRITICAL: visibility scoping
      # (VisibilityContext / Issue.visible) stays PRE-profile — the profile changes ONLY
      # weighting on the already-visibility-scoped metrics; it NEVER changes the visible issue
      # set (a profile can never widen or narrow what a viewer may see). When no profile_provider
      # is injected the engine behaves as if profiles did not exist (default config, no profile
      # component in the fingerprint).
      class Engine
        def initialize(metrics_source:, store:, settings_provider:, clock:, profile_provider: nil)
          @metrics_source = metrics_source
          @store = store
          @settings_provider = settings_provider
          @clock = clock
          @profile_provider = profile_provider
        end

        # Compute one project's full projection through the cache. requested_id is the
        # transient viewer selection (the ?profile query param; nil => role binding / default).
        # Returns Projection scored under the RESOLVED profile's config, cached under a
        # profile-partitioned fingerprint.
        def project_projection(user, project, requested_id = nil)
          active = resolve_profile(user, project, requested_id)
          # Capture the dangling-fallback warning the provider set during this resolution (nil on
          # a clean resolve) BEFORE any further provider call could reset it.
          warning = profile_warning
          config = active ? active.config : @settings_provider.scoring_config

          ctx_id = VisibilityContext.new(user, project).id
          fingerprint = SnapshotFingerprint.new(
            user, project, settings_provider: @settings_provider,
            active_profile_id: active&.id
          ).value
          # The partition-scope for the superseded-fingerprint prune in the store: the RESOLVED
          # active profile id, normalized so the reserved default/nil path collapses to '' (the
          # single-profile one-row-per-cell behavior). A NON-default profile scopes the prune to
          # its own id so warming it never deletes another profile's row (cache partitioning).
          partition_profile_id = partition_profile_id(active)

          max_age = @settings_provider.snapshot_max_age_minutes
          row = @store.fetch_row(project.id, ctx_id, fingerprint)
          row = if row.nil?
                  warm(user, project, ctx_id, fingerprint, profile_id: partition_profile_id)
                elsif age_stale?(row[:computed_at], max_age)
                  refresh(user, project, ctx_id, fingerprint, profile_id: partition_profile_id)
                else
                  row
                end

          build_projection(project, row[:payload], row[:computed_at],
                            config: config, active_profile: active, profile_warning: warning)
        end

        # Compute every visible+permitted project's projection (portfolio set). The warm
        # path does ONE bulk snapshot SELECT for the whole portfolio,
        # falling back to a per-project warm only on a cache miss.
        #
        # The portfolio is PROFILED exactly like the per-project show page.
        # requested_id is the transient GLOBAL override (?profile_id) applying to every project;
        # when absent, each project resolves its OWN active profile via the provider (the
        # viewer's per-project role-default binding — Redmine roles are per-project — else the
        # system default). The resolved profile's id folds into that project's SnapshotFingerprint
        # AND scopes its prune, so the portfolio's per-project snapshots are profile-partitioned
        # with the SAME no-cross-serve guarantee as the show page.
        def portfolio_projections(user, requested_id = nil)
          pids = @metrics_source.portfolio_project_ids(user)
          projects = Project.visible(user).where(id: pids).order(:id)

          # Resolve each project's active profile up front (per-project role default, or the
          # global override). Keyed by project.id so the fingerprint, prune-scope, and scoring
          # config all read the SAME resolved profile below.
          active_by_id = {}
          config_by_id = {}
          warning_by_id = {}
          keys = {}
          projects.each do |project|
            active = resolve_profile(user, project, requested_id)
            active_by_id[project.id] = active
            # Capture THIS project's dangling-fallback warning (nil on a clean resolve) BEFORE the
            # next iteration's resolve_profile resets the provider's @last_warning. Threaded into
            # build_projection below so the presenter can surface it on the index.
            warning_by_id[project.id] = profile_warning
            config_by_id[project.id] = active ? active.config : @settings_provider.scoring_config
            ctx_id = VisibilityContext.new(user, project).id
            fingerprint = SnapshotFingerprint.new(
              user, project, settings_provider: @settings_provider,
              active_profile_id: active&.id
            ).value
            keys[project.id] = [project.id, ctx_id, fingerprint]
          end

          rows = @store.fetch_rows(keys.values)
          max_age = @settings_provider.snapshot_max_age_minutes

          projects.map do |project|
            key = keys[project.id]
            active = active_by_id[project.id]
            partition_profile_id = partition_profile_id(active)
            row = rows[key]
            row = if row.nil?
                    warm(user, project, key[1], key[2], profile_id: partition_profile_id)
                  elsif age_stale?(row[:computed_at], max_age)
                    refresh(user, project, key[1], key[2], profile_id: partition_profile_id)
                  else
                    row
                  end
            build_projection(project, row[:payload], row[:computed_at],
                             config: config_by_id[project.id], active_profile: active,
                             profile_warning: warning_by_id[project.id])
          end
        end

        private

        # Resolve the active profile for the viewer via the injected provider (nil when no
        # provider is wired => default-config behavior, as if profiles did not exist).
        # requested_id is the transient
        # selection. A dangling id degrades to the default inside the provider (never raises).
        def resolve_profile(user, project, requested_id)
          return nil if @profile_provider.nil?

          @profile_provider.resolve(user, project, requested_id)
        end

        # The dangling-fallback warning from the LAST provider #resolve:
        # a human-readable String when the just-resolved selection referenced an unpublished
        # profile (scoring fell back to the system default), else nil. nil when no provider is
        # wired or the provider does not expose #last_warning.
        def profile_warning
          return nil if @profile_provider.nil?
          return nil unless @profile_provider.respond_to?(:last_warning)

          @profile_provider.last_warning
        end

        # The store-partition id for the superseded-fingerprint prune scope: the resolved active
        # profile's id, with the reserved-default and no-profile paths mapped to '' so a
        # default-only cell collapses to a single row (mirrors SnapshotFingerprint's OMIT rule
        # for RESERVED_DEFAULT_ID / nil — same partition dimension, expressed as a column).
        def partition_profile_id(active)
          id = active&.id
          return '' if id.nil?
          return '' if id.to_s == SnapshotFingerprint::RESERVED_DEFAULT_ID

          id.to_s
        end

        def published_profiles
          return nil if @profile_provider.nil?

          @profile_provider.profiles
        end

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
        def refresh(user, project, ctx_id, fingerprint, profile_id: '')
          metrics = @metrics_source.metrics_for(user, project_ids: [project.id]).first
          payload = build_payload(metrics, user, project)
          @store.refresh(project.id, ctx_id, fingerprint, payload,
                         computed_at: @clock.now, profile_id: profile_id)
          @store.fetch_row(project.id, ctx_id, fingerprint) ||
            { payload: payload, computed_at: @clock.now }
        end

        # Cold-miss warm: compute the static aggregate, store it (idempotent), and read it
        # back so the returned computed_at is the persisted snapshot instant.
        def warm(user, project, ctx_id, fingerprint, profile_id: '')
          metrics = @metrics_source.metrics_for(user, project_ids: [project.id]).first
          payload = build_payload(metrics, user, project)
          @store.store(project.id, ctx_id, fingerprint, payload, profile_id: profile_id)
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
        # timeline through the pure domain. A corrupt snapshot payload or a
        # Scoring/Timeline raise would otherwise surface as a bare Redmine 500 with no
        # provenance; log the project_id + exception (class/message/backtrace head) so the
        # failure is diagnosable, then re-raise so observable behavior is UNCHANGED (the
        # request still 500s — this adds an audit line, it does not swallow the error).
        def build_projection(project, payload, computed_at, config: nil, active_profile: nil,
                             profile_warning: nil)
          metrics = @store.deserialize_metrics(payload)
          config ||= @settings_provider.scoring_config
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
            risk_tracker_ids: safe_risk_tracker_ids,
            active_profile: active_profile,
            active_profile_name: active_profile&.name,
            published_profiles: published_profiles,
            profile_warning: profile_warning
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
