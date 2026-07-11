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
  # GLOBAL-count assertions (e.g. CacheClearTaskTest). Delete in reverse dependency order (issues ->
  # watchers -> members -> pulse_* -> project -> user -> role), each guarded so a partial-setup
  # failure (or the source-guard test, which creates nothing) still cleans exactly what exists.
  # ASM-07: no residual state.
  def teardown
    if @project
      Issue.where(project_id: @project.id).delete_all rescue nil
      Watcher.where(watchable_type: 'Project', watchable_id: @project.id).delete_all rescue nil
      member_ids = Member.where(project_id: @project.id).pluck(:id)
      MemberRole.where(member_id: member_ids).delete_all rescue nil
      Member.where(project_id: @project.id).delete_all rescue nil
      if defined?(PulseAlertState)
        PulseAlertState.where(project_id: @project.id).delete_all rescue nil
      end
      ActiveRecord::Base.connection.execute(
        "DELETE FROM pulse_snapshots WHERE project_id = #{@project.id.to_i}"
      ) rescue nil
      Project.where(id: @project.id).delete_all rescue nil
    end
    User.where(id: @author.id).delete_all rescue nil if @author
    Role.where(id: @role.id).delete_all rescue nil if @role
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
