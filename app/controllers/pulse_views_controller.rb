# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseViewsController — the saved-views CRUD + selection surface.
# TOP-LEVEL constant at app/controllers/pulse_views_controller.rb (matches the
# PulseController / PulseApiController convention; NOT Pulse::ViewsController — that would
# require a pulse/ subdir Zeitwerk cannot resolve, the exact production-boot NameError the
# project has hit before).
#
# SECURITY:
#   * Every action that targets a view resolves it through @view_store.find_visible(id, user)
#     — the ViewStore port routed to PulseView.visible_to. A view outside the caller's visible
#     set raises RecordNotFound -> 404 (EXISTENCE HIDING). This runs on EVERY format (HTML +
#     .json): Redmine 6.x .json routing does NOT inherit session authorization, so the re-check
#     is server-side and format-unconditional. 404 (not 403) is pinned for a non-visible READ so
#     the caller cannot distinguish "does not exist" from "exists but private".
#   * Publishing (visibility public/roles on create/update) is gated by the GLOBAL permission
#     :manage_public_pulse_views (allowed_to?(..., nil, global: true)); absent -> 403 BEFORE any
#     persistence. Private views need only :view_pulse.
#   * edit/update/destroy: a system_view? (built-in) target -> 403 UNCONDITIONALLY for ALL users
#     (incl admins / global-permission holders), BEFORE the ownership check. Otherwise owner? OR
#     the global permission; else 403. WRITE denial is 403 (distinct from the READ 404).
#
# PERSISTENCE-BEHIND-PORT: the controller NEVER calls PulseView AR methods directly.
# Every persistence op goes through @view_store (Pulse::Adapters::ActiveRecordViewStore, injected
# per-request at the composition root). The AR scope stays inside the adapter.
class PulseViewsController < PulseBaseController
  # Redmine 6.x .json routing does NOT inherit session auth — the API-key credential is honoured
  # only on actions that opt into API auth. The saved-views .json surface (read + write) must
  # authenticate the caller so the SERVER-SIDE visibility re-check runs against the real user
  # (the positive-control public .json read must resolve as user_b, not anonymous). The re-check
  # itself (visible_to -> 404) is what hides existence; accept_api_auth only establishes identity.
  accept_api_auth :index, :show, :create, :update, :destroy, :select

  before_action :wire_view_store
  before_action :authorize_view_pulse
  before_action :load_view, only: %i[show edit update destroy select]
  before_action :authorize_edit_view, only: %i[edit update destroy]

  # A non-visible target 404s (existence hiding) on EVERY format — the adapter's scoped find
  # raises RecordNotFound, mapped here to Redmine's 404.
  rescue_from ActiveRecord::RecordNotFound do
    render_404
  end

  # GET /pulse/views — list ONLY the views visible to the caller.
  def index
    @views = @view_store.visible_to(User.current).to_a
    respond_to do |format|
      format.html { render template: 'pulse_views/index' }
      format.json { render json: @views.map { |v| view_json(v) } }
    end
  end

  # GET /pulse/views/new — the create form.
  def new
    @view = PulseView.new(visibility: 'private', project_scope: 'all')
    render template: 'pulse_views/new'
  end

  # POST /pulse/views — create a saved view owned by the requester. Publishing public/roles
  # is gated by the GLOBAL permission BEFORE persistence.
  def create
    return if deny_publish_without_permission(view_params[:visibility])

    attrs = view_params.to_h.symbolize_keys.merge(user_id: User.current.id)
    @view = @view_store.create(attrs)

    if @view.persisted?
      respond_to do |format|
        format.html { redirect_to pulse_views_path, notice: I18n.t(:notice_successful_create) }
        format.json { render json: view_json(@view), status: :created }
      end
    else
      respond_to do |format|
        format.html { render template: 'pulse_views/new', status: :unprocessable_entity }
        format.json { render json: { errors: @view.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # GET /pulse/views/:id[.json] — show one visible view. A non-visible id already 404'd in
  # load_view (existence hiding, every format).
  def show
    respond_to do |format|
      format.html { render template: 'pulse_views/show' }
      format.json { render json: view_json(@view) }
    end
  end

  # GET /pulse/views/:id/edit — the edit form (owner / global-permission holder; built-ins 403).
  def edit
    render template: 'pulse_views/edit'
  end

  # PATCH /pulse/views/:id — update. Publishing public/roles gated by the GLOBAL permission.
  def update
    return if deny_publish_without_permission(view_params[:visibility])

    if @view_store.update(@view, view_params.to_h.symbolize_keys)
      respond_to do |format|
        format.html { redirect_to pulse_views_path, notice: I18n.t(:notice_successful_update) }
        format.json { render json: view_json(@view) }
      end
    else
      respond_to do |format|
        format.html { render template: 'pulse_views/edit', status: :unprocessable_entity }
        format.json { render json: { errors: @view.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /pulse/views/:id — destroy (owner / global-permission holder; built-ins 403).
  def destroy
    @view_store.destroy(@view)
    respond_to do |format|
      format.html { redirect_to pulse_views_path, notice: I18n.t(:notice_successful_delete) }
      format.json { head :no_content }
    end
  end

  # POST /pulse/views/:id/select — activate the view (records session[:active_pulse_view_id]).
  # A built-in system view IS selectable (selectable != editable). A non-visible target 404'd
  # in load_view.
  def select
    session[:active_pulse_view_id] = @view.id
    respond_to do |format|
      format.html { redirect_to pulse_path }
      format.json { head :no_content }
    end
  end

  private

  # Module + permission gate for the whole saved-views surface. The saved-views surface is
  # portfolio-wide (not project-scoped), so :view_pulse is checked globally (holding it on
  # any project satisfies the cockpit-viewer requirement) — consistent with the top-menu link.
  def authorize_view_pulse
    return true if User.current.allowed_to?(:view_pulse, nil, global: true)

    render_403
    false
  end

  # Resolve the target THROUGH the visibility scope (ViewStore port). A non-visible id raises
  # RecordNotFound (rescued -> 404). Runs on EVERY format.
  def load_view
    @view = @view_store.find_visible(params[:id], User.current)
  end

  # edit/update/destroy gate. A system_view? (built-in) is immutable for ALL users -> 403
  # BEFORE the ownership check. Otherwise owner? OR the GLOBAL :manage_public_pulse_views; else 403.
  def authorize_edit_view
    if @view.system_view?
      render_403
      return false
    end
    return true if @view.owner?(User.current)
    return true if User.current.allowed_to?(:manage_public_pulse_views, nil, global: true)

    render_403
    false
  end

  # Publishing a public/roles view requires the GLOBAL :manage_public_pulse_views permission.
  # Returns true (and renders 403) when the submitted visibility is public/roles and the caller
  # lacks it — the caller returns early BEFORE any persistence.
  def deny_publish_without_permission(visibility)
    return false unless %w[public roles].include?(visibility.to_s)
    return false if User.current.allowed_to?(:manage_public_pulse_views, nil, global: true)

    render_403
    true
  end

  # Composition root: inject the ViewStore adapter before any action / before_action uses it.
  # The controller talks ONLY to @view_store — never to PulseView directly.
  def wire_view_store
    @view_store = Pulse::Adapters::ActiveRecordViewStore.new
  end

  # Strong params for the saved-view record. role_ids / scope_params / sort / prefs are the
  # structured (Array / Hash) columns the GUI form authors: role_ids is
  # an Array of role ids (roles visibility); scope_params carries project_ids (selected scope)
  # and status_id (status_filter scope); sort is a 2-element [column, direction] Array; prefs is
  # a free-form scalar Hash of threshold/column preferences. Permitting the exact scope_params
  # shape (rather than a bare `scope_params: {}`) keeps the accepted nesting explicit — the
  # server-side publish gate, visibility re-check, and system-view immutability are unchanged.
  def view_params
    params.require(:pulse_view).permit(
      :name, :visibility, :project_scope, :lens_ref, :profile_ref,
      role_ids: [], sort: [], prefs: {},
      scope_params: [:status_id, { project_ids: [] }]
    )
  end

  # The JSON representation of a view (used for index/show/create .json responses).
  def view_json(view)
    {
      id: view.id,
      name: view.name,
      user_id: view.user_id,
      visibility: view.visibility,
      role_ids: view.role_ids_array,
      project_scope: view.project_scope,
      scope_params: view.scope_params,
      lens_ref: view.lens_ref,
      profile_ref: view.profile_ref,
      sort: view.sort,
      prefs: view.prefs,
      system: view.system_view?
    }
  end
end
