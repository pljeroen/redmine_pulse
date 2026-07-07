# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/health_result'
require 'pulse/domain/scoring'
require 'pulse/domain/timeline'

module Pulse
  module Tasks
    # CanonicalScan — shared composition-root wiring for the two rake tasks.
    # It builds the CANONICAL/global read: a privileged viewer + a profile-provider-less
    # PulseProjection::Engine (so scoring uses the 'default' profile config — the
    # canonical behavior), and it computes one project's current canonical HealthResult.
    #
    # Alerting scores under the canonical profile ONLY (per-viewer alerting is explicitly
    # out of scope) — the alert-state row is keyed by project_id alone, so a
    # single canonical read per project is exactly right.
    module CanonicalScan
      module_function

      # A privileged canonical viewer so every pulse-enabled project is scored regardless of
      # per-user membership (the canonical/global read; there is no per-viewer alerting). An
      # admin user satisfies allowed_to?(:view_pulse, project) on every pulse-enabled project.
      def canonical_viewer
        User.active.where(admin: true).order(:id).first || User.admin.active.first ||
          User.where(admin: true).first
      end

      # The canonical projection engine: the SAME adapters the request cycle wires, but with
      # NO profile_provider — so it scores under the global 'default' config (canonical).
      def canonical_engine
        settings_provider = Pulse::Adapters::RedmineSettingsProvider.new
        clock = Pulse::Adapters::SystemClock.new
        Pulse::Adapters::PulseProjection::Engine.new(
          metrics_source: Pulse::Adapters::RedmineMetricsSource.new(
            settings_provider: settings_provider, clock: clock
          ),
          store: Pulse::Adapters::ActiveRecordSnapshotStore.new,
          settings_provider: settings_provider,
          clock: clock,
          profile_provider: nil # canonical/global profile only
        )
      end

      # Resolve the set of project ids to act on: an explicit list as-is, else the full
      # pulse-enabled portfolio visible to the canonical viewer.
      def target_project_ids(project_ids)
        return Array(project_ids).map(&:to_i) unless project_ids.nil?

        settings_provider = Pulse::Adapters::RedmineSettingsProvider.new
        clock = Pulse::Adapters::SystemClock.new
        Pulse::Adapters::RedmineMetricsSource.new(
          settings_provider: settings_provider, clock: clock
        ).portfolio_project_ids(canonical_viewer)
      end

      # Compute one project's CURRENT canonical HealthResult (rag / dominant_signal /
      # health_score). `force_rag` is a deterministic-transition seam (used by the frozen
      # suites): when given, the current band is that Symbol and the dominant/score are
      # carried from `prior` (or the real computation when there is no prior) so the forced
      # step is a PURE rag-axis transition — it never injects a spurious dominant_change or
      # score_delta. Without force_rag it is the real canonical HealthResult.
      def current_health(viewer, engine, project, prior: nil, force_rag: nil)
        projection = engine.project_projection(viewer, project, nil)
        health = projection.health

        return health if force_rag.nil?

        dominant = prior && prior[:last_dominant] ? prior[:last_dominant].to_sym : health.dominant_signal
        score = prior && !prior[:last_score].nil? ? prior[:last_score] : health.health_score

        Pulse::Domain::HealthResult.new(
          project_id: project.id,
          health_score: force_rag == :no_data ? nil : score,
          rag: force_rag,
          dominant_signal: force_rag == :no_data ? nil : dominant,
          signal_completeness: health.signal_completeness,
          breakdown: health.breakdown,
          lens_keys: health.lens_keys,
          effort_open: health.effort_open
        )
      end
    end
  end
end
