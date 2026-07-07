# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# THE 404-vs-403 ACCESS DECISION MATRIX, end
# to end through the HTTP layer (both HTML show and JSON project actions). Each row
# R1..R9 of the access-decision table is a discrete, independently
# falsifiable assertion.
#
#   R1 nonexistent id                 -> 404
#   R2 private, viewer not member     -> 404 (existence never leaked)
#   R3 archived project               -> 404 (Project.visible excludes archived)
#   R4 visible, pulse module disabled -> 403
#   R5 visible, module on, no view_pulse -> 403
#   R6 visible, module on, view_pulse -> 200
#   R7 anonymous on a public+module+anon-perm project -> 200 (else 403/404)
#   R8 JSON action, rest_api disabled -> Redmine 401/403 (decided before R1-R6)
#   R9 JSON action, rest on, no/invalid key, not logged in -> Redmine 401/403
#
# this suite MUST run on PostgreSQL 16 (the production engine) — the
# Project.visible / allowed_to? SQL composition is verified on the deployed engine.
# Requires the controllers + routes.
class PermissionAccessTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # production-engine gate — the access SQL must be verified on Postgres.
    # This is the Postgres-evidence lane; skip on non-Postgres
    # adapters (counted as skips, not failures) so the other CI legs stay green. On Postgres
    # (local harness + Postgres CI legs) the guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @member_role = create_role!(name: 'AccAll', issues_visibility: 'all',
                                permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'Acc', identifier: 'acc-proj')
  end

  def login_as(user)
    # Redmine integration-login helper; sets the session for the user.
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    # Some harness builds generate users without a known password; fall back to the
    # session-stub Redmine functional tests use.
    User.current = user
  end

  def member_user!(login:, role: @member_role)
    u = create_user!(login: login)
    add_member!(project: @project, principal: u, role: role)
    u
  end

  # ─────────────────────────── R1: nonexistent id ───────────────────────────

  def test_R1_nonexistent_id_html_404
    u = member_user!(login: 'r1u')
    login_as(u)
    get '/projects/no-such-project/pulse'
    assert_response :not_found
  end

  def test_R1_nonexistent_id_json_404
    u = member_user!(login: 'r1j')
    with_settings rest_api_enabled: '1' do
      get '/pulse/projects/no-such-project.json', headers: api_key_header(u)
      assert_response :not_found
    end
  end

  # ───────────── R2: private project, viewer not a member -> 404 ─────────────

  def test_R2_private_invisible_html_404
    outsider = create_user!(login: 'r2out') # no membership -> cannot see @project
    login_as(outsider)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :not_found,
                    'private invisible project -> 404, existence not leaked (no 403)'
  end

  # ─────────────────────── R3: archived project -> 404 ──────────────────────

  def test_R3_archived_project_html_404
    user = member_user!(login: 'r3u')
    @project.update_column(:status, Project::STATUS_ARCHIVED)
    login_as(user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :not_found, 'archived project -> 404 (Project.visible excludes archived)'
  end

  # ──────────────── R4: visible, pulse module disabled -> 403 ────────────────

  def test_R4_module_disabled_html_403
    user = member_user!(login: 'r4u')
    @project.enabled_module_names = %w[issue_tracking] # pulse OFF
    login_as(user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :forbidden, 'visible but pulse module disabled -> 403'
  end

  # ──────────── R5: visible, module on, view_pulse absent -> 403 ─────────────

  def test_R5_no_view_pulse_html_403
    role = create_role!(name: 'R5NoPulse', issues_visibility: 'all',
                        permissions: %i[view_issues]) # NO view_pulse
    user = member_user!(login: 'r5u', role: role)
    login_as(user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :forbidden, 'visible, module on, but no view_pulse -> 403'
  end

  # ──────────── R6: visible, module on, view_pulse held -> 200 ───────────────

  def test_R6_visible_permitted_html_200
    user = member_user!(login: 'r6u')
    login_as(user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success, 'visible + module + view_pulse -> 200'
  end

  def test_R6_visible_permitted_json_200
    user = member_user!(login: 'r6j')
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@project.identifier}.json", headers: api_key_header(user)
      assert_response :success
    end
  end

  # ─────────── R7: anonymous on public+module+anon-permitted project ──────────

  def test_R7_anonymous_on_public_permitted_project
    public_proj = create_project!(name: 'Pub', identifier: 'pub-proj')
    public_proj.update_column(:is_public, true)
    anon = Role.anonymous
    anon.permissions = (anon.permissions | %i[view_issues view_pulse])
    anon.save!
    get "/projects/#{public_proj.identifier}/pulse"
    assert_response :success,
                    'anonymous holding view_pulse on a public module-enabled project -> 200'
  end

  def test_R7_anonymous_without_permission_not_200
    user = nil # anonymous
    # @project is private (default) and anon has no view_pulse here.
    get "/projects/#{@project.identifier}/pulse"
    assert_includes [403, 404, 302], response.status,
                    'anonymous lacking permission/visibility must not get 200'
  end

  # ───────── R8: JSON action with REST disabled -> Redmine 401/403 ───────────

  def test_R8_json_rest_disabled_401_or_403
    user = member_user!(login: 'r8u')
    with_settings rest_api_enabled: '0' do
      get "/pulse/projects/#{@project.identifier}.json", headers: api_key_header(user)
      assert_includes [401, 403], response.status,
                      'REST disabled -> Redmine standard 401/403, decided before R1-R6'
    end
  end

  # ───────── R9: JSON action, REST on, no/invalid key, not logged in ─────────

  def test_R9_json_no_credentials_401_or_403
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@project.identifier}.json"
      assert_includes [401, 403], response.status,
                      'no API key + not logged in -> Redmine standard 401/403'
    end
  end

  def test_R9_json_invalid_key_401_or_403
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@project.identifier}.json",
          headers: { 'X-Redmine-API-Key' => 'totally-invalid-key' }
      assert_includes [401, 403], response.status, 'invalid API key -> 401/403'
    end
  end

  # ───────────── portfolio surfaces never 404/403 for selection ──────────────

  def test_portfolio_empty_is_200_not_404
    outsider = create_user!(login: 'emptyport') # sees no pulse projects
    login_as(outsider)
    get '/pulse'
    assert_response :success, 'an empty portfolio renders 200 (empty state), never 404'
  end

  private

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end
end
