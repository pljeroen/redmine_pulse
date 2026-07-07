# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# ═══════════════════════════════════════════════════════════════════════════════
# SAVED-VIEW VISIBILITY MODEL (a security-critical guarantee)
# ═══════════════════════════════════════════════════════════════════════════════
# The saved-view visibility model mirrors IssueQuery:
#   * PRIVATE view  -> visible ONLY to its owner (user_id == viewer.id)
#   * PUBLIC  view  -> visible to ANY cockpit viewer (holds :view_pulse)
#   * ROLES   view  -> visible ONLY to members holding a listed role (role_ids)
# Views are PRIVATE by default. Publishing a public/role-scoped view is
# gated by the GLOBAL permission :manage_public_pulse_views — the check is
# User.current.allowed_to?(:manage_public_pulse_views, nil, global: true). Per stock
# Redmine semantics (confirmed by live probe), that GLOBAL check is satisfied
# by holding the permission through a role on ANY project — a per-project role DOES count.
# The negative control is therefore a user who holds the permission in NO project at all
# (test_publish_denied_without_manage_public_permission); such a user is denied (403).
#
# Enforcement lives at BOTH the AR scope PulseView.visible_to (the single authoritative
# read gate) AND the controller (index returns only visible_to(User.current);
# a non-visible id -> 404 before the action body reads it).
#
# Runs on PostgreSQL (the production engine): the visible_to scope composes member/role
# SQL that must be verified on the deployed engine; skip (not fail) on a non-Postgres
# adapter so the MySQL CI legs stay green.
class PulseViewsVisibilityTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end

    # A cockpit-viewer role (holds :view_pulse) but NOT the global publish permission.
    @viewer_role = create_role!(name: 'VViewer', issues_visibility: 'all',
                                permissions: %i[view_issues view_pulse])
    # A role that grants the GLOBAL publish permission.
    @publisher_role = create_role!(name: 'VPublisher', issues_visibility: 'all',
                                   permissions: %i[view_issues view_pulse manage_public_pulse_views])
    # The role that role-scoped views target (distinct from the unrelated role below).
    @manager_role = create_role!(name: 'VManager', issues_visibility: 'all',
                                 permissions: %i[view_issues view_pulse])
    @unrelated_role = create_role!(name: 'VUnrelated', issues_visibility: 'all',
                                   permissions: %i[view_issues view_pulse])

    @project = create_project!(name: 'VProj', identifier: 'vproj')
    @other_project = create_project!(name: 'VOther', identifier: 'vother')

    @user_a = create_user!(login: 'vis_a')      # owner of the private view
    @user_b = create_user!(login: 'vis_b')      # non-owner cockpit viewer
    @manager = create_user!(login: 'vis_mgr')   # holds @manager_role on @project
    @non_manager = create_user!(login: 'vis_nm') # holds @unrelated_role only

    add_member!(project: @project, principal: @user_a, role: @viewer_role)
    add_member!(project: @project, principal: @user_b, role: @viewer_role)
    add_member!(project: @project, principal: @manager, role: @manager_role)
    add_member!(project: @project, principal: @non_manager, role: @unrelated_role)
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  # Create a PulseView row directly through the model (setup fixture, not a controller
  # action) so the read-side scope assertions are independent of the create gate.
  def make_view(name:, user: nil, visibility: 'private', role_ids: nil, lens_ref: 'health')
    attrs = { name: name, user_id: user&.id, visibility: visibility,
              project_scope: 'all', lens_ref: lens_ref }
    attrs[:role_ids] = role_ids if role_ids
    PulseView.create!(attrs)
  end

  # ── the visible_to READ scope (single authoritative gate) ──

  def test_private_view_invisible_to_non_owner_via_scope
    v = make_view(name: 'A private', user: @user_a, visibility: 'private')

    refute_includes PulseView.visible_to(@user_b).to_a, v,
                    'LEAK: user_a private view appeared in visible_to(user_b)'
    assert_includes PulseView.visible_to(@user_a).to_a, v,
                    "owner (user_a) must see their own private view"
  end

  def test_public_view_visible_to_any_cockpit_viewer_via_scope
    v = make_view(name: 'Shared public', user: @user_a, visibility: 'public')

    assert_includes PulseView.visible_to(@user_b).to_a, v,
                    'public view must be in visible_to(any cockpit viewer)'
  end

  def test_role_scoped_view_visible_only_to_role_holders_via_scope
    v = make_view(name: 'Managers only', user: @user_a, visibility: 'roles',
                  role_ids: [@manager_role.id])

    assert_includes PulseView.visible_to(@manager).to_a, v,
                    'role-scoped view must be visible to a holder of the listed role'
    refute_includes PulseView.visible_to(@non_manager).to_a, v,
                    'LEAK: role-scoped view visible to a user WITHOUT the listed role'
  end

  def test_default_visibility_is_private_owner_only
    # No explicit visibility -> private. Owner sees it; a non-owner does not.
    v = PulseView.create!(name: 'Defaulted', user_id: @user_a.id, project_scope: 'all',
                          lens_ref: 'health')
    assert_equal 'private', v.reload.visibility,
                 'a view with no explicit visibility must default to private'
    assert_includes PulseView.visible_to(@user_a).to_a, v, 'owner sees the defaulted-private view'
    refute_includes PulseView.visible_to(@user_b).to_a, v,
                    'LEAK: defaulted-private view visible to a non-owner'
  end

  # ── the controller index returns only visible_to(User.current) ──

  def test_index_omits_other_users_private_view
    private_a = make_view(name: 'A-only private', user: @user_a, visibility: 'private')
    public_v  = make_view(name: 'Everyone public', user: @user_a, visibility: 'public')

    login_as(@user_b)
    get '/pulse/views'
    assert_response :success

    assert_includes response.body, 'Everyone public',
                    'index must list the public view for user_b'
    refute_includes response.body, 'A-only private',
                    "LEAK: user_a's private view name leaked into user_b's index"
    assert private_a.persisted? && public_v.persisted?
  end

  def test_index_omits_role_scoped_view_from_non_role_holder
    make_view(name: 'Manager dashboard', user: @user_a, visibility: 'roles',
              role_ids: [@manager_role.id])

    login_as(@non_manager)
    get '/pulse/views'
    assert_response :success
    refute_includes response.body, 'Manager dashboard',
                    'LEAK: role-scoped view leaked to a non-role-holder via index'
  end

  def test_controller_show_of_non_visible_view_is_404_not_200
    private_a = make_view(name: 'A-only', user: @user_a, visibility: 'private')

    login_as(@user_b)
    get "/pulse/views/#{private_a.id}"
    assert_response :not_found,
                    'a non-visible view id must 404 (existence hiding) BEFORE the body renders — not 200'
  end

  # ── publish gate: public/roles requires the GLOBAL permission ──

  def test_publish_public_denied_without_global_permission
    # @user_b holds only :view_pulse (viewer role) — no manage_public_pulse_views.
    login_as(@user_b)
    assert_no_difference -> { PulseView.count } do
      post '/pulse/views', params: { pulse_view: view_params(visibility: 'public') }
    end
    assert_response :forbidden,
                    'publishing a PUBLIC view without the global :manage_public_pulse_views -> 403'
  end

  def test_publish_roles_denied_without_global_permission
    login_as(@user_b)
    assert_no_difference -> { PulseView.count } do
      post '/pulse/views',
           params: { pulse_view: view_params(visibility: 'roles', role_ids: [@manager_role.id]) }
    end
    assert_response :forbidden,
                    'publishing a ROLE-SCOPED view without the global permission -> 403'
  end

  def test_private_create_allowed_for_any_view_pulse_holder
    login_as(@user_b)
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views', params: { pulse_view: view_params(visibility: 'private') }
    end
    assert_includes [200, 201, 302], response.status,
                    'creating a PRIVATE view needs only :view_pulse (no publish permission)'
    created = PulseView.order(:id).last
    assert_equal @user_b.id, created.user_id, 'the created private view is owned by the requester'
    assert_equal 'private', created.visibility
  end

  def test_publish_public_allowed_for_global_permission_holder
    publisher = create_user!(login: 'vis_pub')
    add_member!(project: @project, principal: publisher, role: @publisher_role)

    login_as(publisher)
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views', params: { pulse_view: view_params(visibility: 'public') }
    end
    assert_includes [200, 201, 302], response.status,
                    'a GLOBAL holder of :manage_public_pulse_views may publish a public view'
    assert_equal 'public', PulseView.order(:id).last.visibility
  end

  # ── POSITIVE CONTROL — a GLOBAL holder publishes a ROLE-SCOPED view ──
  # The create tests covered public-publish success and roles-publish DENIAL, but
  # not roles-publish SUCCESS by a global-permission holder. This completes the publish matrix:
  # visibility=roles with role_ids, by a :manage_public_pulse_views holder, persists as roles
  # with the submitted role_ids (the publish gate ALLOWS it; the row is a real role-scoped view).
  def test_publish_roles_allowed_for_global_permission_holder
    publisher = create_user!(login: 'vis_rpub')
    add_member!(project: @project, principal: publisher, role: @publisher_role)

    login_as(publisher)
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views',
           params: { pulse_view: view_params(visibility: 'roles', role_ids: [@manager_role.id]) }
    end
    assert_includes [200, 201, 302], response.status,
                    'a GLOBAL holder of :manage_public_pulse_views may publish a ROLE-SCOPED view'
    created = PulseView.order(:id).last
    assert_equal 'roles', created.visibility, 'the published view persists as roles'
    assert_equal [@manager_role.id], created.role_ids_array,
                 'the submitted role_ids round-trip onto the persisted role-scoped view'
    # The role-scoped view is now visible to a holder of the listed role, not to a non-holder.
    assert_includes PulseView.visible_to(@manager).to_a, created,
                    'the published role-scoped view is visible to a holder of the listed role'
    refute_includes PulseView.visible_to(@non_manager).to_a, created,
                    'LEAK: the published role-scoped view is visible to a non-role-holder'
  end

  # ── GUI CRUD completeness for the previously-unauthorable ops ──
  # These POST the exact structured params the _form partial emits (role_ids[], and
  # scope_params[project_ids][]) so the previously-BROKEN GUI create paths (visibility=roles,
  # project_scope=selected) are proven end-to-end: persist -> render -> visible per visibility.

  # A global holder authoring a ROLE-SCOPED view through the form (role_ids[] like the multi-
  # select) creates a roles view that renders on the author's index and is visible to a holder
  # of the listed role only.
  def test_form_creates_role_scoped_view_end_to_end
    publisher = create_user!(login: 'vis_frole')
    add_member!(project: @project, principal: publisher, role: @publisher_role)

    login_as(publisher)
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views', params: { pulse_view: {
        name: 'Form role view', visibility: 'roles', project_scope: 'all',
        lens_ref: 'health', role_ids: [@manager_role.id.to_s]
      } }
    end
    created = PulseView.order(:id).last
    assert_equal 'roles', created.visibility
    assert_equal [@manager_role.id], created.role_ids_array,
                 'the form multi-select role_ids[] persisted onto the created role-scoped view'

    # Renders per visibility: a holder of the listed role sees it on THEIR index (the author,
    # a publisher, does NOT hold @manager_role, so the roles view is intentionally NOT on the
    # author's own index — visibility='roles' targets role holders, not the creator).
    login_as(@manager)
    get '/pulse/views'
    assert_response :success
    assert_includes response.body, 'Form role view',
                    'the form-created role-scoped view renders on a role-holder index'

    # Visible per visibility: to a role holder, not to a non-holder.
    assert_includes PulseView.visible_to(@manager).to_a, created
    refute_includes PulseView.visible_to(@non_manager).to_a, created,
                    'LEAK: the form-created role-scoped view visible to a non-role-holder'
  end

  # A private, SELECTED-scope view authored through the form (scope_params[project_ids][] like
  # the project multi-select) persists the scope params and round-trips them.
  def test_form_creates_selected_scope_view_end_to_end
    login_as(@user_b) # any :view_pulse holder — a private view needs no publish permission
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views', params: { pulse_view: {
        name: 'Form scoped view', visibility: 'private', project_scope: 'selected',
        lens_ref: 'health',
        scope_params: { project_ids: [@project.id.to_s] }
      } }
    end
    assert_includes [200, 201, 302], response.status,
                    'a private selected-scope view needs only :view_pulse'
    created = PulseView.order(:id).last
    assert_equal 'private', created.visibility
    assert_equal 'selected', created.project_scope
    assert_equal [@project.id.to_s], Array((created.scope_params || {})['project_ids']),
                 'the form scope_params[project_ids][] persisted onto the created view'

    # Renders + visible to its owner only.
    get '/pulse/views'
    assert_response :success
    assert_includes response.body, 'Form scoped view', 'the created selected-scope view renders for its owner'
    assert_includes PulseView.visible_to(@user_b).to_a, created
    refute_includes PulseView.visible_to(@user_a).to_a, created,
                    'LEAK: a private selected-scope view visible to a non-owner'
  end

  # ── NEGATIVE CONTROL — no permission in any project ──
  # (2026-07-06): the original test asserted that a user holding
  # :manage_public_pulse_views via a per-project role on an UNRELATED project would NOT
  # satisfy allowed_to?(..., nil, global: true). This assumption was wrong: stock Redmine's
  # User#allowed_to?(action, nil, global: true) returns TRUE if the user holds the
  # permission through a role on ANY project — a per-project role DOES count toward the
  # global check (confirmed by live probe, verified against the sibling POSITIVE test
  # test_publish_public_allowed_for_global_permission_holder which uses the same role
  # topology and asserts the inverse). The original per-project-scoping assumption
  # contradicts stock Redmine semantics and was therefore a test-model defect, not a
  # production bug. The security guarantee ("publishing requires the permission") is
  # preserved: the REAL negative control is a user who holds the permission in NO project.
  def test_publish_denied_without_manage_public_permission
    no_publish_user = create_user!(login: 'vis_nop')
    # This user holds ONLY @viewer_role on @project — a role that does NOT grant
    # :manage_public_pulse_views. They have no membership on any other project.
    # allowed_to?(:manage_public_pulse_views, nil, global: true) is therefore false.
    add_member!(project: @project, principal: no_publish_user, role: @viewer_role)

    refute no_publish_user.allowed_to?(:manage_public_pulse_views, nil, global: true),
           'a user with only :view_pulse (no manage_public_pulse_views on ANY project) ' \
           'must NOT satisfy the GLOBAL permission check'

    login_as(no_publish_user)
    assert_no_difference -> { PulseView.count } do
      post '/pulse/views', params: { pulse_view: view_params(visibility: 'public') }
    end
    assert_response :forbidden,
                    'LEAK: a user without :manage_public_pulse_views anywhere published a public view'
  end

  private

  def view_params(visibility:, role_ids: nil)
    p = { name: "View by #{User.current&.login}", visibility: visibility,
          project_scope: 'all', lens_ref: 'health' }
    p[:role_ids] = role_ids if role_ids
    p
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end
end
