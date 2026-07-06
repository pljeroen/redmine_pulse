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
      projection, now: Time.now.utc, gantt_url: gantt_url_for(project),
      # C6 (FR-C6-08): the health-watch toggle state — offered only to a real logged-in
      # user (anonymous cannot own a subscription), reflecting their current watch state.
      watch_offer: User.current.logged?, watching: watching_health?(project)
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

  # The plugin-private polymorphic discriminator for the "Watch project health" opt-in — a
  # bare Watcher string, deliberately NOT a real AR watchable (the row's #watchable is never
  # dereferenced). It MUST equal the value the scan-side subscription reader keys on. Defined
  # here (as a literal, not by referencing the alert adapter's constant) so the request-cycle
  # code names NONE of the alert-pipeline symbols — the alert scan stays rake-only
  # (INV-ADDITIVE / T1-ADD-03). The scan-side reader and this writer share the same literal by
  # contract; the frozen recipient-permission suite covers that they agree.
  PULSE_HEALTH_WATCHABLE = 'PulseHealth'

  # POST /projects/:id/pulse/watch — the "Watch project health" opt-in (C6 / FR-C6-08).
  # A logged-in, :view_pulse-holding viewer subscribes THEMSELVES to the project's health
  # alerts by writing ONE plugin-private Watcher row (watchable_type PULSE_HEALTH_WATCHABLE,
  # watchable_id = project.id). That row is exactly what the scan reads via subscribers_for.
  # INV-ADDITIVE: this action writes a single subscription record and triggers NO scoring /
  # alert scan — the scan is reachable ONLY from the rake composition root. Watcher is a
  # plugin-agnostic membership table (NOT a Redmine scoring/alert domain model), so this stays
  # a read-only-toward-scoring action.
  def watch
    toggle_health_watch(subscribe: true)
  end

  # POST /projects/:id/pulse/unwatch — the inverse opt-out (idempotent).
  def unwatch
    toggle_health_watch(subscribe: false)
  end

  # ADMIN-ONLY: run `require_admin` (User.current.admin?) BEFORE #webhook_test — STRICTER than
  # the :view_pulse authorize_pulse ladder. A non-admin (incl. a :view_pulse-only user) and an
  # anonymous request are FORBIDDEN (403/redirect) with NO dispatch. This is the SOLE
  # request-cycle webhook gate (FR-C7-09 / FC-C7-08). Scoped to webhook_test only so the
  # read-only pulse surface is unaffected.
  before_action :require_admin, only: :webhook_test

  # POST /pulse/webhook_test — the admin "send test event" diagnostic (C7 / FR-C7-09).
  # Builds a SYNTHETIC AlertEvent (+ synthetic Project + HealthResult + previous) OFF the domain
  # scan path and delivers it to EXACTLY ONE operator-selected global endpoint (params[:endpoint]
  # is its index) via the SHARED HttpWebhookDispatcher pipeline (HTTPS -> SSRF -> serialize ->
  # HMAC -> POST, ~5s timeout), then SURFACES the resulting HTTP status / error class to the
  # operator via flash. It contacts ONE endpoint, never the full list.
  def webhook_test
    endpoints = configured_global_endpoints
    endpoint = endpoints[params[:endpoint].to_i]
    if endpoint.nil?
      flash[:error] = I18n.t(:error_pulse_webhook_no_endpoint,
                             default: 'No webhook endpoint is configured at that position.')
      return redirect_to plugin_settings_path(id: 'redmine_pulse')
    end

    result = deliver_test_event(endpoint)
    if result[:ok]
      flash[:notice] = I18n.t(:notice_pulse_webhook_test_ok, status: result[:status],
                              default: 'Test webhook delivered (HTTP %{status}).')
    elsif result[:status]
      flash[:error] = I18n.t(:error_pulse_webhook_test_status, status: result[:status],
                             default: 'Test webhook returned HTTP %{status}.')
    else
      flash[:error] = I18n.t(:error_pulse_webhook_test_error, error: result[:error],
                             default: 'Test webhook failed: %{error}.')
    end
    redirect_to plugin_settings_path(id: 'redmine_pulse')
  end

  private

  # The configured global webhook endpoints (sanitized-at-write plugin settings). [] when OFF.
  def configured_global_endpoints
    settings = Setting.plugin_redmine_pulse
    settings = {} unless settings.is_a?(Hash)
    Array(settings['pulse_webhook_endpoints_global']).select { |ep| ep.is_a?(Hash) }
  end

  # Build the synthetic delivery inputs and run the ONE-endpoint diagnostic through the shared
  # dispatcher. Returns { ok:, status:, error: }. The synthetic Project/HealthResult are plain
  # duck-typed value carriers (Struct) so no domain scan or Redmine read is triggered here — the
  # request cycle stays scan-free (INV-ADDITIVE). The synthetic Project#id mirrors the AlertEvent
  # project_id so the payload is self-consistent (a representative id, not a real project read).
  def deliver_test_event(endpoint)
    occurred_at = Time.now.utc
    event = Pulse::Domain::AlertEvent.new(
      project_id: 1, event_type: :rag_transition, from: 'green', to: 'amber',
      score: 58, previous_score: 72, delta: -14.0, occurred_at: occurred_at
    )
    project = WebhookTestProject.new(1, 'pulse-webhook-test', 'Pulse webhook test')
    health = WebhookTestHealth.new(58, :amber, :risk_load)
    previous = { rag: 'green', dominant_signal: 'momentum' }

    Pulse::Adapters::HttpWebhookDispatcher.new.deliver_test(
      event, endpoint, project: project, health_result: health, previous: previous
    )
  end

  # Synthetic duck-typed carriers for the test-event payload (id/identifier/name;
  # health_score/rag/dominant_signal) — the serializer reads these plain readers, so no real
  # Project/HealthResult (and thus no Redmine/domain read) is needed on the request cycle.
  WebhookTestProject = Struct.new(:id, :identifier, :name)
  WebhookTestHealth = Struct.new(:health_score, :rag, :dominant_signal)

  # Shared body for watch/unwatch: run the EXACT 404/403 visibility ladder (existence not
  # leaked; module-off / no-view_pulse -> 403), require a real logged-in user (anonymous
  # cannot own a subscription), toggle the subscription Watcher row, then redirect back to the
  # panel. The write is confined to ONE plugin-private Watcher row — no scoring/alert symbol is
  # named or invoked in the request cycle (INV-ADDITIVE).
  def toggle_health_watch(subscribe:)
    project = visible_project(params[:id])
    return if project.nil? # 404 already rendered

    return unless authorize_pulse(project) # 403 already rendered when false

    if User.current.logged?
      if subscribe
        # Idempotent: the Watcher unique index on [user_id, watchable_type, watchable_id]
        # makes a repeat a no-op.
        Watcher.find_or_create_by!(watchable_type: PULSE_HEALTH_WATCHABLE,
                                   watchable_id: project.id, user_id: User.current.id)
      else
        Watcher.where(watchable_type: PULSE_HEALTH_WATCHABLE, watchable_id: project.id,
                      user_id: User.current.id).delete_all
      end
      flash[:notice] = I18n.t(subscribe ? :notice_pulse_health_watched : :notice_pulse_health_unwatched)
    end
    redirect_to project_pulse_path(id: project.identifier)
  end

  # Whether the current viewer holds an explicit "Watch project health" subscription on the
  # project (the toggle state the panel renders). Read-only; a bare Watcher-row existence check
  # keyed on the same plugin-private discriminator the scan reads.
  def watching_health?(project)
    return false unless User.current.logged?

    Watcher.where(watchable_type: PULSE_HEALTH_WATCHABLE, watchable_id: project.id,
                  user_id: User.current.id).exists?
  end

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
