# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# MIGRATION REVERSIBILITY guard.
# The 20260621000001_create_pulse_snapshots migration must round-trip up -> down
# cleanly: after `up` the pulse_snapshots table EXISTS; after `down` it is ABSENT
# (drop_table leaves table_exists? == false). This backfills a regression guard so the
# planned def-up/def-down hardening (replacing the `change` method) cannot silently
# regress reversibility. Characterization: passes against the current `change` impl (a
# create_table `change` migration is auto-reversible).
#
# Runs on PostgreSQL (the production engine) for parity with the sibling store suites.
class PulseSnapshotsMigrationReversibilityTest < ActiveSupport::TestCase
  # This class cycles DDL (drop_table in setup, create_table via migrate(:up), drop_table via
  # migrate(:down)) inside each test. On MySQL, DDL implicitly COMMITs the surrounding
  # transaction, which would destroy the transactional-fixture savepoint (active_record_1) and
  # cascade "SAVEPOINT ... does not exist" errors into UNRELATED sibling test classes. Disabling
  # transactional fixtures makes this class self-manage its table lifecycle (setup drops,
  # teardown re-migrates + restores schema_migrations) with no savepoint dependency — correct on
  # both MySQL (no cascade) and PostgreSQL (setup/teardown already own the lifecycle explicitly).
  self.use_transactional_tests = false

  MIGRATION_VERSION = 20260621000001
  MIGRATION_PATH = File.expand_path(
    '../../../db/migrate/20260621000001_create_pulse_snapshots.rb', File.expand_path(__FILE__)
  )

  # The profile_id column is added by a SEPARATE later migration. Under transactional fixtures
  # this test's DDL was rolled back, so restoring only the base table was harmless. Non-
  # transactionally (required on MySQL — see the class comment) the drop/re-create is REAL, so
  # teardown MUST restore the COMPLETE schema — base table AND profile_id — or every downstream
  # test that reads pulse_snapshots.profile_id breaks (ASM-07: incomplete teardown must not leak).
  PROFILE_ID_MIGRATION_VERSION = 20260706000001
  PROFILE_ID_MIGRATION_PATH = File.expand_path(
    '../../../db/migrate/20260706000001_add_profile_id_to_pulse_snapshots.rb', File.expand_path(__FILE__)
  )

  def conn
    ActiveRecord::Base.connection
  end

  # Deterministic start state: drop the table if present and remove any
  # schema_migrations row for this version, so up/down apply cleanly regardless of the
  # order the harness ran migrations in.
  def setup
    require MIGRATION_PATH
    conn.drop_table(:pulse_snapshots) if conn.table_exists?(:pulse_snapshots)
    conn.execute(
      "DELETE FROM schema_migrations WHERE version = '#{MIGRATION_VERSION}'"
    )
  end

  # Re-establish the FULL migrated state the rest of the suite depends on, so this test is
  # self-contained and leaves the schema as it found it — base table + profile_id column, and
  # both schema_migrations rows.
  def teardown
    migration.migrate(:up) unless conn.table_exists?(:pulse_snapshots)
    unless migrated_row?(MIGRATION_VERSION)
      conn.execute("INSERT INTO schema_migrations (version) VALUES ('#{MIGRATION_VERSION}')")
    end
    # Restore the profile_id column (a later migration) so downstream tests that read
    # pulse_snapshots.profile_id find it present.
    unless conn.column_exists?(:pulse_snapshots, :profile_id)
      profile_id_migration.migrate(:up)
    end
    unless migrated_row?(PROFILE_ID_MIGRATION_VERSION)
      conn.execute("INSERT INTO schema_migrations (version) VALUES ('#{PROFILE_ID_MIGRATION_VERSION}')")
    end
  end

  def migration
    CreatePulseSnapshots.new
  end

  def profile_id_migration
    require PROFILE_ID_MIGRATION_PATH
    AddProfileIdToPulseSnapshots.new
  end

  def migrated_row?(version = MIGRATION_VERSION)
    conn.select_value(
      "SELECT COUNT(*) FROM schema_migrations WHERE version = '#{version}'"
    ).to_i.positive?
  end

  def test_migration_up_creates_table_then_down_drops_it
    refute conn.table_exists?(:pulse_snapshots),
           'precondition: table absent before up (deterministic start state)'

    migration.migrate(:up)
    assert conn.table_exists?(:pulse_snapshots),
           'after up: pulse_snapshots table must EXIST'

    migration.migrate(:down)
    refute conn.table_exists?(:pulse_snapshots),
           'after down: pulse_snapshots table must be ABSENT (drop_table reversibility)'
  end

  def test_migration_round_trips_repeatedly
    # up -> down -> up leaves the table present and re-creatable — the reversibility guard
    # the def-up/def-down hardening must preserve.
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_snapshots), 'first up creates the table'

    migration.migrate(:down)
    refute conn.table_exists?(:pulse_snapshots), 'down drops the table'

    migration.migrate(:up)
    assert conn.table_exists?(:pulse_snapshots),
           'a second up must re-create the table (round-trip is repeatable)'
  end
end
