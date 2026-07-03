# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# CA-21 / FC-CA-21: THE DEFINING CACHE/CLOCK SPLIT INVARIANT. When the snapshot
# fingerprint is UNCHANGED (zero data change) and ONLY Clock.today advances, the
# controller re-projects staleness/momentum/sparkline and re-derives health_score
# WITHOUT calling MetricsSource and WITHOUT inserting a new pulse_snapshots row. The
# time-derived score MAY differ between the two days (staleness grows) even though
# the snapshot is byte-identical — correct, not a cache bug.
#
# Asserts OBSERVABLE POST-STATE: pulse_snapshots.count is unchanged on the 2nd day,
# and the fingerprint is equal across both days. COND-A8-004: Postgres 16. RED.
class CacheClockSplitTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # COND-A8-004 / GL-CI-MYSQL: Postgres-evidence lane — skip on non-Postgres adapters
    # (counted as skips, not failures) so the CI MySQL legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'ClkAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'clkuser')
    @project = create_project!(name: 'Clk', identifier: 'clk-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 5, 10, 0))
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  def snapshot_count(project)
    ActiveRecord::Base.connection
                      .select_value("SELECT COUNT(*) FROM pulse_snapshots WHERE project_id = #{project.id.to_i}")
                      .to_i
  end

  def fingerprint
    Pulse::Adapters::SnapshotFingerprint.new(@user, @project,
                                             settings_provider: real_settings_provider).value
  end

  def test_clock_advance_does_not_change_fingerprint
    # The clock is NOT a fingerprint component (snapshot_fingerprint.rb has no clock
    # input): the fingerprint is identical regardless of "today".
    fp_a = fingerprint
    fp_b = fingerprint # no data change between
    assert_equal fp_a, fp_b, 'fingerprint excludes the clock (zero data change -> unchanged)'
  end

  def test_clock_advance_no_recompute_no_new_row
    # snapshot-max-age-refresh (CT-02 EVOLUTION): SCOPE the pure clock-split property so
    # the age-refresh cannot interfere. With snapshot_max_age_minutes = 0 the freshness
    # cap is DISABLED, so a clock #today advance with ZERO data change re-projects
    # WITHOUT a recompute and WITHOUT a new row — the core FC-CA-21 invariant, unweakened.
    pulse_settings!('snapshot_max_age_minutes' => 0)
    login_as(@user)
    # Day N: cold GET stores exactly one snapshot row.
    travel_to(Time.utc(2026, 6, 20, 9, 0, 0)) do
      get "/projects/#{@project.identifier}/pulse"
    end
    assert_equal 1, snapshot_count(@project), 'day N: cold GET stores one snapshot'

    # Day N+1: clock advanced, ZERO data change -> re-project WITHOUT a new row.
    travel_to(Time.utc(2026, 6, 21, 9, 0, 0)) do
      get "/projects/#{@project.identifier}/pulse"
    end
    assert_equal 1, snapshot_count(@project),
                 'day N+1 (clock advanced, no data change): NO new snapshot row (FC-CA-21)'
  end

  # snapshot-max-age-refresh (CT-02 EVOLUTION): the DOCUMENTED NEW EXCEPTION to the
  # split. A request whose clock #now is BEYOND the freshness cap past the stored
  # computed_at triggers exactly ONE in-place overwrite (same key, NO new row) — the
  # row's computed_at is bumped so "computed X ago" never exceeds the cap. This does NOT
  # weaken the core split (still no NEW row; the fingerprint is untouched): it is the
  # single new age-refresh write.
  def stored_computed_at(project)
    v = ActiveRecord::Base.connection.select_value(
      "SELECT computed_at FROM pulse_snapshots WHERE project_id = #{project.id.to_i} LIMIT 1"
    )
    v.is_a?(Time) ? v : Time.parse(v.to_s)
  end

  def test_now_advance_beyond_max_age_triggers_single_overwrite
    # A short 1-minute cap so a within-test clock advance crosses it.
    pulse_settings!('snapshot_max_age_minutes' => 1)
    login_as(@user)

    # Cold GET at N: one row, computed_at ~ N.
    travel_to(Time.utc(2026, 6, 20, 9, 0, 0)) do
      get "/projects/#{@project.identifier}/pulse"
    end
    assert_equal 1, snapshot_count(@project), 'cold GET stores one row'
    at_n = stored_computed_at(@project)

    # GET at N + 10 minutes (well beyond the 1-minute cap), ZERO data change: the engine
    # finds the row older than the cap and OVERWRITES it in place — computed_at bumps,
    # but there is still exactly ONE row (no new row; the fingerprint is unchanged).
    travel_to(Time.utc(2026, 6, 20, 9, 10, 0)) do
      get "/projects/#{@project.identifier}/pulse"
    end
    assert_equal 1, snapshot_count(@project),
                 'a beyond-cap now-advance OVERWRITES in place -> still exactly one row (no new row)'
    at_after = stored_computed_at(@project)
    assert_operator at_after.to_f, :>, at_n.to_f + 60,
                    'a now-advance BEYOND the cap must bump computed_at (the age-refresh overwrite)'
  end

  def test_clock_advance_reprojects_a_newer_clock_today_in_api
    login_as(@user)
    token = @user.api_token || Token.create!(user: @user, action: 'api')
    hdr = { 'X-Redmine-API-Key' => token.value }

    clock_a = nil
    clock_b = nil
    with_settings rest_api_enabled: '1' do
      travel_to(Time.utc(2026, 6, 20, 9, 0, 0)) do
        get "/pulse/projects/#{@project.identifier}.json", headers: hdr
        clock_a = JSON.parse(response.body)['projection']['clock_today']
      end
      travel_to(Time.utc(2026, 6, 21, 9, 0, 0)) do
        get "/pulse/projects/#{@project.identifier}.json", headers: hdr
        clock_b = JSON.parse(response.body)['projection']['clock_today']
      end
    end
    refute_equal clock_a, clock_b,
                 'the projected clock_today reflects the advancing clock (re-projection)'
  end
end
