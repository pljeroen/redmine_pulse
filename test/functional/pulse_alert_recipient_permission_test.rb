# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# ══ SECURITY — permission re-checked at send time ══════════════════════════════
#
# Recipient permission is re-checked at SEND time (dispatch), NOT at
# subscribe time. Pulse::Adapters::RedmineSubscriptionStore#subscribers_for(project)
# returns a user U IFF (U is subscribed via explicit watch OR the auto-subscribe role)
# AND U.allowed_to?(:view_pulse, project) is TRUE against LIVE permission state. The
# gate is applied to EVERY candidate from BOTH sources; RedmineAlertDelivery receives
# only the filtered set (the gate must NOT live downstream in delivery).
#
# FIVE cases (the 5th locks the per-project-MODULE semantics):
#   (a) subscribed + permitted                         => INCLUDED / receives
#   (b) subscribed then :view_pulse REVOKED            => EXCLUDED / zero deliveries  ★LOAD-BEARING
#   (c) auto-subscribed via role + permitted           => INCLUDED / receives
#   (d) auto-subscribed via role + permission revoked  => EXCLUDED / zero deliveries
#   (e) subscribed + otherwise-permitted BUT the :pulse
#       project MODULE is DISABLED on the project       => EXCLUDED / zero deliveries  ★LOAD-BEARING
#
# (b) is the load-bearing REVOCATION falsifier (the leak this suite exists to prevent).
# (e) is the load-bearing MODULE-SCOPE falsifier: :view_pulse is a PROJECT_MODULE
#     permission (init.rb project_module :pulse), so allowed_to?(:view_pulse, project)
#     is FALSE when the module is disabled — a global/role-only reimplementation of the
#     gate would WRONGLY pass (a)-(d) yet leak here.
#
# The recipient set is asserted BOTH directly (subscribers_for) AND end-to-end via
# scan_and_alert deliveries (ActionMailer::Base.deliveries) — the two load-bearing
# cases assert ZERO deliveries to the excluded user.
#
# Runs on the Redmine harness: exercises RedmineSubscriptionStore / the watch idiom /
# scan_and_alert / Pulse::Mailer end to end.
#
# Runs on PostgreSQL: allowed_to? / module_enabled? SQL composition is verified on the engine.
class PulseAlertRecipientPermissionTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear

    @view_role = create_role!(name: 'PulseViewer', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    @no_view_role = Role.generate!(name: 'NoPulse', issues_visibility: 'all',
                                   permissions: %i[view_issues]) # NO view_pulse
    @project = create_project!(name: 'AlertP', identifier: 'alert-p',
                               modules: %w[issue_tracking pulse repository])

    # Give the project a health transition so scan_and_alert has an event to deliver
    # (green -> amber). Seeded via the alert-state store as a prior baseline.
    create_issue!(project: @project, author: User.where(admin: true).first || User.first,
                  status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # ── helpers (define the target API) ───────────────────────────

  def subscription_store
    Pulse::Adapters::RedmineSubscriptionStore.new
  end

  def subscriber_logins(project)
    subscription_store.subscribers_for(project.id).map(&:login).sort
  end

  # Explicit "Watch project health" subscription (Redmine Watcher idiom with the
  # pulse-health discriminator; the exact watch mechanism is the adapter's, exercised here
  # via the store's own subscribe path so the test does not hard-code the schema).
  def watch_health!(user, project)
    subscription_store.watch!(user, project)
  end

  # Seed a prior green baseline so scan_and_alert detects green->amber this run.
  def seed_green_baseline!(project)
    store = Pulse::Adapters::ActiveRecordAlertStateStore.new
    store.upsert(project.id, last_rag: 'green', last_dominant: 'staleness',
                 last_no_data: false, last_score: 80.0)
  end

  # Run the alert scan for a single project and return the set of recipient logins
  # that actually received an email (ActionMailer::Base.deliveries).
  def scan_and_delivered_logins(project)
    seed_green_baseline!(project)
    # Force the current health to amber for a deterministic transition.
    Pulse::Tasks::ScanAndAlert.run(project_ids: [project.id], force_rag: :amber)
    ActionMailer::Base.deliveries.flat_map(&:to).sort
  end

  # ── (a) subscribed + permitted => INCLUDED / receives ───────────────────────
  def test_a_subscribed_and_permitted_is_included_and_receives
    u = create_user!(login: 'perm_a')
    add_member!(project: @project, principal: u, role: @view_role)
    watch_health!(u, @project)

    assert_includes subscriber_logins(@project), u.login,
                    '(a) subscribed + permitted must be in the recipient set'
    assert_includes scan_and_delivered_logins(@project), u.mail,
                    '(a) subscribed + permitted must RECEIVE the alert email'
  end

  # ── (b) subscribed then :view_pulse REVOKED => EXCLUDED / zero deliveries ★ ──
  def test_b_subscribed_then_permission_revoked_receives_nothing
    u = create_user!(login: 'perm_b')
    member = add_member!(project: @project, principal: u, role: @view_role)
    watch_health!(u, @project)
    # Precondition: while permitted, U is a candidate.
    assert_includes subscriber_logins(@project), u.login, 'precondition: permitted subscriber is a candidate'

    # REVOKE :view_pulse by swapping to a role without it (permission lost AFTER subscribing).
    member.roles = [@no_view_role]
    member.save!
    u.reload
    refute u.allowed_to?(:view_pulse, @project), 'grounding: :view_pulse is now revoked'

    refute_includes subscriber_logins(@project), u.login,
                    '(b) LOAD-BEARING: a revoked-permission subscriber must be EXCLUDED at send'
    refute_includes scan_and_delivered_logins(@project), u.mail,
                    '(b) LOAD-BEARING: ZERO deliveries to the revoked-permission subscriber'
  end

  # ── (c) auto-subscribed via role + permitted => INCLUDED / receives ─────────
  def test_c_auto_subscribed_role_member_permitted_receives
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_alert_auto_subscribe_role_id' => @view_role.id
    )
    u = create_user!(login: 'perm_c')
    add_member!(project: @project, principal: u, role: @view_role) # role => auto-subscribed
    # NOT an explicit watcher — candidacy comes solely from the auto-subscribe role.

    assert_includes subscriber_logins(@project), u.login,
                    '(c) auto-subscribe-role member (permitted) must be in the recipient set'
    assert_includes scan_and_delivered_logins(@project), u.mail,
                    '(c) auto-subscribed + permitted must RECEIVE the alert email'
  end

  # ── (d) auto-subscribed via role + permission revoked => EXCLUDED / zero ─────
  def test_d_auto_subscribed_but_not_permitted_receives_nothing
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_alert_auto_subscribe_role_id' => @no_view_role.id
    )
    u = create_user!(login: 'perm_d')
    # Member via the auto-subscribe role, but that role LACKS :view_pulse.
    add_member!(project: @project, principal: u, role: @no_view_role)
    refute u.allowed_to?(:view_pulse, @project), 'grounding: auto-subscribe role lacks :view_pulse'

    refute_includes subscriber_logins(@project), u.login,
                    '(d) auto-subscribe does NOT bypass the permission gate'
    refute_includes scan_and_delivered_logins(@project), u.mail,
                    '(d) ZERO deliveries to an auto-subscribed-but-unpermitted user'
  end

  # ── (e) subscribed + permitted BUT :pulse MODULE DISABLED => EXCLUDED / zero ★
  def test_e_module_disabled_excludes_even_permitted_subscriber
    u = create_user!(login: 'perm_e')
    add_member!(project: @project, principal: u, role: @view_role)
    watch_health!(u, @project)
    assert_includes subscriber_logins(@project), u.login,
                    'precondition: with module enabled, the permitted subscriber is a candidate'

    # DISABLE the :pulse module on the project (permission stays on the role).
    @project.enabled_module_names = @project.enabled_module_names - ['pulse']
    @project.reload
    u.reload
    refute @project.module_enabled?(:pulse), 'grounding: :pulse module now disabled'
    refute u.allowed_to?(:view_pulse, @project),
           'grounding: :view_pulse (a project_module permission) is FALSE when :pulse disabled'

    refute_includes subscriber_logins(@project), u.login,
                    '(e) LOAD-BEARING: module-disabled project excludes even a permitted subscriber ' \
                    '(per-project-module semantics; a role-only reimplementation would leak here)'
    refute_includes scan_and_delivered_logins(@project), u.mail,
                    '(e) LOAD-BEARING: ZERO deliveries when the :pulse module is disabled'
  end

  # ── (c) permitted-but-NOT-subscribed => excluded (subscription is required) ──
  def test_permitted_but_not_subscribed_is_excluded
    u = create_user!(login: 'perm_ns')
    add_member!(project: @project, principal: u, role: @view_role)
    # NOT a watcher and auto-subscribe is OFF (default nil) => not a candidate.
    refute_includes subscriber_logins(@project), u.login,
                    'a permitted user who never subscribed must NOT be a recipient'
  end
end
