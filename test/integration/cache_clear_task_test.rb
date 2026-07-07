# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'date'

# The pulse:cache:clear rake task underlying behavior.
# The rake task body is a thin shell over the store's clear_all (global) and
# invalidate_project (one project); this suite exercises those underlying methods
# the task drives — asserting OBSERVABLE POST-STATE (rows deleted) — so the
# admin-facing global cache flush is proven, independent of rake-runner wiring.
#
# Runs on PostgreSQL (the production engine) for parity with the sibling store suite.
class CacheClearTaskTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    @store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    @payload = { 'project_id' => 0, 'reference_date' => '2026-06-10',
                 'effort_open' => 1, 'effort_total' => 2, 'risk_raw' => 0,
                 'blocked_count' => 0, 'risk_mapped' => false, 'effort_mapped' => false,
                 'event_series' => [], 'version_due_dates' => [] }
  end

  def conn
    ActiveRecord::Base.connection
  end

  def total_rows
    conn.select_value('SELECT COUNT(*) FROM pulse_snapshots').to_i
  end

  def rows_for(pid)
    conn.select_value("SELECT COUNT(*) FROM pulse_snapshots WHERE project_id = #{pid.to_i}").to_i
  end

  def seed!(pid, ctx, fp)
    @store.store(pid, ctx, fp, @payload.merge('project_id' => pid))
  end

  # ── clear_all: GLOBAL flush across every project + context ──────────────────

  def test_clear_all_deletes_every_row_returns_count
    seed!(101, 'c1', 'f1')
    seed!(101, 'c2', 'f2')
    seed!(202, 'c1', 'f1')
    assert_equal 3, total_rows, 'precondition: three cached rows across two projects'

    deleted = @store.clear_all
    assert_equal 3, deleted, 'clear_all returns the affected-row count'
    assert_equal 0, total_rows, 'clear_all leaves the cache empty (global flush)'
  end

  def test_clear_all_on_empty_cache_returns_zero_no_error
    assert_equal 0, total_rows
    assert_nothing_raised do
      assert_equal 0, @store.clear_all, 'idempotent: clears 0, no error'
    end
  end

  # ── per-project scope ([project_id] form) leaves other projects intact ──────

  def test_invalidate_project_clears_only_target
    seed!(101, 'c1', 'f1')
    seed!(202, 'c1', 'f1')

    deleted = @store.invalidate_project(101)
    assert_equal 1, deleted
    assert_equal 0, rows_for(101), 'target project cache cleared'
    assert_equal 1, rows_for(202), 'other project untouched'
  end

  # ── clear_all writes ONLY pulse_snapshots (read-only w.r.t. Redmine tables) ────────

  def test_clear_all_writes_no_redmine_domain_table
    seed!(101, 'c1', 'f1')
    writes = capture_write_statements do
      @store.clear_all
    end
    assert_equal [], writes,
                 "clear_all touches only pulse_snapshots (got: #{writes.inspect})"
  end
end
