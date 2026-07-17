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
# PulseView AR MODEL — validations + scopes + instance methods
# ═══════════════════════════════════════════════════════════════════════════════
# app/models/pulse_view.rb defines the TOP-LEVEL constant PulseView (Zeitwerk path
# match, consistent with PulseSnapshot). Validations:
#   * name presence (length >= 1)
#   * visibility inclusion in {private, public, roles}
#   * project_scope inclusion in {all, selected, status_filter}
#   * user_id allows nil (system-owned)
#   * role_ids must deserialize to a non-empty Array iff visibility == 'roles'
# Defaults visibility 'private'. role_ids/scope_params/sort/prefs round-trip via JSON
# serialization. Instance methods owner?(user), system_view?, role_ids_array.
#
# This suite runs on PostgreSQL (the production engine) and touches the AR persistence
# layer, so it is skipped on non-Postgres adapters to keep the MySQL CI legs green.
class PulseViewModelTest < ActiveSupport::TestCase
  fixtures :users, :roles

  def setup
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @user = User.find(2)
  end

  def build(attrs = {})
    PulseView.new({ name: 'V', visibility: 'private', project_scope: 'all' }.merge(attrs))
  end

  # ── validations ──

  def test_name_presence_required
    refute build(name: '').valid?, 'empty name must be invalid'
    assert_includes build(name: '').tap(&:valid?).errors.attribute_names, :name
    assert build(name: 'x').valid?, 'a non-empty name is valid'
  end

  def test_visibility_inclusion
    refute build(visibility: 'sideways').valid?, "an unknown visibility must be invalid"
    %w[private public roles].each do |v|
      pv = build(visibility: v)
      pv.role_ids = [1] if v == 'roles'
      assert pv.valid?, "visibility '#{v}' must be accepted (errors: #{pv.errors.full_messages})"
    end
  end

  def test_project_scope_inclusion
    refute build(project_scope: 'weird').valid?, 'an unknown project_scope must be invalid'
    %w[all selected status_filter].each do |s|
      assert build(project_scope: s).valid?, "project_scope '#{s}' must be accepted"
    end
  end

  def test_user_id_allows_nil_for_system_views
    assert build(user_id: nil).valid?, 'user_id nil (system-owned) must be valid'
  end

  def test_default_visibility_is_private
    pv = PulseView.new(name: 'x', project_scope: 'all')
    assert_equal 'private', pv.visibility, 'a fresh view defaults to private'
  end

  def test_role_ids_required_and_nonempty_iff_visibility_roles
    refute build(visibility: 'roles', role_ids: nil).valid?,
           "visibility 'roles' with nil role_ids must be invalid"
    refute build(visibility: 'roles', role_ids: []).valid?,
           "visibility 'roles' with an empty role_ids array must be invalid"
    assert build(visibility: 'roles', role_ids: [7]).valid?,
           "visibility 'roles' with a non-empty role_ids array is valid"
    # role_ids irrelevant for private/public — presence must NOT be required there.
    assert build(visibility: 'private', role_ids: nil).valid?, 'private needs no role_ids'
    assert build(visibility: 'public', role_ids: nil).valid?, 'public needs no role_ids'
  end

  # ── serialization round-trip ──

  def test_json_serialized_fields_round_trip
    pv = PulseView.create!(name: 'Round', user_id: @user.id, visibility: 'roles',
                           project_scope: 'selected', role_ids: [3, 5],
                           scope_params: { 'project_ids' => [10, 11] },
                           sort: %w[health desc], prefs: { 'threshold' => 42 })
    reloaded = PulseView.find(pv.id)
    assert_equal [3, 5], reloaded.role_ids, 'role_ids round-trips'
    assert_equal({ 'project_ids' => [10, 11] }, reloaded.scope_params, 'scope_params round-trips')
    assert_equal %w[health desc], reloaded.sort, 'sort round-trips'
    assert_equal({ 'threshold' => 42 }, reloaded.prefs, 'prefs round-trips')
  end

  def test_role_ids_array_returns_empty_when_nil
    pv = build(visibility: 'private', role_ids: nil)
    assert_equal [], pv.role_ids_array, 'role_ids_array is [] when the column is nil'
  end

  # ── instance methods ──

  def test_owner_predicate
    pv = build(user_id: @user.id)
    assert pv.owner?(@user), 'owner? true for the owning user'
    other = User.find(3)
    refute pv.owner?(other), 'owner? false for a different user'
  end

  def test_system_view_predicate
    assert build(user_id: nil).system_view?, 'system_view? true when user_id nil'
    refute build(user_id: @user.id).system_view?, 'system_view? false when user-owned'
  end

  # ── visible_to scope correctness (model-level, single read gate) ──

  def test_visible_to_scope_unions_private_public_and_roles
    other = User.find(3)
    mine_private = PulseView.create!(name: 'mine', user_id: @user.id, visibility: 'private',
                                     project_scope: 'all')
    others_private = PulseView.create!(name: 'theirs', user_id: other.id, visibility: 'private',
                                       project_scope: 'all')
    a_public = PulseView.create!(name: 'pub', user_id: other.id, visibility: 'public',
                                 project_scope: 'all')

    visible = PulseView.visible_to(@user).to_a
    assert_includes visible, mine_private, 'own private view is visible'
    assert_includes visible, a_public, 'a public view is visible to anyone'
    refute_includes visible, others_private, "LEAK: another user's private view is in visible_to"
  end
end
