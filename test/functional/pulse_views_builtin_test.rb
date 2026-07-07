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
# BUILT-IN SYSTEM VIEWS
# ═══════════════════════════════════════════════════════════════════════════════
# EXACTLY three system-owned built-in views ship (count == 3, not >=3), idempotently
# seeded (find_or_create_by!), each user_id nil, visibility 'public', project_scope
# 'all', profile_ref nil:
#     Portfolio health -> lens health
#     At risk          -> lens at_risk
#     Stalled          -> lens stale
# They are IMMUTABLE at the controller layer for ALL users (incl admins and holders of
# :manage_public_pulse_views): a system_view? guard renders 403 unconditionally on
# edit/update/destroy, BEFORE the ownership/permission check. Built-ins ARE selectable
# (selectable != editable — covered in the select suite).
#
# Runs on PostgreSQL (the production engine): skip on non-Postgres.
class PulseViewsBuiltinTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  PINNED = [
    { name: 'Portfolio health', lens_ref: 'health' },
    { name: 'At risk',          lens_ref: 'at_risk' },
    { name: 'Stalled',          lens_ref: 'stale' }
  ].freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ensure_builtins_seeded!

    @admin = create_user!(login: 'bi_admin', admin: true)
    @manager_role = create_role!(name: 'BIMgr', issues_visibility: 'all',
                                 permissions: %i[view_issues view_pulse manage_public_pulse_views])
    @manager = create_user!(login: 'bi_mgr')
    @project = create_project!(name: 'BIProj', identifier: 'biproj')
    add_member!(project: @project, principal: @manager, role: @manager_role)
  end

  # If a migration-seed already ran on the harness DB the built-ins are present; otherwise
  # this test exercises the same idempotent seed the migration uses.
  def ensure_builtins_seeded!
    return unless defined?(PulseView)

    PulseView.seed_builtins! if PulseView.respond_to?(:seed_builtins!)
  end

  # ── exactly 3, the exact set, system-owned + public ──

  def test_exactly_three_system_views
    assert_equal 3, PulseView.system_owned.count,
                 'EXACTLY 3 built-in system views must exist (count == 3, not >=3)'
  end

  def test_pinned_set_present_with_lens_refs
    PINNED.each do |b|
      found = PulseView.find_by(name: b[:name], user_id: nil, visibility: 'public',
                                lens_ref: b[:lens_ref])
      assert found, "built-in '#{b[:name]}' (lens #{b[:lens_ref]}, public, system-owned) must exist"
      assert_equal 'all', found.project_scope, 'built-ins are project_scope all'
      assert_nil found.profile_ref, 'built-ins carry a nil profile_ref (system default)'
    end
  end

  def test_no_system_view_outside_the_pinned_set
    names = PulseView.system_owned.pluck(:name).sort
    assert_equal PINNED.map { |b| b[:name] }.sort, names,
                 'no system-owned view may exist outside {Portfolio health, At risk, Stalled}'
  end

  # ── idempotent seed (re-seed leaves count == 3) ──

  def test_reseed_is_idempotent
    skip 'seed entry point not built yet' unless PulseView.respond_to?(:seed_builtins!)

    assert_no_difference -> { PulseView.system_owned.count } do
      PulseView.seed_builtins!
      PulseView.seed_builtins!
    end
    assert_equal 3, PulseView.system_owned.count, 're-seeding must not duplicate built-ins'
  end

  # ── built-ins IMMUTABLE at controller for ALL users (403 before ownership) ──

  def builtin
    PulseView.find_by(name: 'Portfolio health', user_id: nil)
  end

  def test_admin_cannot_update_builtin
    login_as(@admin)
    patch "/pulse/views/#{builtin.id}", params: { pulse_view: { name: 'hacked' } }
    assert_response :forbidden,
                    'an ADMIN editing a built-in must be 403 (system_view? guard fires first)'
    assert_equal 'Portfolio health', builtin.reload.name, 'built-in must be unchanged'
  end

  def test_admin_cannot_destroy_builtin
    login_as(@admin)
    assert_no_difference -> { PulseView.system_owned.count } do
      delete "/pulse/views/#{builtin.id}"
    end
    assert_response :forbidden, 'an ADMIN deleting a built-in must be 403'
  end

  def test_manage_public_holder_cannot_update_builtin
    login_as(@manager)
    patch "/pulse/views/#{builtin.id}", params: { pulse_view: { name: 'hacked' } }
    assert_response :forbidden,
                    'a :manage_public_pulse_views holder editing a built-in must be 403 ' \
                    '(the system_view? guard precedes the permission check)'
  end

  def test_manage_public_holder_cannot_destroy_builtin
    login_as(@manager)
    assert_no_difference -> { PulseView.system_owned.count } do
      delete "/pulse/views/#{builtin.id}"
    end
    assert_response :forbidden, 'a :manage_public_pulse_views holder deleting a built-in must be 403'
  end

  private

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end
end
