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
# END-TO-END PERSISTENCE CHAIN
# ═══════════════════════════════════════════════════════════════════════════════
# Exercise the WHOLE chain through the real controller + ViewStore adapter, not the model
# in isolation. Create a view (through POST /pulse/views) with a lens + a profile bound ->
# persist -> select it -> the cockpit (GET /pulse) renders under that lens + that profile.
# This is the regression guard for the whole saved-view -> active-profile persistence chain.
#
# Also covers: a user-authored/private custom lens persists via the store, owner-scoped
# (retrievable by its owner, not by another user).
#
# Runs on PostgreSQL (the production engine): skip on non-Postgres.
class PulseViewsIntegrationTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'E2EViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'e2e_u')
    @other = create_user!(login: 'e2e_other')
    @project = create_project!(name: 'E2EProj', identifier: 'e2e-proj')
    add_member!(project: @project, principal: @user, role: @role)
    add_member!(project: @project, principal: @other, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # ── The full chain: create -> persist -> select -> cockpit reflects lens + profile ──

  def test_create_persist_select_cockpit_reflects_lens_and_profile
    login_as(@user)

    # 1) CREATE through the real controller (routes through @view_store).
    assert_difference -> { PulseView.count }, 1 do
      post '/pulse/views', params: { pulse_view: {
        name: 'My at-risk view', visibility: 'private', project_scope: 'all',
        lens_ref: 'at_risk', profile_ref: 'no-such-profile'
      } }
    end
    assert_includes [200, 201, 302], response.status, 'create returns ok/redirect'

    # 2) PERSISTED with the correct columns.
    view = PulseView.order(:id).last
    assert_equal @user.id, view.user_id
    assert_equal 'at_risk', view.lens_ref, 'the persisted lens_ref round-trips'
    assert_equal 'no-such-profile', view.profile_ref, 'the persisted profile_ref round-trips'

    # 3) SELECT -> session reference stored.
    post "/pulse/views/#{view.id}/select"
    assert_equal view.id, session[:active_pulse_view_id], 'select stores the active view id'

    # 4) COCKPIT renders under the selected lens + profile (chain closes). The dangling
    # profile_ref proves the profile_ref reached the resolve path (surfaced warning);
    # the at_risk lens proves the lens_ref reached LensRanker.
    get '/pulse'
    assert_response :success, 'the cockpit renders 200 after selecting the created view'
    assert_match(/at_risk/, response.body, "the selected view's lens_ref drives the active lens")
    assert_match(/not a published profile|falling back|system default/i, response.body,
                 "the selected view's profile_ref reached the resolve path")
  end

  # A built-in system view is SELECTABLE (selectable != editable).
  def test_builtin_view_is_selectable
    skip 'built-in seed not built yet' unless defined?(PulseView) &&
                                              PulseView.respond_to?(:seed_builtins!)
    PulseView.seed_builtins!
    builtin = PulseView.find_by(name: 'At risk', user_id: nil)

    login_as(@user)
    post "/pulse/views/#{builtin.id}/select"
    assert_equal builtin.id, session[:active_pulse_view_id],
                 'a system-owned built-in view IS selectable (selectable != editable)'

    get '/pulse'
    assert_response :success
    assert_match(/at_risk/, response.body, "selecting 'At risk' applies the at_risk lens")
  end

  # ── a private user-authored lens persists via the store, owner-scoped ──

  def test_private_lens_persists_owner_scoped
    login_as(@user)
    # A private view carrying a user-authored lens_ref (the persistence surface for a
    # private custom lens — embedded via lens_ref).
    post '/pulse/views', params: { pulse_view: {
      name: 'My private lens view', visibility: 'private', project_scope: 'all',
      lens_ref: 'my-private-lens'
    } }
    mine = PulseView.order(:id).last
    assert_equal 'my-private-lens', mine.lens_ref, 'the private lens_ref persists'

    # Owner retrieves it via the visible read gate; a different user does NOT.
    assert_includes PulseView.visible_to(@user).to_a, mine,
                    'the owner retrieves their private lens-bearing view'
    refute_includes PulseView.visible_to(@other).to_a, mine,
                    'LEAK: a private lens-bearing view is visible to a non-owner'
  end

  private

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end
end
