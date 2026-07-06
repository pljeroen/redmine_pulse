# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# IT-C6-CHAIN — END-TO-END alert chain (the integration lesson: green tests can pass
# per-unit while the composed pipeline leaks or double-fires; this suite drives the
# WHOLE chain through the scan_and_alert composition root).
#
# Scenario: seed a project's PulseAlertState (green); the health changes (amber) =>
# run scan_and_alert =>
#   - a subscribed + permitted watcher receives EXACTLY ONE email;
#   - the alert-state advances to amber;
#   - an immediate re-run (unchanged health) sends NOTHING (ONCE, FC-C6-15);
#   - a revoked-permission watcher receives NONE (FC-C6-06 case b);
#   - a module-disabled watcher receives NONE (FC-C6-06 case e).
#
# This composes AlertRules (domain) + ActiveRecordAlertStateStore + RedmineSubscriptionStore
# (permission-at-send) + RedmineAlertDelivery + Pulse::Mailer end-to-end.
#
# RED-by-construction: the whole pipeline is absent. A9 makes it GREEN.
# Postgres-gated.
class PulseAlertChainTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @view_role = create_role!(name: 'ChainViewer', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    @no_view_role = Role.generate!(name: 'ChainNoPulse', issues_visibility: 'all',
                                   permissions: %i[view_issues])
    @project = create_project!(name: 'ChainP', identifier: 'chain-p',
                               modules: %w[issue_tracking pulse repository])
    create_issue!(project: @project, author: User.where(admin: true).first || User.first,
                  status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def alert_store
    Pulse::Adapters::ActiveRecordAlertStateStore.new
  end

  def watch!(user)
    Pulse::Adapters::RedmineSubscriptionStore.new.watch!(user, @project)
  end

  def seed_green!
    alert_store.upsert(@project.id, last_rag: 'green', last_dominant: 'staleness',
                       last_no_data: false, last_score: 80.0)
  end

  def run_scan!
    Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
  end

  def delivered_mails
    ActionMailer::Base.deliveries.flat_map(&:to)
  end

  def test_full_chain_green_to_amber_one_email_state_advances_rerun_silent
    good = create_user!(login: 'chain_good')
    add_member!(project: @project, principal: good, role: @view_role)
    watch!(good)

    # Also seed a revoked watcher and a module-disabled scenario in one chain run.
    revoked = create_user!(login: 'chain_revoked')
    rev_member = add_member!(project: @project, principal: revoked, role: @view_role)
    watch!(revoked)
    rev_member.roles = [@no_view_role] # revoke :view_pulse AFTER subscribing
    rev_member.save!

    seed_green!
    run_scan!

    # The permitted subscribed watcher got EXACTLY ONE email.
    good_mails = ActionMailer::Base.deliveries.select { |m| m.to.include?(good.mail) }
    assert_equal 1, good_mails.size, 'the permitted watcher receives EXACTLY ONE email'

    # The revoked watcher got NONE.
    refute_includes delivered_mails, revoked.mail,
                    'a revoked-permission watcher receives NONE (FC-C6-06 b)'

    # State advanced to amber.
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'alert-state advances to amber after the transition'

    # An immediate re-run with unchanged health sends NOTHING.
    ActionMailer::Base.deliveries.clear
    events = run_scan!
    assert_equal [], events, 're-run with unchanged health emits nothing (ONCE)'
    assert_equal 0, ActionMailer::Base.deliveries.size, 're-run delivers nothing'
  end

  def test_full_chain_module_disabled_watcher_receives_none
    watcher = create_user!(login: 'chain_moddis')
    add_member!(project: @project, principal: watcher, role: @view_role)
    watch!(watcher)

    # Disable the :pulse module (permission stays on the role; module gate must exclude).
    @project.enabled_module_names = @project.enabled_module_names - ['pulse']
    @project.reload

    seed_green!
    run_scan!

    refute_includes delivered_mails, watcher.mail,
                    'a module-disabled-project watcher receives NONE (FC-C6-06 e)'
  end
end
