# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'date'

# snapshot-max-age-refresh (CT-02 EVOLUTION) — the CORE engine age-check.
#
# A configurable snapshot_max_age_minutes freshness cap: when PulseProjection::Engine
# finds a cached snapshot OLDER than the cap, the first requester recomputes and
# OVERWRITES it in place (fresh computed_at). Lazy, request-triggered (no cron).
#   * fresh row (age < cap)      -> served as-is, NO store write, computed_at unchanged.
#   * stale row (age >= cap)     -> refresh: computed_at bumped to ~clock.now, same key.
#   * snapshot_max_age_minutes=0 -> DISABLED: a stale row is NOT refreshed.
#   * cold miss (nil)            -> warm (unchanged).
#   * portfolio: a MIX {fresh, stale, missing} -> only stale + missing write.
#   * boundary: age exactly == cap -> refresh (inclusive at the boundary).
#
# The age check reads @clock.now (injectable/testable), NOT a bare Time.now. This
# suite drives the REAL engine (real store + RedmineMetricsSource) against a real
# project, with a CONTROLLABLE clock double exposing BOTH #today and #now, and forces
# a row's computed_at via SQL to place it fresh / stale / exactly-at-boundary.
#
# The fingerprint EXCLUDES the clock (DEC-11), so advancing #now does not change the
# key — only the age-refresh overwrites the row. Postgres-gated (COND-A8-004). RED
# until GREEN adds Clock#now, SnapshotStore#refresh, the setting, and the engine
# age-check on project_projection + portfolio_projections.
class SnapshotAgeRefreshTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  # A clock double that satisfies BOTH the existing #today contract AND the new #now
  # contract the age-check requires. `now` is fully controllable so a test can place the
  # cached row's age relative to the cap without sleeping.
  ControllableClock = Struct.new(:date, :instant) do
    def today
      date
    end

    def now
      instant
    end
  end

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @now = Time.utc(2026, 6, 20, 12, 0, 0)
    @clock = ControllableClock.new(Date.new(2026, 6, 20), @now)
    @store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    @settings = Pulse::Adapters::RedmineSettingsProvider.new
    @role = create_role!(name: 'AgeAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'ageuser')
    @project = create_project!(name: 'Age', identifier: 'age-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 5, 10, 0))
    User.current = @user
  end

  def build_engine
    metrics_source = Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: @settings, clock: @clock
    )
    Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: metrics_source, store: @store,
      settings_provider: @settings, clock: @clock
    )
  end

  def conn
    ActiveRecord::Base.connection
  end

  def rows_for(pid)
    conn.select_value("SELECT COUNT(*) FROM pulse_snapshots WHERE project_id = #{pid.to_i}").to_i
  end

  # Read the stored computed_at for the project's single cache row (as a Time).
  def stored_computed_at(pid)
    v = conn.select_value(
      "SELECT computed_at FROM pulse_snapshots WHERE project_id = #{pid.to_i} LIMIT 1"
    )
    v.is_a?(Time) ? v : Time.parse(v.to_s)
  end

  # Force the project's single cache row to a specific computed_at (simulate age).
  def force_computed_at!(pid, instant)
    conn.execute(
      "UPDATE pulse_snapshots SET computed_at = '#{instant.utc.iso8601}' " \
      "WHERE project_id = #{pid.to_i}"
    )
  end

  # Warm the cache once (cold GET path), then return the engine for the assertions.
  def warm_once!
    engine = build_engine
    engine.project_projection(@user, @project)
    assert_equal 1, rows_for(@project.id), 'precondition: cold warm stored one row'
    engine
  end

  # ─────────────── (d) cold miss still warms (unchanged) ─────────────

  def test_cold_miss_warms_one_row
    with_settings_max_age(60) do
      engine = build_engine
      assert_equal 0, rows_for(@project.id), 'precondition: empty cache'
      engine.project_projection(@user, @project)
      assert_equal 1, rows_for(@project.id),
                   'cold miss still warms exactly one snapshot row (unchanged)'
    end
  end

  # ─────────────── (a) fresh row is NOT refreshed ─────────────

  def test_fresh_row_is_not_refreshed
    with_settings_max_age(60) do
      warm_once!
      # Place the row 10 minutes old; cap is 60 -> fresh.
      fresh_at = @now - (10 * 60)
      force_computed_at!(@project.id, fresh_at)
      engine = build_engine
      engine.project_projection(@user, @project)
      after = stored_computed_at(@project.id)
      assert_equal 1, rows_for(@project.id), 'fresh row: no new row'
      assert_in_delta fresh_at.to_f, after.to_f, 1.0,
                      'a row FRESHER than the cap must NOT be refreshed (computed_at unchanged)'
    end
  end

  # ─────────────── (b) stale row triggers refresh ─────────────

  def test_stale_row_is_refreshed_and_computed_at_bumped
    with_settings_max_age(60) do
      warm_once!
      # Place the row 120 minutes old; cap is 60 -> stale.
      stale_at = @now - (120 * 60)
      force_computed_at!(@project.id, stale_at)
      engine = build_engine
      engine.project_projection(@user, @project)
      after = stored_computed_at(@project.id)
      assert_equal 1, rows_for(@project.id),
                   'refresh OVERWRITES the same key -> still exactly one row'
      assert_operator after.to_f, :>, stale_at.to_f + 60,
                      'a row OLDER than the cap must be refreshed (computed_at bumped to ~clock.now)'
      assert_in_delta @now.to_f, after.to_f, 5.0,
                      'the refreshed computed_at must be ~ clock.now (the age-check clock)'
    end
  end

  # ─────────────── (c) snapshot_max_age_minutes = 0 disables refresh ─────────────

  def test_zero_max_age_disables_refresh
    with_settings_max_age(0) do
      warm_once!
      # A very stale row; with the cap disabled it must NOT be refreshed.
      stale_at = @now - (10_000 * 60)
      force_computed_at!(@project.id, stale_at)
      engine = build_engine
      engine.project_projection(@user, @project)
      after = stored_computed_at(@project.id)
      assert_in_delta stale_at.to_f, after.to_f, 1.0,
                      'snapshot_max_age_minutes = 0 DISABLES the age-refresh (stale row untouched)'
    end
  end

  # ─────────────── (f) boundary: age exactly == cap refreshes (inclusive) ─────────────

  def test_boundary_age_equal_to_cap_refreshes
    with_settings_max_age(60) do
      warm_once!
      # Exactly 60 minutes old; the check is inclusive (>=) -> refresh.
      boundary_at = @now - (60 * 60)
      force_computed_at!(@project.id, boundary_at)
      engine = build_engine
      engine.project_projection(@user, @project)
      after = stored_computed_at(@project.id)
      assert_operator after.to_f, :>, boundary_at.to_f + 60,
                      'age EXACTLY == cap must refresh (inclusive at the boundary)'
      assert_in_delta @now.to_f, after.to_f, 5.0,
                      'the boundary refresh must bump computed_at to ~ clock.now'
    end
  end

  # ─────────────── (e) portfolio: a MIX {fresh, stale, missing} ─────────────

  def test_portfolio_handles_fresh_stale_and_missing_mix
    with_settings_max_age(60) do
      # A second and third project so the portfolio holds a mix.
      p_fresh = @project
      p_stale = create_project!(name: 'Stale', identifier: 'stale-proj')
      add_member!(project: p_stale, principal: @user, role: @role)
      create_issue!(project: p_stale, author: @user, status: open_status,
                    created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 5, 10, 0))
      p_missing = create_project!(name: 'Missing', identifier: 'missing-proj')
      add_member!(project: p_missing, principal: @user, role: @role)
      create_issue!(project: p_missing, author: @user, status: open_status,
                    created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 5, 10, 0))

      # Warm p_fresh + p_stale (NOT p_missing) via one portfolio pass.
      engine = build_engine
      engine.portfolio_projections(@user)
      # All three warmed on the first pass -> reset to the desired mix:
      #   fresh row (10 min old), stale row (120 min old), missing (delete its row).
      force_computed_at!(p_fresh.id, @now - (10 * 60))
      force_computed_at!(p_stale.id, @now - (120 * 60))
      conn.execute("DELETE FROM pulse_snapshots WHERE project_id = #{p_missing.id.to_i}")
      assert_equal 0, rows_for(p_missing.id), 'precondition: missing project has no row'

      fresh_before = stored_computed_at(p_fresh.id)
      stale_before = stored_computed_at(p_stale.id)

      engine = build_engine
      engine.portfolio_projections(@user)

      # fresh: untouched; stale: refreshed (bumped); missing: warmed (a row now exists).
      assert_in_delta fresh_before.to_f, stored_computed_at(p_fresh.id).to_f, 1.0,
                      'portfolio: the FRESH project is served as-is (computed_at unchanged)'
      assert_operator stored_computed_at(p_stale.id).to_f, :>, stale_before.to_f + 60,
                      'portfolio: the STALE project is refreshed (computed_at bumped)'
      assert_equal 1, rows_for(p_missing.id),
                   'portfolio: the MISSING project is warmed (one row now stored)'
    end
  end

  private

  # Persist a snapshot_max_age_minutes value for the duration of the block, restoring
  # the prior plugin settings afterwards.
  def with_settings_max_age(minutes)
    saved = Setting.plugin_redmine_pulse
    base = saved.is_a?(Hash) ? saved : {}
    Setting.plugin_redmine_pulse = base.merge('snapshot_max_age_minutes' => minutes.to_s)
    @settings = Pulse::Adapters::RedmineSettingsProvider.new
    yield
  ensure
    Setting.plugin_redmine_pulse = saved
  end
end
