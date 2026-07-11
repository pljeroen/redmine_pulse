# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# scan_and_alert delegates its critical section to the AdvisoryLock port (F1 / R2 / AC4).
#
# This is the wiring gate that FORCES A9 to route with_project_lock through the AdvisoryLock
# adapter instead of the inline adapter_name branch. Two independent observations, both RED
# until the delegation exists:
#
#   (1) SQL-level (MySQL): a real scan on MySQL must issue GET_LOCK for the scanned project —
#       the observable signature of the MysqlAdvisoryLock adapter running around the critical
#       section. Today scan_and_alert degrades to a plain yield on MySQL (no GET_LOCK), so this
#       is RED for the RIGHT reason: the MySQL adapter is not wired.
#
#   (2) source-level: with_project_lock must NOT contain the inline adapter_name branch or the
#       raw pg_advisory_xact_lock SQL any more — that logic moves into the Pg adapter. This is a
#       static guard so the refactor is not silently reverted. RED now (the branch still lives in
#       scan_and_alert.rb); GREEN once A9 extracts it to the port/adapter.
#
# Observation (1) is MySQL-gated (needs a real MySQL connection); observation (2) is engine-
# agnostic (reads source).
class PulseScanDelegatesToAdvisoryLockTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  self.use_transactional_tests = false

  SCAN_SOURCE = File.expand_path(
    '../../../lib/pulse/tasks/scan_and_alert.rb', File.expand_path(__FILE__)
  )

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    ActionMailer::Base.deliveries.clear
  end

  # Non-transactional: the MySQL delegation test COMMITS a role/user/project/member/issue (in the
  # test body) that must be removed or they dirty the shared DB and break reruns / sibling
  # GLOBAL-count assertions (e.g. CacheClearTaskTest). ASM-07: no residual state.
  #
  # COMPLETE footprint (traced from the MySQL delegation test body + the scan it runs):
  #   issues / enabled_modules / members / member_roles / projects_trackers / project
  #                     Project.destroy_all cascades all of these (issues :dependent=>:destroy,
  #                     enabled_modules :dependent=>:delete_all, members via before_destroy
  #                     :delete_all_members, projects_trackers via HABTM teardown).
  #   watchers          this test creates NO watchers, but the scan body can write
  #                     watchable_type='PulseHealth' rows via RedmineSubscriptionStore.
  #                     Project#destroy has NO dependent for Watcher — delete explicitly
  #                     for both Project and PulseHealth types before destroy_all.
  #   pulse_alert_states  the scan's advance_state (plugin table, not covered by Project#destroy —
  #                     deleted explicitly before destroy_all).
  #   pulse_snapshots   the scan's CanonicalScan cache write (plugin table, not covered —
  #                     deleted explicitly before destroy_all).
  #   user              User.destroy_all cascades email_addresses (:dependent=>:delete_all),
  #                     tokens, user_preferences, and any remaining memberships. Destroyed AFTER
  #                     Project.destroy_all so member_roles/members are already gone.
  #   role              Role.destroy_all cascades any remaining member_roles. Destroyed AFTER
  #                     user (both are freed from members by the project destroy).
  def teardown
    if @project
      # Watchers: NOT cascaded by Project#destroy — delete explicitly before destroying the project.
      Watcher.where(watchable_id: @project.id,
                    watchable_type: %w[Project PulseHealth]).delete_all rescue nil
      # Plugin tables: not covered by Project#destroy.
      if defined?(PulseAlertState)
        PulseAlertState.where(project_id: @project.id).delete_all rescue nil
      end
      ActiveRecord::Base.connection.execute(
        "DELETE FROM pulse_snapshots WHERE project_id = #{@project.id.to_i}"
      ) rescue nil
      # Cascade: issues, enabled_modules, members/member_roles, projects_trackers, project row.
      Project.where(id: @project.id).destroy_all rescue nil
    end
    # Destroy (not delete_all) so Redmine's User#destroy callbacks cascade email_addresses,
    # tokens, user_preferences, etc. Project must be destroyed first (done above) so member_roles
    # referencing this user are already gone before User#destroy fires its own callbacks.
    User.where(id: @author.id).destroy_all rescue nil if @author
    # Destroy (not delete_all) so Role#destroy cascades any remaining member_roles.
    Role.where(id: @role.id).destroy_all rescue nil if @role
  end

  # ── (2) source guard: the inline adapter_name / pg_advisory branch must be GONE ──
  def test_with_project_lock_no_longer_branches_on_adapter_name_inline
    src = File.read(SCAN_SOURCE)
    refute_match(/adapter_name\s*=~\s*\/postgres/i, src,
                 'with_project_lock must delegate to the AdvisoryLock port, not branch on ' \
                 'adapter_name inline (R2 — the F1 defect site)')
    refute_match(/pg_advisory_xact_lock/i, src,
                 'the raw pg_advisory_xact_lock SQL must move into Pulse::Adapters::PgAdvisoryLock ' \
                 '(R2/R3), not stay inline in scan_and_alert.rb')
    assert_match(/AdvisoryLock/, src,
                 'scan_and_alert must reference the AdvisoryLock port/adapter (delegation, not inline)')
  end

  # ── (1) SQL-level: on MySQL a scan must take the GET_LOCK (adapter is wired + invoked) ──
  def test_mysql_scan_issues_get_lock_for_the_scanned_project
    unless ActiveRecord::Base.connection.adapter_name =~ /mysql|maria/i
      skip "MySQL-only delegation lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end

    @role = create_role!(name: 'DelegViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'DelegP', identifier: "deleg-#{SecureRandom.hex(3)}")
    @author = create_user!(login: "deleg_author_#{SecureRandom.hex(3)}")
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))

    get_lock_sqls = []
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      sql = args.last[:sql].to_s
      get_lock_sqls << sql if sql =~ /GET_LOCK/i
    end
    begin
      Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    refute_empty get_lock_sqls,
                 'a MySQL scan must delegate the critical section to the MysqlAdvisoryLock adapter, ' \
                 'issuing GET_LOCK around the scanned project (RED today: scan degrades to plain yield)'
  end
end
