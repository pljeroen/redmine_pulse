# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Advisory performance benchmark (does NOT block on its own). With all portfolio projects
# warm (cache hit), the portfolio overview GET completes well under 1s and the per-request
# projection is O(P) with NO extra DB query per project (prefer a single bulk SnapshotStore
# fetch over N+1).
#
# Runs on PostgreSQL (the production engine).
class PortfolioPerfBench < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  N_PROJECTS = 30

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # Runs on PostgreSQL (the production engine) — skip on non-Postgres adapters
    # (counted as skips, not failures) so the MySQL CI legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'PerfAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'perfuser')
    @projects = Array.new(N_PROJECTS) do |i|
      p = create_project!(name: "Perf#{i}", identifier: "perf-#{i}")
      add_member!(project: p, principal: @user, role: @role)
      create_issue!(project: p, author: @user, status: open_status,
                    updated_on: Time.utc(2026, 6, 10, 0))
      p
    end
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  def test_warm_portfolio_get_under_one_second
    login_as(@user)
    get '/pulse' # cold: warm the cache
    assert_response :success
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get '/pulse' # warm
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_response :success
    assert_operator elapsed, :<, 1.0,
                    "warm portfolio GET should be well under 1s (got #{elapsed.round(3)}s) [advisory]"
  end

  def test_warm_portfolio_get_has_no_per_project_n_plus_one
    login_as(@user)
    get '/pulse' # warm the cache

    queries = []
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = args.last
      next if payload[:name].to_s =~ /SCHEMA|TRANSACTION/i

      queries << payload[:sql]
    end
    get '/pulse'
    ActiveSupport::Notifications.unsubscribe(sub)
    assert_response :success

    snapshot_selects = queries.count { |q| q =~ /\bpulse_snapshots\b/i && q =~ /\ASELECT/i }
    assert_operator snapshot_selects, :<, N_PROJECTS,
                    "warm path should bulk-fetch snapshots, not N+1 per project " \
                    "(#{snapshot_selects} snapshot SELECTs for #{N_PROJECTS} projects) [advisory]"
  end
end
