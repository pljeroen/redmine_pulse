# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# IT-C6-03 / IT-C6-05 / IT-C6-09 — rake task behavior (recompute + scan_and_alert).
#
# The rake task bodies are thin shells over composition-root classes:
#   redmine_pulse:recompute      -> Pulse::Tasks::Recompute.run
#   redmine_pulse:scan_and_alert -> Pulse::Tasks::ScanAndAlert.run
# This suite exercises those underlying entry points (asserting OBSERVABLE POST-STATE),
# mirroring cache_clear_task_test.rb (drive the method the task drives).
#
# FC-C6-10 recompute idempotence: run recompute; capture computed_at; re-run within
#   max-age => unchanged (fresh row not recomputed); recompute writes ONLY pulse_snapshots
#   and NEVER pulse_alert_states.
# FC-C6-15 ONCE: green->amber emits exactly one rag_transition and advances state; an
#   immediate second run with unchanged health emits NOTHING (state matches).
# FC-C6-08 partial-failure: mailer stubbed to raise for recipient#1 => the error is
#   logged, delivery to recipient#2 still occurs, deliver returns normally (no raise),
#   and state STILL advances (OI-C6-01) => a third run emits nothing (no re-alert).
# FC-C6-12 canonical-profile-only: both tasks score under the 'default' profile.
#
# RED-by-construction: the task classes / stores / Pulse::Mailer / pulse_alert_states
# do not exist yet. A9 makes it GREEN.
#
# Postgres-gated for parity with the sibling integration suites.
class PulseAlertTasksTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @role = create_role!(name: 'TaskViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'TaskP', identifier: 'task-p')
    @author = create_user!(login: 'task_author')
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def conn
    ActiveRecord::Base.connection
  end

  def alert_store
    Pulse::Adapters::ActiveRecordAlertStateStore.new
  end

  def seed_green_baseline!
    alert_store.upsert(@project.id, last_rag: 'green', last_dominant: 'staleness',
                       last_no_data: false, last_score: 80.0)
  end

  # A subscribed + permitted watcher, so scan_and_alert has a recipient.
  def add_watcher!(login)
    u = create_user!(login: login)
    add_member!(project: @project, principal: u, role: @role)
    Pulse::Adapters::RedmineSubscriptionStore.new.watch!(u, @project)
    u
  end

  # ── FC-C6-10: recompute idempotence + writes only pulse_snapshots ───────────
  def test_recompute_is_idempotent_within_max_age
    Pulse::Tasks::Recompute.run
    first = conn.select_value(
      "SELECT MAX(computed_at) FROM pulse_snapshots WHERE project_id = #{@project.id}"
    )
    refute_nil first, 'recompute warmed a snapshot row'

    Pulse::Tasks::Recompute.run # re-run within max-age
    second = conn.select_value(
      "SELECT MAX(computed_at) FROM pulse_snapshots WHERE project_id = #{@project.id}"
    )
    assert_equal first, second, 'a fresh row (within max-age) must NOT be recomputed (idempotent)'
  end

  def test_recompute_writes_no_pulse_alert_states
    wrote_alert_state = false
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      sql = args.last[:sql].to_s
      next if args.last[:name].to_s =~ /SCHEMA|TRANSACTION/i
      wrote_alert_state = true if sql =~ /\A\s*(INSERT|UPDATE|DELETE)\b/i && sql =~ /\bpulse_alert_states\b/i
    end
    Pulse::Tasks::Recompute.run
    refute wrote_alert_state, 'recompute must NEVER write pulse_alert_states'
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ── FC-C6-15 ONCE: fire once; re-run with no change emits nothing ───────────
  def test_scan_fires_once_then_second_run_emits_nothing
    add_watcher!('once_w')
    seed_green_baseline!

    first_events = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    assert_equal 1, first_events.size, 'green->amber emits exactly one event'
    assert_equal :rag_transition, first_events.first.event_type
    # State advanced to amber.
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag]

    ActionMailer::Base.deliveries.clear
    second_events = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    assert_equal [], second_events, 'an unchanged re-run emits NOTHING (state matches, ONCE)'
    assert_equal 0, ActionMailer::Base.deliveries.size, 'no re-delivery on the unchanged re-run'
  end

  def test_first_run_no_prior_state_establishes_baseline_no_alert
    add_watcher!('baseline_w')
    # No prior baseline seeded => first run establishes it, fires nothing (FC-C6-03).
    events = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    assert_equal [], events, 'first run with no prior row => baseline, no alert (no first-cron flood)'
    refute_nil alert_store.find_by_project(@project.id), 'baseline row now written'
  end

  # ── FC-C6-08 / FC-C6-15: partial delivery failure — others still get it, ─────
  #    error logged, state STILL advances, no re-fire on a later run (OI-C6-01).
  def test_partial_delivery_failure_logs_and_still_advances_state
    w1 = add_watcher!('fail_w1')
    w2 = add_watcher!('ok_w2')
    seed_green_baseline!

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    # Everything else the mailer path might call is a no-op.
    %i[info warn debug].each { |m| fake_logger.define_singleton_method(m) { |*| } }

    # Stub Pulse::Mailer.health_alert to RAISE for w1 only.
    raised_for = []
    Pulse::Mailer.stub(:health_alert, ->(user, _event) {
      if user.login == w1.login
        raised_for << user.login
        raise 'SMTP down for w1'
      end
      # For w2, return a mail-like object that responds to deliver_now.
      deliverable = Object.new
      deliverable.define_singleton_method(:deliver_now) do
        ActionMailer::Base.deliveries << OpenStruct.new(to: [user.mail])
        self
      end
      deliverable
    }) do
      Rails.stub(:logger, fake_logger) do
        assert_nothing_raised do
          Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
        end
      end
    end

    assert_includes raised_for, w1.login, 'the mailer raised for recipient#1'
    refute_empty logged, 'the delivery failure for recipient#1 was LOGGED (Rails.logger.error)'
    delivered = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_includes delivered, w2.mail, 'recipient#2 still received the alert despite #1 failing'

    # State STILL advanced despite the partial failure (OI-C6-01).
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'state advances after evaluation regardless of delivery outcome'

    # A third run with unchanged health emits nothing (no re-alert after partial failure).
    ActionMailer::Base.deliveries.clear
    third = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    assert_equal [], third, 'no re-alert after the earlier partial failure (ONCE governs detection)'
  end

  # ── FC-C6-12: scan scores under the canonical/global profile ────────────────
  def test_scan_uses_canonical_profile_alert_state_keyed_by_project_only
    add_watcher!('canon_w')
    seed_green_baseline!
    Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
    # Alert-state row keyed by project_id only — no per-viewer columns exist.
    cols = conn.columns(:pulse_alert_states).map(&:name)
    refute_includes cols, 'visibility_context_id'
    refute_includes cols, 'profile_id'
    assert_equal 1,
                 conn.select_value("SELECT COUNT(*) FROM pulse_alert_states WHERE project_id = #{@project.id}").to_i,
                 'exactly one canonical alert-state row per project'
  end
end
