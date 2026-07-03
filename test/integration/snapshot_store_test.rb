# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'date'

# CA-04/05/06/08 + FC-CA-05/06/07/08 + BR-03: ActiveRecordSnapshotStore + the
# pulse_snapshots migration. Asserts OBSERVABLE POST-STATE: the migrated table +
# UNIQUE constraint; idempotent insert-or-ignore convergence to ONE row; scoped
# invalidate_project returning a count; and the Date/Symbol round-trip fidelity that
# lets a deserialized snapshot reconstruct ProjectMetrics and score identically.
#
# Postgres-gated (FC-CA-38). RED until A9 builds the adapter + migration.
class SnapshotStoreTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    @pid = 4242
    @ctx = 'ctxA'
    @fp = 'fpA'
    @payload = { 'project_id' => @pid, 'reference_date' => '2026-06-10',
                 'effort_open' => 1, 'effort_total' => 2, 'risk_raw' => 0,
                 'blocked_count' => 0, 'risk_mapped' => false, 'effort_mapped' => false,
                 'event_series' => [], 'version_due_dates' => [] }
  end

  def conn
    ActiveRecord::Base.connection
  end

  def rows_for(pid)
    conn.select_value("SELECT COUNT(*) FROM pulse_snapshots WHERE project_id = #{pid.to_i}").to_i
  end

  # ─────────────── FC-CA-05: migration created the table + UNIQUE ────────────

  def test_pulse_snapshots_table_exists_with_columns
    assert conn.table_exists?(:pulse_snapshots), 'migration must create pulse_snapshots'
    cols = conn.columns(:pulse_snapshots).map(&:name)
    %w[id project_id visibility_context_id snapshot_fingerprint payload
       computed_at created_at].each do |c|
      assert_includes cols, c, "pulse_snapshots must have column #{c}"
    end
  end

  def test_pulse_snapshots_has_three_column_unique_index
    idx = conn.indexes(:pulse_snapshots).select(&:unique)
    triple = %w[project_id visibility_context_id snapshot_fingerprint].sort
    assert idx.any? { |i| i.columns.sort == triple },
           'a UNIQUE index on (project_id, visibility_context_id, snapshot_fingerprint) is required'
  end

  def test_migration_does_not_touch_redmine_core_tables
    # The plugin-prefixed table collides with no core table (CD-CA-03).
    refute conn.table_exists?(:pulse_issues)
    assert conn.table_exists?(:issues), 'core issues table intact'
  end

  # ─────────────────── FC-CA-04/06: fetch_row + idempotent store ─────────────

  def test_fetch_row_returns_nil_on_miss
    assert_nil @store.fetch_row(@pid, @ctx, 'nope')
  end

  def test_store_then_fetch_row_round_trips_a_hash
    @store.store(@pid, @ctx, @fp, @payload)
    got = @store.fetch_row(@pid, @ctx, @fp)
    assert_kind_of Hash, got
    assert_kind_of Hash, got[:payload]
    assert_equal @pid, got[:payload]['project_id']
  end

  def test_store_is_idempotent_one_row_no_raise
    @store.store(@pid, @ctx, @fp, @payload)
    assert_equal 1, rows_for(@pid)
    # Second store with the SAME key: silent no-op (insert-or-ignore), no raise.
    assert_nothing_raised do
      @store.store(@pid, @ctx, @fp, @payload)
    end
    assert_equal 1, rows_for(@pid), 'duplicate-key store converges to exactly one row'
  end

  def test_concurrent_duplicate_insert_does_not_raise
    # Simulate the concurrent cold-miss: a raw insert lands first, then store() of the
    # same key must swallow the unique-constraint violation.
    @store.store(@pid, @ctx, @fp, @payload)
    assert_nothing_raised('RecordNotUnique must be swallowed (ON CONFLICT DO NOTHING)') do
      @store.store(@pid, @ctx, @fp, @payload.merge('effort_open' => 99))
    end
    assert_equal 1, rows_for(@pid)
  end

  # ── RT-04 (security-S2-dos): prune SUPERSEDED fingerprints on store ──────────
  # Storing a NEW fingerprint for an existing (project_id, visibility_context_id) leaves the
  # OLD-fingerprint row behind. Every viewer's data change churns the fingerprint, so the
  # (pid, ctx) cell accretes one dead row per change without bound; every warm fetch then
  # SELECTs + JSON-parses ALL of them (unbounded scan + memory — an availability lever). The
  # intended fix prunes the superseded rows for that (pid, ctx) when a genuinely NEW
  # fingerprint is stored, so the cell holds exactly the current snapshot.

  def ctx_fp_rows(pid, ctx)
    conn.select_value(
      "SELECT COUNT(*) FROM pulse_snapshots " \
      "WHERE project_id = #{pid.to_i} AND visibility_context_id = '#{ctx}'"
    ).to_i
  end

  def fps_for(pid, ctx)
    conn.select_values(
      "SELECT snapshot_fingerprint FROM pulse_snapshots " \
      "WHERE project_id = #{pid.to_i} AND visibility_context_id = '#{ctx}'"
    )
  end

  # RED now: storing fp2 over the same (pid, ctx) with a DIFFERENT fingerprint must leave
  # ONLY the fp2 row (the superseded fp1 row is pruned). Currently BOTH rows persist.
  def test_store_new_fingerprint_prunes_superseded_row
    @store.store(@pid, @ctx, 'fp1', @payload)
    @store.store(@pid, @ctx, 'fp2', @payload.merge('effort_open' => 7))

    assert_equal 1, ctx_fp_rows(@pid, @ctx),
                 'a NEW fingerprint for the same (pid, ctx) supersedes the old one — ' \
                 'exactly ONE row remains (RT-04 prune)'
    assert_equal ['fp2'], fps_for(@pid, @ctx),
                 'the surviving row carries the CURRENT fingerprint (fp2); fp1 was pruned'
  end

  # The prune is scoped to the SAME (pid, ctx): a store under a different ctx for the same
  # project must NOT be pruned by a store under this ctx (each cell is independent).
  def test_store_new_fingerprint_prune_is_scoped_to_same_pid_ctx
    @store.store(@pid, 'ctxA', 'fp1', @payload)
    @store.store(@pid, 'ctxB', 'fpB', @payload) # a DIFFERENT cell for the same project
    @store.store(@pid, 'ctxA', 'fp2', @payload.merge('effort_open' => 9)) # supersede ctxA only

    assert_equal ['fp2'], fps_for(@pid, 'ctxA'), 'ctxA supersedes to fp2'
    assert_equal 1, ctx_fp_rows(@pid, 'ctxB'),
                 'a different (pid, ctx) cell is untouched by the ctxA prune (scoped)'
  end

  # GREEN companion: a SAME-KEY store/refresh (identical fingerprint — the snapshot-max-age
  # in-place update path) must NOT prune/delete the row. Only a genuinely NEW fingerprint
  # supersedes. #refresh uses update_all on the SAME key -> one row, no delete.
  def test_same_key_refresh_does_not_prune_the_row
    @store.store(@pid, @ctx, @fp, @payload)
    assert_equal 1, ctx_fp_rows(@pid, @ctx)
    @store.refresh(@pid, @ctx, @fp, @payload.merge('effort_open' => 3)) # SAME key, new payload
    assert_equal 1, ctx_fp_rows(@pid, @ctx),
                 'a same-key refresh (same fingerprint) overwrites in place — no prune, one row'
    assert_equal [@fp], fps_for(@pid, @ctx), 'the row keeps its (unchanged) fingerprint'
  end

  # GREEN companion: a duplicate SAME-KEY store (insert-or-ignore) likewise leaves the row
  # in place — a same-fingerprint re-store is NOT a supersede and must NOT prune.
  def test_same_key_store_does_not_prune_the_row
    @store.store(@pid, @ctx, @fp, @payload)
    @store.store(@pid, @ctx, @fp, @payload) # identical key -> insert-or-ignore, no supersede
    assert_equal 1, ctx_fp_rows(@pid, @ctx),
                 'a same-key re-store is idempotent — no prune, exactly one row'
    assert_equal [@fp], fps_for(@pid, @ctx)
  end

  # ───────────────── FC-CA-08: scoped invalidate_project + count ─────────────

  def test_invalidate_project_deletes_only_target_returns_count
    @store.store(@pid, 'c1', 'f1', @payload)
    @store.store(@pid, 'c2', 'f2', @payload)
    other = @pid + 1
    @store.store(other, 'c1', 'f1', @payload.merge('project_id' => other))

    deleted = @store.invalidate_project(@pid)
    assert_equal 2, deleted, 'invalidate_project returns the affected-row count'
    assert_equal 0, rows_for(@pid), 'all rows for the target project deleted'
    assert_equal 1, rows_for(other), 'rows for a different project are untouched'
  end

  def test_invalidate_empty_project_returns_zero_no_error
    assert_equal 0, @store.invalidate_project(999_999), 'idempotent: deletes 0, no error'
  end

  # ─────────────── FC-CA-07 / BR-03: Date/Symbol round-trip fidelity ─────────

  def test_round_trip_reconstructs_project_metrics_with_plain_date
    metrics = Pulse::Domain::ProjectMetrics.new(
      project_id: 7, reference_date: Date.new(2026, 6, 10),
      effort_open: 3, effort_total: 5, risk_raw: 0, blocked_count: 1,
      risk_mapped: false, effort_mapped: false,
      event_series: [{ date: Date.new(2026, 6, 5), type: :issue_created }],
      version_due_dates: [{ version_id: 42, due_date: Date.new(2026, 9, 30), name: 'v1.0' }]
    )
    # The store/controller serialize+deserialize pair must re-hydrate Date strings to
    # Date and provenance/type strings to Symbols, or ProjectMetrics rejects them.
    payload = @store.respond_to?(:serialize_metrics) ? @store.serialize_metrics(metrics) : nil
    skip_helper = payload.nil?
    @store.store(7, @ctx, @fp, payload || @payload)
    row = @store.fetch_row(7, @ctx, @fp)
    assert_kind_of Hash, row
    fetched = row[:payload]
    assert_kind_of Hash, fetched

    unless skip_helper
      rebuilt = @store.deserialize_metrics(fetched)
      assert_instance_of Date, rebuilt.reference_date,
                         'reference_date re-hydrates to a PLAIN Date (FR-01)'
      assert_instance_of Date, rebuilt.event_series.first[:date]
      assert_equal :issue_created, rebuilt.event_series.first[:type], 'type re-hydrated to Symbol'
      # Determinism: scoring the deserialized snapshot equals scoring the original.
      cfg = Pulse::Domain::ScoringConfig.new
      a = Pulse::Domain::Scoring.score(metrics, @clock, cfg).health_score
      b = Pulse::Domain::Scoring.score(rebuilt, @clock, cfg).health_score
      assert_equal a, b, 'round-trip is lossless w.r.t. the score (FC-CA-07)'
    end
  end

  # ── snapshot-max-age-refresh (CT-02 EVOLUTION): SnapshotStore#refresh ─────────
  # refresh(project_id, visibility_context_id, fingerprint, payload) OVERWRITES the row
  # for that EXACT key (payload replaced + computed_at bumped to ~now), creating it if
  # absent (defensive). Distinct from #store (insert-or-ignore). Writes ONLY the SAME key
  # (no new row — the growth characteristic is unchanged). RED until GREEN adds #refresh.

  def computed_at_for(pid, ctx, fp)
    conn.select_value(
      "SELECT computed_at FROM pulse_snapshots " \
      "WHERE project_id = #{pid.to_i} AND visibility_context_id = '#{ctx}' " \
      "AND snapshot_fingerprint = '#{fp}'"
    )
  end

  def test_refresh_overwrites_payload_for_the_key
    @store.store(@pid, @ctx, @fp, @payload)
    new_payload = @payload.merge('effort_open' => 999)
    @store.refresh(@pid, @ctx, @fp, new_payload)
    got = @store.fetch_row(@pid, @ctx, @fp)
    assert_equal 999, got[:payload]['effort_open'],
                 'refresh must OVERWRITE the payload in place (unlike store insert-or-ignore)'
  end

  def test_refresh_bumps_computed_at
    @store.store(@pid, @ctx, @fp, @payload)
    old_at = @store.fetch_row(@pid, @ctx, @fp)[:computed_at]
    # Force a distinguishable later write instant.
    travel_to(Time.now.utc + 3600) do
      @store.refresh(@pid, @ctx, @fp, @payload)
    end
    new_at = @store.fetch_row(@pid, @ctx, @fp)[:computed_at]
    assert_operator new_at, :>, old_at,
                    'refresh must bump computed_at to the fresh write instant'
  end

  def test_refresh_does_not_add_a_new_row
    @store.store(@pid, @ctx, @fp, @payload)
    assert_equal 1, rows_for(@pid)
    @store.refresh(@pid, @ctx, @fp, @payload.merge('effort_open' => 7))
    assert_equal 1, rows_for(@pid),
                 'refresh overwrites the SAME key -> exactly one row (no unbounded growth)'
  end

  def test_refresh_leaves_other_keys_untouched
    @store.store(@pid, @ctx, @fp, @payload)
    @store.store(@pid, 'ctxB', 'fpB', @payload.merge('effort_open' => 5))
    @store.refresh(@pid, @ctx, @fp, @payload.merge('effort_open' => 999))
    other = @store.fetch_row(@pid, 'ctxB', 'fpB')
    assert_equal 5, other[:payload]['effort_open'],
                 'refresh must touch ONLY its keyed row; other keys are unchanged'
  end

  def test_refresh_creates_the_row_when_absent
    assert_nil @store.fetch_row(@pid, @ctx, 'newfp'), 'precondition: no row for the key'
    @store.refresh(@pid, @ctx, 'newfp', @payload)
    got = @store.fetch_row(@pid, @ctx, 'newfp')
    assert_kind_of Hash, got,
                   'refresh must CREATE the row defensively when none exists (store fallback)'
    assert_equal @pid, got[:payload]['project_id']
  end

  def test_refresh_writes_no_redmine_domain_table
    @store.store(@pid, @ctx, @fp, @payload)
    writes = capture_write_statements do
      @store.refresh(@pid, @ctx, @fp, @payload.merge('effort_open' => 2))
    end
    assert_equal [], writes,
                 "refresh touches only pulse_snapshots (got: #{writes.inspect})"
  end

  # ──────────────── READ-ONLY: store/invalidate write no domain table ────────

  def test_store_and_invalidate_write_no_redmine_domain_table
    writes = capture_write_statements do
      @store.store(@pid, @ctx, @fp, @payload)
      @store.invalidate_project(@pid)
    end
    assert_equal [], writes,
                 "snapshot store touches only pulse_snapshots (got: #{writes.inspect})"
  end
end
