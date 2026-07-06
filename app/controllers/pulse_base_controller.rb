# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseBaseController — the shared composition-root + authorization base for the
# HTML (PulseController) and JSON (PulseApiController) adapter surfaces.
#
# It owns the per-request adapter-factory methods (settings_provider / clock /
# store / metrics_source / engine) and the module+permission `authorize_pulse`
# ladder — identical across both surfaces (a copy-paste DRY removal, no behavior
# change). The EXACT 404/403 visibility decision differs per surface (HTML sets
# @project so Redmine's project layout/menu renders; JSON does not), so
# `visible_project` stays per-controller; only the shared machinery lives here.
#
# Both subclasses remain `< ApplicationController` transitively (this class is
# `< ApplicationController`), so Redmine's REST-auth, CSRF, layout, and helper
# wiring are inherited unchanged.
class PulseBaseController < ApplicationController
  private

  # D2: module disabled -> 403 ; D3: no view_pulse -> 403 ; else true.
  # Identical for HTML and JSON (the per-surface difference is only in
  # visible_project, which the subclass owns).
  def authorize_pulse(project)
    unless project.module_enabled?(:pulse)
      render_403
      return false
    end
    unless User.current.allowed_to?(:view_pulse, project)
      render_403
      return false
    end
    true
  end

  # ── composition root: per-request adapter wiring ────────────────────────────

  def settings_provider
    @settings_provider ||= Pulse::Adapters::RedmineSettingsProvider.new
  end

  def clock
    @clock ||= Pulse::Adapters::SystemClock.new
  end

  def store
    @store ||= Pulse::Adapters::ActiveRecordSnapshotStore.new
  end

  def metrics_source
    @metrics_source ||= Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: settings_provider, clock: clock
    )
  end

  # C4: the ProfileProvider resolves the active scoring profile per viewer (transient
  # selection > role binding > system default). Injected into the engine so scoring is
  # driven by the resolved profile's config and the cache is profile-partitioned.
  def profile_provider
    @profile_provider ||= Pulse::Adapters::RedmineProfileProvider.new(
      settings_provider: settings_provider
    )
  end

  def engine
    @engine ||= Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: metrics_source, store: store,
      settings_provider: settings_provider, clock: clock,
      profile_provider: profile_provider
    )
  end

  # C4 (FC-C4-06): the canonical transient profile selection param is `profile_id` (the
  # validated-intent name). `profile` is retained ONLY as a backward-compat alias for callers
  # that predate the rename; `profile_id` wins when both are present. nil when neither is set
  # (=> role-default / system-default resolution inside the provider).
  def selected_profile_id
    params[:profile_id].presence || params[:profile].presence
  end
end
