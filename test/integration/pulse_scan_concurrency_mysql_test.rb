# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# MySQL single-writer serialization proof (F1 / R4 / AC3).
#
# NOTE: PulseScanConcurrencyTest#test_two_concurrent_scans_deliver_exactly_once is the
# authoritative end-to-end delivery-dedup proof (runs on both Postgres and MySQL). This
# suite validates the MySQL advisory lock PRIMITIVE / fail-closed behavior only.
#
# The MySQL analogue of PulseScanConcurrencyTest's exactly-once guarantee. On MySQL the
# critical section is serialized by a SESSION advisory lock (GET_LOCK / RELEASE_LOCK). This
# suite proves the contract DETERMINISTICALLY — no sleeps, no thread-timing race — using the
# two-connection lock-holding technique:
#
#   (A) a dedicated MySQL connection TAKES and HOLDS the project's advisory lock (the exact
#       name the MysqlAdvisoryLock adapter derives) — this simulates a concurrent scan already
#       inside the critical section;
#   (B) with A still holding the lock, ScanAndAlert.run scans the SAME project for the SAME
#       green->amber transition. Because A holds the lock, B's with_project_lock CANNOT acquire.
#       Per the mysql adapter FAIL-CLOSED contract, B MUST NOT run the critical section unlocked:
#       it delivers NOTHING and does NOT advance the state (the next cron run retries).
#   (C) A releases the lock; a subsequent scan then delivers EXACTLY ONCE and advances to amber.
#
# This is the fire-once-per-transition guarantee (running unlocked on non-acquire would BE the
# F1 double-delivery bug — ASM-04).
#
# RED-reason at authoring time: Pulse::Adapters::MysqlAdvisoryLock does not exist (NameError),
# AND scan_and_alert still degrades to a plain yield on MySQL (no serialization) — so under
# contention B would run unlocked and deliver, failing the fail-closed assertion. GREEN once A9
# wires the MySQL adapter with fail-closed acquisition.
#
# MySQL-gated: this is the MySQL serialization lane (mirrors the PG-gated concurrency suite).
class PulseScanConcurrencyMysqlTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  self.use_transactional_tests = false

  def uid
    @uid ||= SecureRandom.hex(3)
  end

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /mysql|maria/i
      skip "MySQL-only serialization lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @created_users = []
    @role = create_role!(name: "ConcMyViewer_#{uid}", issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'ConcMyP', identifier: "conc-my-#{uid}")
    @author = create_user!(login: "conc_my_author_#{uid}")
    @created_users << @author
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # This class is non-transactional (real GET_LOCK on MySQL), so it MUST remove EVERY row it
  # committed or they leak into sibling tests (e.g. CacheClearTaskTest) and break reruns
  # (ASM-07: no residual state).
  #
  # COMPLETE footprint (traced from setup + add_watcher! + seed_green_baseline! + the scan body):
  #   issues / enabled_modules / members / member_roles / projects_trackers / project
  #                     Project.destroy_all cascades all of these (issues :dependent=>:destroy,
  #                     enabled_modules :dependent=>:delete_all, members via before_destroy
  #                     :delete_all_members, projects_trackers via HABTM teardown).
  #   watchers          add_watcher! -> RedmineSubscriptionStore#watch! writes
  #                     watchable_type='PulseHealth', watchable_id=project.id.
  #                     Project#destroy has NO dependent for Watcher, so these MUST be removed
  #                     explicitly before destroy_all. Also delete watchable_type='Project' rows
  #                     for completeness.
  #   pulse_alert_states  seed_green_baseline! upsert + the scan's advance_state (plugin table,
  #                     not covered by Project#destroy — deleted explicitly before destroy_all).
  #   pulse_snapshots   the scan's CanonicalScan cache write (plugin table, not covered —
  #                     deleted explicitly before destroy_all).
  #   users             User.destroy_all cascades email_addresses (:dependent=>:delete_all),
  #                     tokens, user_preferences, and any remaining memberships. Destroyed AFTER
  #                     Project.destroy_all so member_roles/members are already gone.
  #   role              Role.destroy_all cascades any remaining member_roles. Destroyed AFTER
  #                     users (both are freed from members by the project destroy).
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
    # referencing these users are already gone before User#destroy fires its own callbacks.
    user_ids = Array(@created_users).map(&:id).compact
    User.where(id: user_ids).destroy_all rescue nil unless user_ids.empty?
    # Destroy (not delete_all) so Role#destroy cascades any remaining member_roles.
    Role.where(name: "ConcMyViewer_#{uid}").destroy_all rescue nil
  end

  def alert_store
    Pulse::Adapters::ActiveRecordAlertStateStore.new
  end

  def seed_green_baseline!
    alert_store.upsert(@project.id, last_rag: 'green', last_dominant: 'staleness',
                       last_no_data: false, last_score: 80.0)
  end

  def add_watcher!(login)
    u = create_user!(login: "#{login}_#{uid}")
    @created_users << u
    add_member!(project: @project, principal: u, role: @role)
    Pulse::Adapters::RedmineSubscriptionStore.new.watch!(u, @project)
    u
  end

  # The exact lock name the MysqlAdvisoryLock adapter derives for this project — so the
  # held-lock in connection A contends against the SAME name the scan under test would take.
  # We obtain it by spying the adapter's own GET_LOCK SQL against a throwaway spy connection,
  # keeping the test in lock-step with A9's chosen naming (no hard-coded name duplication).
  def adapter_lock_name(project_id)
    captured = nil
    spy = Object.new
    spy.define_singleton_method(:select_value) do |sql|
      captured = sql[/GET_LOCK\(\s*'([^']*)'/, 1] if sql =~ /GET_LOCK/i
      1 # pretend acquired so the adapter proceeds and then releases
    end
    spy.define_singleton_method(:quote) { |s| "'#{s}'" }
    Pulse::Adapters::MysqlAdvisoryLock.new(spy).with_lock(project_id) { nil }
    captured
  end

  # ── serialization proof: a held lock forces the concurrent scan to fail closed ──
  def test_scan_fails_closed_when_project_lock_is_held_then_delivers_once_after_release
    add_watcher!('conc_my_w')
    seed_green_baseline!

    lock_name = adapter_lock_name(@project.id)
    refute_nil lock_name, 'the MySQL adapter must derive a GET_LOCK name'

    # (A) hold the project's advisory lock on a DEDICATED backend session.
    holder = ActiveRecord::Base.connection_pool.checkout
    begin
      acquired = holder.select_value("SELECT GET_LOCK(#{holder.quote(lock_name)}, 0)")
      assert_equal 1, acquired.to_i, 'connection A must acquire the project lock to hold it'

      # (B) scan the same green->amber transition while A holds the lock. The scan's own
      # with_project_lock cannot acquire -> fail closed -> no delivery, no state advance.
      Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)

      assert_equal 0, ActionMailer::Base.deliveries.size,
                   'FAIL CLOSED: a scan that cannot acquire the held lock must deliver NOTHING ' \
                   "(got #{ActionMailer::Base.deliveries.size} — the F1 unlocked double-fire)"
      assert_equal 'green', alert_store.find_by_project(@project.id)[:last_rag],
                   'state must remain green (the fail-closed scan did not advance under contention)'
    ensure
      holder.select_value("SELECT RELEASE_LOCK(#{holder.quote(lock_name)})")
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    # (C) with the lock released, the next scan sees the still-green baseline, delivers the
    #     transition EXACTLY ONCE, and advances to amber.
    Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    assert_equal 1, ActionMailer::Base.deliveries.size,
                 'after release, the retry scan delivers the transition EXACTLY once'
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'state advanced to amber exactly once after the lock was free'
  end
end
