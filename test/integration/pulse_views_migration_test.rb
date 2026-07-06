# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# ═══════════════════════════════════════════════════════════════════════════════
# IT-C5-01 — pulse_views MIGRATION (FC-C5-01 / FC-C5-02 / FC-C5-03; AC-C5-01)
# ═══════════════════════════════════════════════════════════════════════════════
# up creates the pulse_views CONFIG table with the exact 13-column shape + indexes on
# user_id and visibility; down drops it cleanly (drop_table drops the indexes too), and
# the round-trip is repeatable (idempotent up->down->up).
#
# INV-C5-CONFIG-NOT-CACHE (FC-C5-03): pulse_views is CONFIG, never the snapshot cache.
# pulse_snapshots (the SOLE reversible cache table) is byte-identical in schema and row
# count across C5 up/down; the migration source contains no :pulse_snapshots token — the
# "one reversible cache table" trust narrative holds (count 1 -> 1).
#
# Mirrors the reversibility idiom in
# test/integration/pulse_snapshots_migration_reversibility_test.rb (deterministic start
# state; teardown re-migrates so the rest of the suite finds the table present).
#
# RED-by-construction: db/migrate/*_create_pulse_views.rb and the CreatePulseViews class
# do not exist yet (LoadError / NameError). A9 authors the migration to this contract.
class PulseViewsMigrationTest < ActiveSupport::TestCase
  # A9 owns the concrete timestamp; the test discovers the file by glob so the timestamp
  # is not pinned here (the class name / table / column shape ARE pinned).
  MIGRATION_GLOB = File.expand_path(
    '../../../db/migrate/*_create_pulse_views.rb', File.expand_path(__FILE__)
  )

  REQUIRED_COLUMNS = %w[
    id name user_id visibility role_ids project_scope scope_params
    lens_ref profile_ref sort prefs created_at updated_at
  ].freeze

  def conn
    ActiveRecord::Base.connection
  end

  def migration_path
    Dir.glob(MIGRATION_GLOB).first
  end

  def migration
    path = migration_path
    raise LoadError, "no *_create_pulse_views.rb migration found (RED: A9 not built yet)" if path.nil?

    require path
    CreatePulseViews.new
  end

  # Deterministic start state: table absent, so up/down apply cleanly.
  def setup
    conn.drop_table(:pulse_views) if conn.table_exists?(:pulse_views)
  end

  # Leave the schema as the rest of the suite expects it (table present + seeded).
  def teardown
    migration.migrate(:up) unless conn.table_exists?(:pulse_views)
  rescue LoadError
    # RED phase: nothing to restore (migration file absent).
  end

  # ── FC-C5-01 — up creates the table with the exact column shape + indexes ──

  def test_up_creates_pulse_views_with_required_columns
    refute conn.table_exists?(:pulse_views), 'precondition: table absent before up'

    migration.migrate(:up)
    assert conn.table_exists?(:pulse_views), 'after up: pulse_views table must EXIST'

    names = conn.columns(:pulse_views).map(&:name)
    REQUIRED_COLUMNS.each do |col|
      assert_includes names, col, "pulse_views must have the '#{col}' column"
    end
  end

  def test_up_creates_indexes_on_user_id_and_visibility
    migration.migrate(:up)
    indexed = conn.indexes(:pulse_views).map { |ix| ix.columns.sort }
    assert_includes indexed, ['user_id'], 'an index on user_id must exist'
    assert_includes indexed, ['visibility'], 'an index on visibility must exist'
  end

  def test_column_nullability_and_defaults_pinned
    migration.migrate(:up)
    cols = conn.columns(:pulse_views).each_with_object({}) { |c, h| h[c.name] = c }

    refute cols['name'].null, 'name must be NOT NULL'
    refute cols['visibility'].null, 'visibility must be NOT NULL'
    refute cols['project_scope'].null, 'project_scope must be NOT NULL'
    assert cols['user_id'].null, 'user_id must be NULLABLE (nil == system/built-in)'

    assert_equal 'private', cols['visibility'].default, "visibility default must be 'private' (FR-C5-04)"
    assert_equal 'all', cols['project_scope'].default, "project_scope default must be 'all'"
  end

  # ── FC-C5-02 — down drops the table cleanly; round-trip repeatable ──

  def test_down_drops_table_then_up_recreates
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_views), 'up creates the table'

    migration.migrate(:down)
    refute conn.table_exists?(:pulse_views),
           'after down: pulse_views must be ABSENT (drop_table reversibility)'

    migration.migrate(:up)
    assert conn.table_exists?(:pulse_views), 'a second up must re-create the table (repeatable round-trip)'
    names = conn.columns(:pulse_views).map(&:name)
    REQUIRED_COLUMNS.each { |c| assert_includes names, c, "re-created table must restore '#{c}'" }
  end

  # ── FC-C5-03 — INV-C5-CONFIG-NOT-CACHE: pulse_snapshots untouched; count 1 -> 1 ──

  def test_pulse_snapshots_untouched_across_c5_up_and_down
    assert conn.table_exists?(:pulse_snapshots),
           'precondition: the sole cache table pulse_snapshots exists'
    before_cols = conn.columns(:pulse_snapshots).map(&:name).sort
    before_rows = conn.select_value('SELECT COUNT(*) FROM pulse_snapshots').to_i

    migration.migrate(:up)
    migration.migrate(:down)

    assert conn.table_exists?(:pulse_snapshots),
           'pulse_snapshots must survive C5 up/down (it is the CACHE table, not CONFIG)'
    assert_equal before_cols, conn.columns(:pulse_snapshots).map(&:name).sort,
                 'pulse_snapshots column set must be byte-identical across C5 up/down'
    assert_equal before_rows, conn.select_value('SELECT COUNT(*) FROM pulse_snapshots').to_i,
                 'pulse_snapshots row count must be unchanged (C5 never writes the cache)'
  end

  def test_migration_source_references_no_pulse_snapshots_token
    src = File.read(migration_path)
    refute_match(/pulse_snapshots/, src,
                 'the C5 migration must reference pulse_views ONLY — no :pulse_snapshots token ' \
                 '(INV-C5-CONFIG-NOT-CACHE)')
  end

  def test_exactly_one_reversible_cache_table
    # The cache-table count invariant: pulse_snapshots is the ONE cache table; pulse_views
    # is CONFIG. Both exist after up, but only pulse_snapshots is the cache category.
    migration.migrate(:up)
    assert conn.table_exists?(:pulse_snapshots), 'the one cache table is present'
    assert conn.table_exists?(:pulse_views), 'the config table is present (distinct category)'
  end
end
