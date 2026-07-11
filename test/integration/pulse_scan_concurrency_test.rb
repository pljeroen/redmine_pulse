# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Concurrent-scan safety: the alert fires at most once per transition.
#
# The once-per-transition guarantee must hold not only across SEQUENTIAL
# reruns but across OVERLAPPING cron invocations. Two `redmine_pulse:scan_and_alert`
# processes that start at the same instant for the same project could both:
#   (a) read the SAME prior alert-state (green),
#   (b) evaluate the SAME green->amber rag_transition,
#   (c) both deliver the AlertEvent, and
#   (d) both advance state to amber
# => DUPLICATE alert emails for ONE transition, breaking ONCE.
#
# The fix serializes the per-project read->evaluate->deliver->advance section
# behind a per-engine advisory lock keyed by project_id (pg_advisory_xact_lock on
# Postgres; GET_LOCK on MySQL). Correct on the FIRST run (no state row need exist yet)
# and reversible (no schema change). This suite proves BOTH:
#   (1) the advisory lock is actually taken around the critical section (spy), and
#   (2) two concurrent scans against the same prior state deliver EXACTLY ONCE.
#
# ENGINE-AGNOSTIC: this test runs on every adapter (Postgres AND MySQL) — it is the
# authoritative end-to-end delivery-dedup proof. The MySQL-gated
# PulseScanConcurrencyMysqlTest validates the MySQL lock PRIMITIVE / fail-closed
# behavior (deterministic two-connection technique), but this test is the honest
# overlapping-thread proof that must stay GREEN on both engines.
class PulseScanConcurrencyTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  # Non-transactional: the delivery-dedup test's two worker threads each check out their OWN AR
  # connection, so the setup rows must be COMMITTED to be visible cross-connection — a fixture
  # transaction would hide them from the sibling connection. Because the rows genuinely commit,
  # teardown MUST remove every one of them (see teardown below) so the shared DB stays clean and
  # rerunnable.
  self.use_transactional_tests = false

  # Unique per-run identifiers so a re-run never collides with a row a prior run leaked, and so
  # the delivery-dedup test's committed cross-connection rows (see the two-thread test below) can
  # be found-and-removed exactly in teardown. The suffix is stable within one test instance.
  def uid
    @uid ||= SecureRandom.hex(4)
  end

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    ActionMailer::Base.deliveries.clear
    @created_users = []
    @role = create_role!(name: "ConcViewer_#{uid}", issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: "ConcP_#{uid}", identifier: "conc-p-#{uid}")
    @author = create_user!(login: "conc_author_#{uid}")
    @created_users << @author
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # This suite's delivery-dedup test runs two scans on separately-checked-out connections, so its
  # setup rows must be COMMITTED to be visible cross-connection — they are NOT rolled back by the
  # fixture transaction. Remove EVERY row this test created so the shared DB stays clean and
  # reruns do not collide.
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
  #                     (Redmine built-in project watchers) for completeness.
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
    Role.where(name: "ConcViewer_#{uid}").destroy_all rescue nil
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

  # ── (1) the advisory lock is actually taken, keyed by project_id, around the ──
  #    per-project critical section (read->evaluate->deliver->advance). This is the
  #    single-writer guard that makes ONCE hold under overlapping cron runs.
  def test_scan_takes_project_advisory_lock_around_critical_section
    add_watcher!('lock_w')
    seed_green_baseline!

    locked_keys = []
    original = Pulse::Tasks::ScanAndAlert.method(:with_project_lock)
    Pulse::Tasks::ScanAndAlert.define_singleton_method(:with_project_lock) do |project_id, &blk|
      locked_keys << project_id
      original.call(project_id, &blk)
    end

    begin
      Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    ensure
      Pulse::Tasks::ScanAndAlert.singleton_class.send(:remove_method, :with_project_lock)
      Pulse::Tasks::ScanAndAlert.define_singleton_method(:with_project_lock, original)
    end

    assert_includes locked_keys, @project.id,
                    'the scan must take a per-project lock around the critical section'
  end

  # ── (2) two concurrent scans against the same prior state deliver EXACTLY ONCE ─
  #    The advisory lock serializes the two overlapping runs so only the first sees
  #    the green->amber transition; the second observes the already-advanced amber
  #    state and emits nothing. Exactly ONE delivery total.
  def test_two_concurrent_scans_deliver_exactly_once
    add_watcher!('conc_w')
    seed_green_baseline!

    barrier = Queue.new
    threads = 2.times.map do
      Thread.new do
        # Each thread checks out its OWN AR connection (concurrent DB access), then
        # blocks on the barrier so both enter the scan as close to simultaneously as
        # possible — the overlapping-cron race the lock must defeat.
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
        end
      end
    end
    # Release both threads together.
    2.times { barrier << :go }
    # Use #value (not #join) so ANY exception raised inside a worker thread re-raises HERE and
    # fails the test. #join would silently swallow a crashed worker, letting a false 1-delivery
    # green slip through — this test is the authoritative exactly-once proof, so a hidden worker
    # crash must never masquerade as a pass. (Thread.abort_on_exception is not relied upon.)
    threads.each(&:value)

    delivered = ActionMailer::Base.deliveries.size
    assert_equal 1, delivered,
                 "two concurrent scans of one green->amber transition must deliver EXACTLY " \
                 "once (got #{delivered} — ONCE broken by an overlapping-cron double-fire)"
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'state advanced to amber exactly once'
  end
end
