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
# behind a PostgreSQL transaction-scoped ADVISORY LOCK keyed by project_id
# (pg_advisory_xact_lock). Correct on the FIRST run (no state row need exist yet) and
# reversible (no schema change). This suite proves BOTH:
#   (1) the advisory lock is actually taken around the critical section (spy), and
#   (2) two concurrent scans against the same prior state deliver EXACTLY ONCE.
#
# Postgres-gated: the advisory-lock mechanism is Postgres-specific and the harness DB is
# PostgreSQL.
class PulseScanConcurrencyTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @role = create_role!(name: 'ConcViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'ConcP', identifier: 'conc-p')
    @author = create_user!(login: 'conc_author')
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def alert_store
    Pulse::Adapters::ActiveRecordAlertStateStore.new
  end

  def seed_green_baseline!
    alert_store.upsert(@project.id, last_rag: 'green', last_dominant: 'staleness',
                       last_no_data: false, last_score: 80.0)
  end

  def add_watcher!(login)
    u = create_user!(login: login)
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
    threads.each(&:join)

    delivered = ActionMailer::Base.deliveries.size
    assert_equal 1, delivered,
                 "two concurrent scans of one green->amber transition must deliver EXACTLY " \
                 "once (got #{delivered} — ONCE broken by an overlapping-cron double-fire)"
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'state advanced to amber exactly once'
  end
end
