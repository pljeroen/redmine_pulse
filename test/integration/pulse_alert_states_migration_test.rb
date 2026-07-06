# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# IT-C6-06 / FC-C6-05 / FC-C6-12 / FC-C6-13 — pulse_alert_states migration + store.
#
# A reversible migration creates pulse_alert_states with columns
#   {project_id:integer (UNIQUE index), last_rag:string, last_dominant:string,
#    last_no_data:boolean, last_score:float, updated_at:datetime}
# keyed by project_id ONLY (per-project canonical profile — NEVER visibility_context_id
# / profile_id, contrast pulse_snapshots). up creates the table + unique index; down
# drops it cleanly with NO foreign keys to Redmine domain tables. pulse_snapshots is
# UNCHANGED (separate table).
#
# ActiveRecordAlertStateStore round-trips find_by_project / upsert; a second upsert on
# the same project_id UPDATES (never a 2nd row) — enforced by the unique index.
#
# RED-by-construction: the migration file + PulseAlertState model + the store adapter
# do not exist yet (LoadError / NameError / missing relation). A9 makes it GREEN.
#
# Postgres-gated for parity with the sibling migration/store suites.
class PulseAlertStatesMigrationTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  MIGRATION_VERSION = 20260706000003
  MIGRATION_PATH = File.expand_path(
    '../../../db/migrate/20260706000003_create_pulse_alert_states.rb', File.expand_path(__FILE__)
  )

  def conn
    ActiveRecord::Base.connection
  end

  def setup
    unless conn.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{conn.adapter_name})"
    end
    require MIGRATION_PATH
    conn.drop_table(:pulse_alert_states) if conn.table_exists?(:pulse_alert_states)
    conn.execute("DELETE FROM schema_migrations WHERE version = '#{MIGRATION_VERSION}'")
  end

  def teardown
    return unless conn.adapter_name =~ /postgres/i

    migration.migrate(:up) unless conn.table_exists?(:pulse_alert_states)
    unless migrated_row?
      conn.execute("INSERT INTO schema_migrations (version) VALUES ('#{MIGRATION_VERSION}')")
    end
  end

  def migration
    CreatePulseAlertStates.new
  end

  def migrated_row?
    conn.select_value(
      "SELECT COUNT(*) FROM schema_migrations WHERE version = '#{MIGRATION_VERSION}'"
    ).to_i.positive?
  end

  def columns
    conn.columns(:pulse_alert_states).map(&:name).sort
  end

  # ── up creates the table with the six columns ───────────────────────────────
  def test_up_creates_table_with_expected_columns
    refute conn.table_exists?(:pulse_alert_states), 'precondition: table absent before up'
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_alert_states), 'after up: table must EXIST'
    expected = %w[id last_dominant last_no_data last_rag last_score project_id updated_at].sort
    # id is implicit; assert the six declared columns are present (updated_at + the five state fields).
    %w[project_id last_rag last_dominant last_no_data last_score updated_at].each do |c|
      assert_includes columns, c, "pulse_alert_states must have a #{c} column"
    end
    # It must NEVER be keyed by these (per-project only, DEC-10 / FC-C6-12).
    refute_includes columns, 'visibility_context_id',
                    'pulse_alert_states must NOT carry visibility_context_id (per-project only)'
    refute_includes columns, 'profile_id',
                    'pulse_alert_states must NOT carry profile_id (canonical profile only)'
  end

  # ── unique index on project_id (one row per project) ────────────────────────
  def test_project_id_has_unique_index
    migration.migrate(:up)
    idx = conn.indexes(:pulse_alert_states).find { |i| i.columns == ['project_id'] }
    refute_nil idx, 'a project_id index must exist'
    assert idx.unique, 'the project_id index must be UNIQUE (one row per project)'
  end

  # ── down drops the table cleanly (reversibility) ────────────────────────────
  def test_down_drops_table_cleanly
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_alert_states)
    migration.migrate(:down)
    refute conn.table_exists?(:pulse_alert_states),
           'after down: pulse_alert_states must be ABSENT (reversible)'
  end

  def test_round_trips_repeatedly
    migration.migrate(:up)
    migration.migrate(:down)
    refute conn.table_exists?(:pulse_alert_states), 'down drops the table'
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_alert_states), 'a second up re-creates it (repeatable)'
  end

  # ── pulse_snapshots schema UNCHANGED by this migration ──────────────────────
  def test_pulse_snapshots_columns_unchanged
    before = conn.columns(:pulse_snapshots).map(&:name).sort
    migration.migrate(:up)
    after = conn.columns(:pulse_snapshots).map(&:name).sort
    assert_equal before, after, 'pulse_snapshots schema must be untouched by the alert-state migration'
  end

  # ── store round-trip: upsert then find_by_project; second upsert UPDATES ─────
  def test_store_upsert_find_by_project_round_trip_and_single_row
    migration.migrate(:up)
    PulseAlertState.reset_column_information if defined?(PulseAlertState)
    store = Pulse::Adapters::ActiveRecordAlertStateStore.new

    assert_nil store.find_by_project(4242), 'no row yet => nil (first run)'

    store.upsert(4242, last_rag: 'green', last_dominant: 'staleness',
                 last_no_data: false, last_score: 80.0)
    row = store.find_by_project(4242)
    refute_nil row
    assert_equal 'green', row[:last_rag]
    assert_equal 'staleness', row[:last_dominant]
    assert_equal false, row[:last_no_data]
    assert_in_delta 80.0, row[:last_score], 1e-9

    # A second upsert on the same project_id UPDATES, does not insert a 2nd row.
    store.upsert(4242, last_rag: 'amber', last_dominant: 'risk_load',
                 last_no_data: false, last_score: 55.0)
    count = conn.select_value('SELECT COUNT(*) FROM pulse_alert_states WHERE project_id = 4242').to_i
    assert_equal 1, count, 'one row per project_id (unique-index upsert, not insert)'
    assert_equal 'amber', store.find_by_project(4242)[:last_rag], 'second upsert updated the row'
  end
end
