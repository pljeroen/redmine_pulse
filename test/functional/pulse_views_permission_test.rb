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
# TIER-1 SECURITY — FR-C5-08 .JSON ACCESS CONTROL (FC-C5-08 / FC-C5-09 / FC-C5-10)
# ═══════════════════════════════════════════════════════════════════════════════
# Redmine 6.x platform rule (spec §1.5 / INV-C5-PERM): format-based (.json) routing
# does NOT inherit session authorization. Every PulseViewsController action therefore
# re-runs the visibility gate SERVER-SIDE on EVERY format, via a before_action that
# resolves the target through @view_store.visible_to(User.current).find(id).
#
# PINNED ORACLES (ASM-C5-02, single + intentional):
#   * non-visible READ over .json  -> 404 (existence hiding — RecordNotFound in the
#     adapter). NEVER 200 (that IS the permission_leak class). NEVER 403 (403 would let
#     the caller distinguish "exists but private" from "does not exist").
#   * WRITE permission denial       -> 403 (ownership / publish / system-view gate).
#
# This suite MIRRORS the permission_leak_test.rb idiom:
#   with_settings rest_api_enabled: '1' { get '<...>.json', headers: api_key_header(user) }
#
# RED-by-construction: PulseViewsController, the /pulse/views routes, the ViewStore
# port and PulseView do not exist yet (RoutingError / NameError). A9 implements GREEN.
#
# Postgres-evidence lane (COND-A8-004 / GL-CI-MYSQL): skip (not fail) on a non-Postgres
# adapter so the CI MySQL legs stay green; the visible_to SQL is verified on Postgres.
class PulseViewsPermissionTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  # The exact private-view payload fields that MUST NOT leak in a 404 body.
  PRIVATE_NAME = 'SECRET private view'
  PRIVATE_LENS = 'at_risk'
  PRIVATE_PROFILE = 'secret-profile-xyz'

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @viewer_role = create_role!(name: 'PViewer', issues_visibility: 'all',
                                permissions: %i[view_issues view_pulse])
    @publisher_role = create_role!(name: 'PPublisher', issues_visibility: 'all',
                                   permissions: %i[view_issues view_pulse manage_public_pulse_views])
    @project = create_project!(name: 'PProj', identifier: 'pproj')

    @user_a = create_user!(login: 'perm_a')  # owner of the private view
    @user_b = create_user!(login: 'perm_b')  # non-owner, holds :view_pulse only
    add_member!(project: @project, principal: @user_a, role: @viewer_role)
    add_member!(project: @project, principal: @user_b, role: @viewer_role)

    @private_a = PulseView.create!(
      name: PRIVATE_NAME, user_id: @user_a.id, visibility: 'private',
      project_scope: 'all', lens_ref: PRIVATE_LENS, profile_ref: PRIVATE_PROFILE
    )
    @public_a = PulseView.create!(
      name: 'Everyone can see this', user_id: @user_a.id, visibility: 'public',
      project_scope: 'all', lens_ref: 'health'
    )
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  # ══════════════════════════════════════════════════════════════════════════════
  # THE tier-1 falsifier method (IT-C5-06). Named exactly per FC-C5-08 / CANON.
  # A non-owner reading another user's PRIVATE view over .json -> 404 existence hiding.
  # ══════════════════════════════════════════════════════════════════════════════
  def test_json_rechecks_permission
    with_settings rest_api_enabled: '1' do
      get "/pulse/views/#{@private_a.id}.json", headers: api_key_header(@user_b)
    end

    # PINNED: 404 (existence hiding). NOT 200 (the leak class), NOT 403 (distinguishable).
    assert_response :not_found,
                    'FR-C5-08 breach: non-owner .json read of a private view must be 404 ' \
                    '(existence hiding) — NOT 200 (leak), NOT 403 (distinguishable existence)'
    assert_equal 404, response.status,
                 "the pinned status for a non-visible READ is exactly 404 (got #{response.status})"
    refute_equal 200, response.status, 'a 200 here is the exact permission_leak class recurring'
    refute_equal 403, response.status, '403 would leak existence (does-not-exist vs exists-but-private)'
  end

  # Existence hiding is only real if the 404 body carries NONE of the private payload.
  def test_json_404_body_leaks_no_private_payload
    with_settings rest_api_enabled: '1' do
      get "/pulse/views/#{@private_a.id}.json", headers: api_key_header(@user_b)
    end
    assert_response :not_found

    body = response.body.to_s
    refute_includes body, PRIVATE_NAME, 'LEAK: private view NAME appeared in the 404 body'
    refute_includes body, PRIVATE_LENS, 'LEAK: private view lens_ref appeared in the 404 body'
    refute_includes body, PRIVATE_PROFILE, 'LEAK: private view profile_ref appeared in the 404 body'
  end

  # POSITIVE CONTROL — a PUBLIC view over .json is served (200) to any cockpit viewer.
  # Proves the 404 above is the VISIBILITY gate, not a blanket .json refusal.
  def test_json_public_view_is_200_positive_control
    with_settings rest_api_enabled: '1' do
      get "/pulse/views/#{@public_a.id}.json", headers: api_key_header(@user_b)
    end
    assert_response :success,
                    'a PUBLIC view over .json must be 200 for any cockpit viewer (positive control)'
  end

  # The re-check runs on EVERY format, not HTML-only. The HTML path for a non-visible
  # view must ALSO 404 (a passing HTML-only impl would still leak over .json — and vice
  # versa; both are asserted so neither format can be the silent gap).
  def test_html_non_visible_view_is_404_too
    login_as(@user_b)
    get "/pulse/views/#{@private_a.id}"
    assert_response :not_found,
                    'the visibility before_action must run on the HTML format too -> 404'
  end

  # ── FC-C5-10 — WRITE permission denial is 403 (distinct from the READ 404) ──

  def test_non_owner_patch_visible_view_is_403
    # A visible-but-not-owned view: @user_b can SEE the public view, but must not mutate it
    # without ownership or the global permission.
    login_as(@user_b)
    patch "/pulse/views/#{@public_a.id}", params: { pulse_view: { name: 'hijacked' } }
    assert_response :forbidden,
                    'a non-owner without :manage_public_pulse_views mutating a visible view -> 403'
    assert_equal 'Everyone can see this', @public_a.reload.name, 'the view must not be mutated'
  end

  def test_non_owner_destroy_visible_view_is_403
    login_as(@user_b)
    assert_no_difference -> { PulseView.count } do
      delete "/pulse/views/#{@public_a.id}"
    end
    assert_response :forbidden,
                    'a non-owner without the global permission deleting a visible view -> 403'
  end

  def test_json_patch_write_denial_is_403_not_404
    # @user_b CAN see the public view (so it is not a READ-404 case); the WRITE is denied
    # with 403 (the distinct WRITE oracle). Confirms 404 vs 403 are not conflated.
    with_settings rest_api_enabled: '1' do
      patch "/pulse/views/#{@public_a.id}.json",
            params: { pulse_view: { visibility: 'public', name: 'x' } },
            headers: api_key_header(@user_b)
    end
    assert_response :forbidden,
                    'a WRITE without permission on a VISIBLE view is 403 (WRITE denial), not the READ 404'
  end

  # Owner may mutate their own view (the gate is not a blanket deny).
  def test_owner_patch_own_view_succeeds
    login_as(@user_a)
    patch "/pulse/views/#{@private_a.id}", params: { pulse_view: { name: 'Renamed by owner' } }
    assert_includes [200, 302], response.status, 'the owner may edit their own view'
    assert_equal 'Renamed by owner', @private_a.reload.name
  end

  private

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end
end
