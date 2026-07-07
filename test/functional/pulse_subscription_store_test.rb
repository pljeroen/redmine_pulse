# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Subscription = explicit "Watch project health" OR admin auto-subscribe-role.
# RedmineSubscriptionStore#subscribers_for resolves the UNION of
#   (1) explicit per-user watch records (Redmine Watcher idiom, pulse-health discriminator),
#   (2) members of pulse_alert_auto_subscribe_role_id on the project (nil => off, DEFAULT).
# Both sources feed the permission gate (covered exhaustively in
# pulse_alert_recipient_permission_test.rb). This suite covers the UNION composition:
# watch-only, role-only, both (no duplicate), and nil-role => watchers-only.
#
# Requires RedmineSubscriptionStore + the watch idiom.
# Runs on PostgreSQL.
class PulseSubscriptionStoreTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'SubViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'SubP', identifier: 'sub-p')
  end

  def store
    Pulse::Adapters::RedmineSubscriptionStore.new
  end

  def logins(project)
    store.subscribers_for(project.id).map(&:login).sort
  end

  def member_user!(login)
    u = create_user!(login: login)
    add_member!(project: @project, principal: u, role: @role)
    u
  end

  def set_auto_subscribe_role!(role)
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_alert_auto_subscribe_role_id' => role&.id
    )
  end

  # ── explicit watcher only => that user is a candidate ───────────────────────
  def test_explicit_watcher_only_is_candidate
    set_auto_subscribe_role!(nil) # auto-subscribe OFF
    u = member_user!('watch_only')
    store.watch!(u, @project)
    assert_equal ['watch_only'], logins(@project)
  end

  # ── auto-subscribe role member only => candidate ────────────────────────────
  def test_auto_subscribe_role_member_only_is_candidate
    set_auto_subscribe_role!(@role)
    u = member_user!('role_only') # member via the auto-subscribe role, no explicit watch
    assert_includes logins(@project), u.login
  end

  # ── both sources => UNION, no duplicate ─────────────────────────────────────
  def test_union_of_watch_and_role_no_duplicate
    set_auto_subscribe_role!(@role)
    both = member_user!('both_src')
    store.watch!(both, @project) # ALSO an explicit watcher
    role_only = member_user!('role_src')
    watch_only = member_user!('watch_src')
    store.watch!(watch_only, @project)

    result = logins(@project)
    assert_equal %w[both_src role_src watch_src], result, 'union of both sources'
    assert_equal result.uniq, result, 'a user in BOTH sources appears exactly once (no duplicate)'
  end

  # ── nil auto-subscribe role => ONLY explicit watchers are candidates ────────
  def test_nil_auto_subscribe_role_excludes_role_members
    set_auto_subscribe_role!(nil) # DEFAULT: disabled
    member_user!('role_member_no_watch') # member but NOT an explicit watcher
    watcher = member_user!('explicit_watcher')
    store.watch!(watcher, @project)
    assert_equal ['explicit_watcher'], logins(@project),
                 'with auto-subscribe off, role members are NOT candidates (only explicit watchers)'
  end

  # ── unwatch removes the candidate ───────────────────────────────────────────
  def test_unwatch_removes_candidate
    set_auto_subscribe_role!(nil)
    u = member_user!('toggle_u')
    store.watch!(u, @project)
    assert_includes logins(@project), u.login
    store.unwatch!(u, @project)
    refute_includes logins(@project), u.login, 'unwatch removes the subscription candidate'
  end
end
