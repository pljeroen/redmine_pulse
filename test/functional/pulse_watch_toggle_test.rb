# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# The USER-FACING "Watch project health" opt-in. A logged-in
# viewer with :view_pulse toggles the subscription from the cockpit:
#   POST /projects/:id/pulse/watch    -> subscribe   (Watcher row 'PulseHealth')
#   POST /projects/:id/pulse/unwatch  -> unsubscribe
# and the subscription is EXACTLY what RedmineSubscriptionStore#subscribers_for reads, so a
# watched user receives the scan email and an unwatched user does not.
#
# End-to-end negative/positive chain (through the real HTTP surface):
#   (1) before watching, the viewer is NOT in subscribers_for and receives NO email;
#   (2) after POST watch, the viewer IS in subscribers_for and RECEIVES the scan email;
#   (3) after POST unwatch, the viewer is again absent from subscribers_for and receives none.
# The scan itself is driven separately (rake composition root) — the watch action starts NO
# scan (additive), it only writes the viewer's own subscription record.
#
# Postgres-gated for parity with the sibling alert suites (the permission SQL is verified on
# the engine).
class PulseWatchToggleTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear

    @view_role = create_role!(name: 'WatchViewer', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'WatchP', identifier: 'watch-p',
                               modules: %w[issue_tracking pulse repository])
    @user = create_user!(login: 'watch_u')
    add_member!(project: @project, principal: @user, role: @view_role)
    # A seeded issue so the project scores (scan has something to transition on).
    create_issue!(project: @project, author: User.where(admin: true).first || User.first,
                  status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  def subscription_store
    Pulse::Adapters::RedmineSubscriptionStore.new
  end

  def subscriber_logins(project)
    subscription_store.subscribers_for(project.id).map(&:login).sort
  end

  # Drive a green->amber transition and return the recipient mails that received an email.
  def scan_and_delivered_mails(project)
    Pulse::Adapters::ActiveRecordAlertStateStore.new.upsert(
      project.id, last_rag: 'green', last_dominant: 'staleness',
      last_no_data: false, last_score: 80.0
    )
    ActionMailer::Base.deliveries.clear
    Pulse::Tasks::ScanAndAlert.run(project_ids: [project.id], force_rag: :amber)
    ActionMailer::Base.deliveries.flat_map(&:to).sort
  end

  # ── the cockpit offers the Watch toggle to a permitted logged-in viewer ──────
  def test_cockpit_renders_watch_toggle_for_permitted_viewer
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    # Not yet watching => the "Watch" (subscribe) button POSTs to pulse#watch.
    assert_select "form[action=?][method=post]", "/projects/#{@project.identifier}/pulse/watch",
                  { minimum: 1 },
                  'the cockpit must offer a "Watch project health" toggle'
  end

  # ── POST watch => the viewer becomes a subscriber and RECEIVES the scan email ─
  def test_watch_creates_subscription_that_scan_delivers_to
    # Precondition: not subscribed, no delivery.
    refute_includes subscriber_logins(@project), @user.login,
                    'precondition: viewer is not subscribed before clicking Watch'
    refute_includes scan_and_delivered_mails(@project), @user.mail,
                    'precondition: an unsubscribed viewer receives no scan email'

    login_as(@user)
    post "/projects/#{@project.identifier}/pulse/watch"
    assert_response :redirect,
                    'POST watch must redirect back to the cockpit (a plain member toggle)'

    # The subscription is EXACTLY what subscribers_for reads.
    assert_includes subscriber_logins(@project), @user.login,
                    'after POST watch, the viewer must be in subscribers_for'
    # ...and a subsequent scan delivers to them (the alert chain, driven separately).
    assert_includes scan_and_delivered_mails(@project), @user.mail,
                    'after watching, the transition scan must deliver the alert email to the watcher'
  end

  # ── POST unwatch => the viewer is unsubscribed and receives NO email ─────────
  def test_unwatch_removes_subscription_and_stops_delivery
    login_as(@user)
    post "/projects/#{@project.identifier}/pulse/watch"
    assert_includes subscriber_logins(@project), @user.login, 'precondition: watching after Watch'

    # Now the cockpit offers the Unwatch toggle; POST it.
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_select "form[action=?][method=post]", "/projects/#{@project.identifier}/pulse/unwatch",
                  { minimum: 1 },
                  'while watching, the cockpit must offer the Unwatch toggle'

    post "/projects/#{@project.identifier}/pulse/unwatch"
    assert_response :redirect

    refute_includes subscriber_logins(@project), @user.login,
                    'after POST unwatch, the viewer must NOT be in subscribers_for'
    refute_includes scan_and_delivered_mails(@project), @user.mail,
                    'after unwatching, the transition scan must NOT deliver to the ex-watcher'
  end

  # ── the watch action writes ONE subscription row and starts NO alert scan ────
  # additive: the toggle must not read/write pulse_alert_states in the request cycle
  # (that is the scan's table; the watch action only touches the Watcher subscription row).
  def test_watch_toggle_does_not_touch_alert_state_table
    reads_or_writes = []
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      sql = args.last[:sql].to_s
      next if args.last[:name].to_s =~ /SCHEMA|TRANSACTION/i
      reads_or_writes << sql if sql =~ /\bpulse_alert_states\b/i
    end
    login_as(@user)
    post "/projects/#{@project.identifier}/pulse/watch"
    post "/projects/#{@project.identifier}/pulse/unwatch"
    assert_equal [], reads_or_writes,
                 "the Watch toggle must not read/write pulse_alert_states in the request cycle " \
                 "(additive — the alert scan stays rake-only): #{reads_or_writes.inspect}"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ── anonymous / unauthenticated cannot subscribe (403/redirect, no row) ──────
  def test_anonymous_cannot_watch
    # No login: the per-action authorize ladder rejects (:view_pulse is not held anonymously
    # on a private project) — the visibility ladder 404s a non-visible project. Either way,
    # no subscription is written.
    post "/projects/#{@project.identifier}/pulse/watch"
    refute_includes subscriber_logins(@project), @user.login,
                    'an unauthenticated POST must not create a subscription'
  end
end
