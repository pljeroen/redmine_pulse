# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseController — the HTML adapter surface + composition root (CA-10/11/12).
# It instantiates the Redmine adapters per request and injects them into the pure-
# domain Scoring/Timeline functions via PulseProjection::Engine; the ERB views render
# ONLY the precomputed HtmlPresenter view-model (COND-A4-001/002).
#
# Access: per-project show/refresh enforce the EXACT 404/403 decision (FC-CA-01/02):
#   not in Project.visible(viewer) / nonexistent / archived -> 404 (existence not
#   leaked); visible-but-module-off or visible-but-no-view_pulse -> 403; else 200.
# Read-only: GET writes nothing on Redmine domain tables; refresh writes only
# pulse_snapshots (INV-READ-ONLY / FC-CA-11/13).
class PulseController < PulseBaseController
  # No global require_login: anonymous access is governed by the per-project
  # visibility + permission ladder (R7 — anonymous holding view_pulse on a PUBLIC,
  # module-enabled project gets 200; otherwise Project.visible excludes it -> 404, or
  # the authorize ladder -> 403). The portfolio overview is likewise visibility-scoped.

  # GET /pulse — portfolio overview (never 404/403 for selection; empty -> 200).
  def index
    active = active_pulse_view # C5: the selected saved view (visible-only) or nil (pre-C5 path)

    # C5 (FC-C5-13/16/17): an active view drives the lens (surfacing a dangling-lens_ref
    # warning); with no active view the lens comes from params[:lens] exactly as pre-C5.
    if active&.lens_ref
      lens, lens_warning = Pulse::Adapters::LensRanker.normalize_lens_with_warning(active.lens_ref)
    else
      lens = Pulse::Adapters::LensRanker.normalize_lens(params[:lens])
      lens_warning = nil
    end

    # C5 (FC-C5-13): an active view's profile_ref is the effective selected_profile_id fed into
    # the resolve path (the requested_id — landing C4's deferred FR-C4-03); else the params path.
    # A dangling id degrades to the system default inside the provider (surfaced as a banner).
    profile_id = active&.profile_ref.presence || selected_profile_id
    projections = engine.portfolio_projections(User.current, profile_id)

    # C5 (FC-C5-13): project_scope pre-filters the portfolio before ranking (a new pre-filter
    # step; the engine internals are untouched). 'selected' -> scope_params[:project_ids].
    projections = apply_view_scope(projections, active)

    ranked = Pulse::Adapters::LensRanker.rank(projections, lens)
    @view = Pulse::Adapters::HtmlPresenter.portfolio_view(
      ranked, lens: lens, now: Time.now.utc, lens_warning: lens_warning
    )
    render template: 'pulse/index'
  end

  # GET /projects/:id/pulse — one project's health panel.
  def show
    project = visible_project(params[:id])
    return if project.nil? # 404 already rendered

    return unless authorize_pulse(project) # 403 already rendered when false

    # C4: the transient profile selection (?profile_id=<id>) — a per-request override that
    # beats the viewer's role binding (FC-C4-06 level 1). A dangling id degrades to the
    # system default inside the provider (never a crash). Visibility scoping stays
    # PRE-profile (INV-C4-PERM-UNCHANGED) — the profile only reweights visible metrics.
    projection = engine.project_projection(User.current, project, selected_profile_id)
    @view = Pulse::Adapters::HtmlPresenter.panel_view(
      projection, now: Time.now.utc, gantt_url: gantt_url_for(project)
    )
    render template: 'pulse/show'
  end

  # Deep-link to Redmine's built-in project Gantt, but ONLY when the viewer is actually
  # allowed to see it — allowed_to?(:view_gantt, project) is false when the :gantt module
  # is disabled OR the viewer lacks the permission, so the panel never offers a link that
  # would 403 on click. The route helper (not a hand-built path) honours Project#to_param
  # and any relative_url_root (sub-URI) deployment.
  def gantt_url_for(project)
    return nil unless User.current.allowed_to?(:view_gantt, project)

    project_gantt_path(project)
  end

  # POST /pulse/refresh — invalidate the target project's cached snapshots only.
  def refresh
    project = visible_project(params[:project_id])
    return if project.nil?

    return unless authorize_pulse(project)

    # RT-06 (security-S2-dos): scope the eviction to the ACTING caller's own visibility
    # context only. invalidate_project would delete EVERY visibility context's rows for the
    # project, letting one viewer evict every other viewer's warmed snapshot (a cross-context
    # cache-stampede lever). Deleting only (project_id, this caller's ctx id) keeps the blast
    # radius to the caller. (The rake pulse:cache:clear task keeps using invalidate_project /
    # clear_all for the deliberate admin-driven global flush.)
    caller_ctx = Pulse::Adapters::VisibilityContext.new(User.current, project).id
    store.invalidate_context(project.id, caller_ctx)
    flash[:notice] = I18n.t('pulse.refresh_done')
    redirect_to project_pulse_path(id: project.identifier)
  end

  private

  # ── C5 saved-view selection wiring (FC-C5-13/16/17) ─────────────────────────

  # The active saved view for this request, resolved THROUGH the ViewStore visibility gate
  # (session[:active_pulse_view_id]). Returns nil when no view is selected OR the referenced
  # view is no longer visible to the viewer — in which case the cockpit behaves EXACTLY as
  # pre-C5 (additive-compat, FC-C5-17). Never raises.
  def active_pulse_view
    id = session[:active_pulse_view_id]
    return nil if id.nil?

    view_store.find_visible(id, User.current)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Pre-filter the ranked-input projections by the active view's project_scope (FC-C5-13). This
  # is a controller-side pre-filter — the engine internals are untouched. It only ever NARROWS
  # the already-visibility-scoped portfolio; it NEVER widens the visible project set (visibility
  # stays PRE-scope). 'all' / no active view -> no change.
  #   'selected'      -> keep only scope_params[:project_ids].
  #   'status_filter' -> keep only projects whose PROJECT status (Project#status:
  #                      STATUS_ACTIVE=1 / STATUS_CLOSED=5 / STATUS_ARCHIVED=9) equals the view's
  #                      stored scope_params[:status_id] (FR-C5-01). A blank/unset status filter
  #                      leaves the portfolio unchanged (no coherent narrowing target).
  def apply_view_scope(projections, active)
    return projections if active.nil?

    case active.project_scope
    when 'selected'
      apply_selected_scope(projections, active)
    when 'status_filter'
      apply_status_filter_scope(projections, active)
    else
      projections
    end
  end

  # 'selected' -> intersect the (already-visible) portfolio with scope_params[:project_ids].
  # A submitted id for a project the viewer cannot see cannot widen the set: the projection
  # list is already visibility-scoped, so a non-visible id simply matches nothing.
  def apply_selected_scope(projections, active)
    ids = Array((active.scope_params || {})['project_ids'] ||
                (active.scope_params || {})[:project_ids]).map(&:to_i)
    return projections if ids.empty?

    projections.select { |p| ids.include?(p.project.id) }
  end

  # 'status_filter' -> keep only projects whose Project#status matches the view's stored status.
  # Narrows only: the projection list is already visibility-scoped, so this can never surface a
  # project the viewer cannot see. A blank/unparseable status leaves the portfolio unchanged.
  def apply_status_filter_scope(projections, active)
    raw = (active.scope_params || {})['status_id'] || (active.scope_params || {})[:status_id]
    status = raw.to_s.strip
    return projections if status.empty?

    status = status.to_i
    projections.select { |p| p.project.status == status }
  end

  # The composition-root ViewStore adapter (config store for pulse_views; never pulse_snapshots).
  def view_store
    @view_store ||= Pulse::Adapters::ActiveRecordViewStore.new
  end

  # ── the EXACT 404/403 ladder (FC-CA-02 D1..D4) ──────────────────────────────

  # D1: not in Project.visible / nonexistent / archived -> 404 (existence not leaked).
  # HTML-specific: assigns @project so Redmine's base layout renders the project
  # context/menu (the JSON surface deliberately does NOT — hence per-controller).
  # authorize_pulse + the adapter-factory composition root live in
  # PulseBaseController (shared, identical across both surfaces).
  def visible_project(identifier)
    project = Project.visible(User.current).find_by(identifier: identifier)
    render_404 if project.nil?
    @project = project
    project
  end
end
