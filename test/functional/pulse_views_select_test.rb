# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# ═══════════════════════════════════════════════════════════════════════════════
# IT-C5-05 — VIEW SELECTION applies lens + profile + scope (FC-C5-13 / FC-C5-16 /
#            FC-C5-17); AC-C5-05; lands C4's deferred FR-C4-03
# ═══════════════════════════════════════════════════════════════════════════════
# POST /pulse/views/:id/select (target resolved via visible_to) records the active view
# in session[:active_pulse_view_id]. A subsequent GET /pulse then:
#   (a) feeds the view's lens_ref to LensRanker.normalize_lens (active lens);
#   (b) feeds the view's profile_ref as the effective selected_profile_id into the engine
#       — the requested_id (level-1 transient selection) of RedmineProfileProvider#resolve,
#       LANDING C4's deferred FR-C4-03;
#   (c) filters the project set by project_scope / scope_params.
#
# DANGLING REFS (FC-C5-16, no 500):
#   * profile_ref removed -> RedmineProfileProvider#resolve falls back to 'default' AND
#     surfaces #last_warning (as-built, no new code).
#   * lens_ref unknown key -> LensRanker.normalize_lens ALREADY returns 'health', BUT
#     surfaces NO warning as-built (RC-C5-06). C5 MUST ADD a surfaced warning — asserted
#     here (see the dangling-lens test). The silent default is NOT sufficient.
#
# ADDITIVE-COMPAT (FC-C5-17): with no active view in session the cockpit behaves EXACTLY
# as pre-C5 (lens from params, full scope).
#
# RED-by-construction: the select route/action, session wiring, PulseView, and the
# dangling-lens warning do not exist yet. A9 implements GREEN.
#
# Postgres-evidence lane (COND-A8-004 / GL-CI-MYSQL): skip on non-Postgres.
class PulseViewsSelectTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'SelViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'sel_u')
    @p1 = create_project!(name: 'SelP1', identifier: 'sel-p1')
    @p2 = create_project!(name: 'SelP2', identifier: 'sel-p2')
    add_member!(project: @p1, principal: @user, role: @role)
    add_member!(project: @p2, principal: @user, role: @role)
    [@p1, @p2].each do |proj|
      create_issue!(project: proj, author: @user, status: open_status,
                    created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    end
  end

  def make_view(**attrs)
    PulseView.create!({ user_id: @user.id, visibility: 'private', project_scope: 'all',
                        name: 'Sel view' }.merge(attrs))
  end

  # ── FC-C5-13 — select stores the active view id in session ──

  def test_select_sets_active_view_in_session
    v = make_view(lens_ref: 'at_risk')
    login_as(@user)
    post "/pulse/views/#{v.id}/select"
    assert_includes [200, 302], response.status, 'select returns a redirect/ok'
    assert_equal v.id, session[:active_pulse_view_id],
                 'select must record the active view id in session[:active_pulse_view_id]'
  end

  def test_select_non_visible_view_is_404
    other = create_user!(login: 'sel_other')
    others_view = PulseView.create!(name: 'not yours', user_id: other.id, visibility: 'private',
                                    project_scope: 'all', lens_ref: 'health')
    login_as(@user)
    post "/pulse/views/#{others_view.id}/select"
    assert_response :not_found,
                    'selecting a view outside visible_to must 404 (resolved via the view store)'
  end

  # ── FC-C5-13 — a selected view drives the active lens ──

  def test_selected_view_applies_its_lens
    v = make_view(lens_ref: 'at_risk')
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success
    # The active lens is at_risk (from the selected view), not the default health. The
    # cockpit surfaces the active lens (selector state / lens vocabulary) — the selected
    # view's lens_ref must reach the rendered cockpit, not params.
    assert_match(/at_risk/, response.body,
                 "the selected view's lens_ref (at_risk) must drive the active cockpit lens")
  end

  # ── FC-C5-13 — a selected view drives the active profile (LANDS FR-C4-03) ──
  # The view's profile_ref becomes the effective selected_profile_id fed into
  # RedmineProfileProvider#resolve as the requested_id. We assert this by pointing the
  # view at a PUBLISHED admin profile and observing the cockpit resolve under it: a
  # dangling profile_ref surfaces last_warning (asserted separately); a VALID one resolves
  # cleanly. Here we assert the selection reaches the resolve path via the surfaced
  # warning on a KNOWN-dangling ref (the observable signal that profile_ref was consulted).
  def test_selected_view_profile_ref_feeds_the_resolve_path
    v = make_view(lens_ref: 'health', profile_ref: 'no-such-profile')
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success,
                    "a selected view whose profile_ref is dangling must still render 200 " \
                    '(the resolve path degrades to default, never 500)'
    # The surfaced warning proves the view's profile_ref was fed into the resolve path as
    # the requested_id (the same path as params[:profile_id]) — landing FR-C4-03.
    assert_match(/not a published profile|falling back|system default/i, response.body,
                 "the selected view's profile_ref must feed the resolve path and surface the " \
                 'dangling-fallback warning (proves FR-C4-03 selection wiring)')
  end

  # ── FC-C5-13 — project_scope=selected filters the project set ──

  def test_selected_view_with_selected_scope_filters_projects
    # TD-C5-02 (2026-07-06): the original assertion used refute_match(/SelP2/, response.body)
    # over the ENTIRE page body. The scope filter IS correct — the portfolio table renders only
    # SelP1's row (verified: one <tr>, href="/projects/sel-p1/pulse"). However, SelP2 also
    # appears in Redmine's core #project-jump dropdown chrome (the user is a member of SelP2),
    # which a plugin controller CANNOT suppress. The full-body assertion therefore fails on
    # valid production code. Fix: scope the assertion to the portfolio table (.list.pulse-portfolio
    # tbody) where project rows are rendered — this is the authoritative scope-filter signal.
    v = make_view(lens_ref: 'health', project_scope: 'selected',
                  scope_params: { 'project_ids' => [@p1.id] })
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success
    # SelP1 must appear in the portfolio table (in-scope project).
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelP1/,
                  message: 'the in-scope project P1 must appear in the portfolio table'
    # SelP2 must NOT appear in the portfolio table (out-of-scope — scope filter must exclude it).
    # We assert over the table, not the full body, because Redmine chrome (e.g. the project-jump
    # dropdown) contains project names the controller cannot suppress.
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelP2/, count: 0,
                  message: 'project_scope=selected must exclude SelP2 from the portfolio table'
  end

  # ── FR-C5-01 / FC-C5-13 — project_scope=status_filter narrows to matching PROJECT status ──
  # A10-C5-004 remediation: Select x status_filter must apply end-to-end. A status_filter view
  # stores a PROJECT status (Project::STATUS_ACTIVE/CLOSED/ARCHIVED) in scope_params[:status_id];
  # selecting it narrows the portfolio to the viewer's VISIBLE projects of that status only.
  #   - an ACTIVE project the viewer can see -> included
  #   - a CLOSED project the viewer can see (still visible via Project.visible) -> excluded
  #   - status_filter NEVER widens the visible set (visibility stays PRE-scope): a project the
  #     viewer is NOT a member of is absent regardless of its status.
  # Assert against the portfolio TABLE (TD-C5-02: Redmine chrome the plugin cannot suppress).
  def test_selected_view_with_status_filter_scope_narrows_by_project_status
    # A CLOSED project the viewer CAN see (member) — visible via Project.visible, but wrong status.
    closed_p = create_project!(name: 'SelClosed', identifier: 'sel-closed',
                               status: Project::STATUS_CLOSED)
    add_member!(project: closed_p, principal: @user, role: @role)
    create_issue!(project: closed_p, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))

    # A project the viewer is NOT a member of (invisible) — a status_filter=active view must
    # never surface it (status_filter narrows only; it can NOT widen the visible set).
    invisible_active = create_project!(name: 'SelInvisibleActive', identifier: 'sel-invis-active')
    refute Project.visible(@user).exists?(id: invisible_active.id),
           'test precondition: the invisible project must not be in the viewer\'s visible set'

    v = make_view(lens_ref: 'health', project_scope: 'status_filter',
                  scope_params: { 'status_id' => Project::STATUS_ACTIVE.to_s })
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success
    # ACTIVE, visible projects (SelP1/SelP2) are IN scope.
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelP1/,
                  message: 'an ACTIVE visible project must appear under status_filter=active'
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelP2/,
                  message: 'a second ACTIVE visible project must appear under status_filter=active'
    # The CLOSED (visible) project is OUT of scope — the status filter must exclude it.
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelClosed/, count: 0,
                  message: 'a CLOSED project must be excluded by status_filter=active (narrows by status)'
    # The invisible project must NEVER appear — status_filter cannot widen visibility.
    assert_select 'table.pulse-portfolio tbody tr td a', text: /SelInvisibleActive/, count: 0,
                  message: 'status_filter must NOT surface a project the viewer cannot see'
  end

  # ── FC-C5-16 — dangling profile_ref degrades to default + surfaced warning (no 500) ──

  def test_dangling_profile_ref_renders_200_with_warning
    v = make_view(lens_ref: 'health', profile_ref: 'deleted-profile-id')
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success, 'a dangling profile_ref must NOT 500 — it degrades to the default'
    assert_match(/not a published profile|falling back|system default/i, response.body,
                 'a dangling profile_ref must surface the RedmineProfileProvider warning')
  end

  # ── FC-C5-16 — dangling lens_ref degrades to health + surfaced warning (NEW, RC-C5-06) ──
  # As-built LensRanker.normalize_lens returns 'health' for an unknown key but surfaces NO
  # warning. C5 MUST ADD a surfaced warning for a dangling lens_ref. This test FAILS on the
  # silent-default impl (no warning) — the RC-C5-06 residual A8/A9 must discharge.
  def test_dangling_lens_ref_renders_200_with_surfaced_warning
    v = make_view(lens_ref: 'a-lens-that-was-removed', profile_ref: nil)
    login_as(@user)
    post "/pulse/views/#{v.id}/select"

    get '/pulse'
    assert_response :success, 'a dangling lens_ref must NOT 500 — it degrades to the default lens'
    assert_match(/lens/i, response.body,
                 'the cockpit still renders under the default (health) lens')
    # The NEW obligation (RC-C5-06): a surfaced warning for the dangling lens_ref. The
    # silent fallback alone is insufficient — a warning must be visible in the cockpit.
    assert_match(
      /is not (a )?(known|registered|available) lens|unknown lens|falling back to the (default|health) lens/i,
      response.body,
      'a dangling lens_ref must surface a warning (RC-C5-06: NOT present as-built; C5 must ADD it)'
    )
  end

  # ── FC-C5-17 — additive-compat: no active view -> pre-C5 behavior ──

  def test_no_active_view_uses_params_lens_baseline
    login_as(@user)
    # No select performed -> session has no active view. The cockpit resolves the lens
    # from params exactly as pre-C5.
    get '/pulse?lens=stale'
    assert_response :success
    assert_nil session[:active_pulse_view_id], 'no view is active without an explicit select'
    assert_match(/stale/, response.body,
                 'with no active view the cockpit uses params[:lens] (pre-C5 behavior, FC-C5-17)')
  end

  private

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end
end
