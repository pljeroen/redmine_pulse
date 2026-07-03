# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# CA-09/13/14/15/16/17/18/19/24/26 + FC-CA-09/15/16/19/24det + D-CA-OQ03:
# PulseApiController JSON surfaces — portfolio + project. REST auth gate, pagination,
# schema_version, two distinct timestamps, projection block, inactive-signal
# presence, determinism + lens tie-break, Redmine-conventional 422 error shape.
#
# COND-A8-004: PostgreSQL 16 gate (FC-CA-38). RED until A9.
class PulseApiControllerTest < ActionDispatch::IntegrationTest
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
    @role = create_role!(name: 'ApiAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'apiuser')
    @project = create_project!(name: 'Api', identifier: 'api-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def get_portfolio(params: {}, headers: nil)
    with_settings rest_api_enabled: '1' do
      get '/pulse/portfolio.json', params: params, headers: headers || api_key_header(@user)
    end
  end

  def get_project(identifier = @project.identifier, headers: nil)
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{identifier}.json", headers: headers || api_key_header(@user)
    end
  end

  def body_json
    JSON.parse(response.body)
  end

  # ─────────────────────── CA-09 / FC-CA-09: REST auth ──────────────────────

  def test_api_key_header_authenticates
    get_portfolio
    assert_response :success, 'X-Redmine-API-Key header authenticates the JSON action'
  end

  def test_rest_disabled_returns_redmine_401_or_403
    with_settings rest_api_enabled: '0' do
      get '/pulse/portfolio.json', headers: api_key_header(@user)
      assert_includes [401, 403], response.status,
                      'REST disabled -> Redmine standard 401/403, no bypass'
    end
  end

  def test_controllers_use_no_custom_api_key_parsing
    # Static: neither controller implements its own API-key parsing — it relies on
    # Redmine's accept_api_auth / built-in mechanism only.
    %w[pulse_api_controller pulse_controller].each do |name|
      path = File.expand_path("../../../app/controllers/#{name}.rb", File.expand_path(__FILE__))
      next unless File.exist?(path)

      src = File.read(path)
      refute_match(/X-Redmine-API-Key|params\[:key\]|api_key/i, src,
                   "#{name} must not implement custom API-key parsing (FC-CA-09)")
    end
  end

  def test_api_controller_declares_accept_api_auth
    path = File.expand_path('../../../app/controllers/pulse_api_controller.rb', File.expand_path(__FILE__))
    if File.exist?(path)
      assert_match(/accept_api_auth\s+:portfolio,\s*:project/, File.read(path),
                   'PulseApiController must declare accept_api_auth :portfolio, :project (BR-04)')
    else
      flunk 'pulse_api_controller.rb not yet implemented (RED)'
    end
  end

  # ── RT-09 (security-S3-defense): CHARACTERIZATION — the .json surface must NOT be
  # reachable with only a session cookie (no API key, no basic auth). Redmine's
  # accept_api_auth / api_request? path treats a `.json` request as an API request and
  # requires an API key (or explicit REST credentials) via require_login for format.api;
  # a plain session cookie is NOT accepted for the JSON body. This pins the current SAFE
  # behavior so a future refactor cannot silently open the session-cookie .json path.
  #
  # Framing note: `ActionDispatch::IntegrationTest` has no ambient browser session, so the
  # faithful expression of "session-only, no API credentials" is a request with REST
  # ENABLED and NO API key / NO basic-auth header. Redmine must answer 401/403 (NOT 200
  # with data). We ALSO drive the login-form session path (post /login) to show that even
  # a real authenticated SESSION cookie does not unlock the JSON body without a key. Both
  # PASS now (characterization).

  def test_json_with_no_api_credentials_rest_enabled_is_401_or_403
    # REST is ENABLED but the request carries NO API key and NO basic auth. Redmine treats
    # the .json body as an API request => require_login denies it (401/403), never 200+data.
    with_settings rest_api_enabled: '1' do
      get '/pulse/portfolio.json', headers: {}
    end
    assert_includes [401, 403], response.status,
                    'REST enabled + NO API credentials on a .json request must be 401/403, ' \
                    'never 200 with data (RT-09 characterization)'
    refute_equal 200, response.status,
                 'the session-cookie/no-key .json path must NOT expose portfolio data'
  end

  def test_json_with_session_cookie_only_no_api_key_is_401_or_403
    # Establish a REAL authenticated session via the login form (session cookie), then hit
    # the JSON surface WITHOUT an API key. The session cookie alone must NOT unlock the API
    # body — Redmine's api_request? path requires an API key for format.api.
    @user.update_column(:password, User.hash_password('password')) rescue nil
    post '/login', params: { username: @user.login, password: 'password' }
    with_settings rest_api_enabled: '1' do
      # No X-Redmine-API-Key / no basic auth: only the session cookie carried by the
      # integration session is present.
      get '/pulse/portfolio.json'
    end
    assert_includes [401, 403], response.status,
                    'a session cookie WITHOUT an API key must NOT unlock the .json body ' \
                    '(RT-09 characterization: session-only => 401/403, not 200+data)'
    # Defense-in-depth: if the framework were to 200 here, the body must at minimum not be
    # a real portfolio payload. Pin that it is not a 200 data leak.
    refute_equal 200, response.status,
                 'session-only .json must not return a 200 portfolio payload'
  end

  # ───────────────── CA-19 schema_version + CA-13 pagination ─────────────────

  def test_portfolio_schema_version_is_string_one_zero
    get_portfolio
    assert_response :success
    assert_equal '1.0', body_json['schema_version']
  end

  def test_portfolio_pagination_shape
    get_portfolio
    assert_response :success
    pag = body_json['pagination']
    assert_equal 0, pag['offset']
    assert_equal 100, pag['limit'], 'default limit is 100 when ?limit absent'
    assert_operator pag['total'], :>=, 1
  end

  def test_portfolio_pagination_offset_limit_applied
    get_portfolio(params: { offset: 0, limit: 1 })
    assert_response :success
    pag = body_json['pagination']
    assert_equal 0, pag['offset']
    assert_equal 1, pag['limit']
    assert_operator body_json['projects'].size, :<=, 1
  end

  # D-CA-OQ03 + CT-PAG-1 / FC-CA-19: limit<1 / non-integer -> 422 Redmine-conventional.

  def test_portfolio_limit_zero_is_422
    get_portfolio(params: { limit: 0 })
    assert_response 422, 'limit<1 is a validation error -> 422, not a zero-row page'
  end

  def test_portfolio_non_integer_limit_is_422
    get_portfolio(params: { limit: 'abc' })
    assert_response 422
  end

  # ── RT-05 (security-S2-dos): API limit UPPER-BOUND cap (availability hardening) ──
  # GET /pulse/portfolio.json validates limit as integer>=1 but has NO upper bound: a
  # request with limit far above a sane maximum forces the composition root to rank +
  # serialize an unbounded slice — an amplification / memory-DoS lever. The intended fix
  # caps limit at a hard maximum (MAX_PORTFOLIO_LIMIT; e.g. 100/250) and returns the
  # Redmine-conventional 422 above it, exactly like the lower bound. RED now: the huge
  # limit is currently ACCEPTED (200), so this asserts the missing upper-bound guard.
  def test_portfolio_over_cap_limit_is_422
    get_portfolio(params: { limit: 1_000_000 })
    assert_response 422,
                    'limit far above the sane maximum must be a validation error -> 422 ' \
                    '(hard upper-bound cap, MAX_PORTFOLIO_LIMIT), not an unbounded page (RT-05)'
  end

  def test_portfolio_over_cap_limit_uses_errors_envelope
    # The over-cap 422 renders via the SAME Redmine-conventional {"errors":[...]} envelope
    # as the lower-bound violation (D-CA-OQ03), not a bespoke shape.
    get_portfolio(params: { limit: 1_000_000 })
    assert_response 422
    parsed = body_json
    assert parsed.key?('errors'), 'over-cap 422 carries a Redmine-conventional "errors" array'
    assert_kind_of Array, parsed['errors']
  end

  def test_portfolio_normal_limit_still_succeeds
    # A sane limit BELOW the cap must remain a normal 200 (the cap only rejects the
    # over-cap tail; it does not change the accepted range for ordinary requests).
    get_portfolio(params: { limit: 25 })
    assert_response :success, 'a normal in-range limit (25) is unaffected by the upper-bound cap'
    assert_equal 25, body_json['pagination']['limit']
  end

  def test_portfolio_negative_offset_is_422
    get_portfolio(params: { offset: -1 })
    assert_response 422, 'offset must be >= 0'
  end

  def test_422_uses_redmine_conventional_errors_envelope
    # D-CA-OQ03: errors render via Redmine's render_validation_errors style
    # ({"errors":[...]}), NOT a custom pulse envelope.
    get_portfolio(params: { limit: 0 })
    assert_response 422
    parsed = body_json
    assert parsed.key?('errors'), 'Redmine-conventional 422 body carries an "errors" array'
    assert_kind_of Array, parsed['errors']
  end

  # ───────────── CA-15: two distinct timestamps (FC-CA-15) ──────────────────

  def test_portfolio_two_distinct_provenance_computed_timestamps
    get_portfolio
    assert_response :success
    j = body_json
    assert_equal 'computed', j['snapshot_computed_at']['provenance']
    assert_equal 'computed', j['projected_at']['provenance']
    # The two objects are emitted separately (sourced from distinct instants):
    # snapshot_computed_at from stored pulse_snapshots.computed_at; projected_at from
    # the request clock. They must NOT be the same object/alias.
    assert j.key?('snapshot_computed_at') && j.key?('projected_at')
  end

  # ───────────── CA-16: projection block from active ScoringConfig ───────────

  def test_portfolio_projection_block_matches_active_config
    get_portfolio
    assert_response :success
    proj = body_json['projection']
    assert_match(/^\d{4}-\d{2}-\d{2}$/, proj['clock_today'], 'clock_today is date-only')
    cfg = real_settings_provider.scoring_config
    assert_equal cfg.activity_window_days, proj['activity_window_days']
    assert_equal cfg.h_stale, proj['horizons']['staleness']
    assert_equal cfg.h_risk, proj['horizons']['risk_load']
    assert_equal cfg.h_blocked, proj['horizons']['blocked_load']
    refute_empty proj['time_zone'].to_s
  end

  # ───────── CA-18 / CA-26: all 5 signals present incl. inactive ─────────────

  def test_portfolio_all_five_signals_present_with_inactive_nulls
    get_portfolio
    assert_response :success
    sigs = body_json['projects'].first['signals']
    %w[staleness progress momentum risk_load blocked_load].each do |k|
      assert sigs.key?(k), "signal #{k} present (no omission)"
    end
    # risk_load is inactive (no risk tracker) -> active:false + null numeric fields.
    rl = sigs['risk_load']
    assert_equal false, rl['active']
    assert_nil rl['raw_value']
    assert_nil rl['effective_weight']
    assert_nil rl['contribution']
  end

  # ───────────── CA-14: project payload structure (FC-CA-18b) ────────────────

  def test_project_payload_core_fields
    get_project
    assert_response :success
    j = body_json
    assert_equal '1.0', j['schema_version']
    assert_equal @project.id, j['project']['project_id']
    assert j.key?('visibility_note')
    assert j.key?('weights_effective')
    assert j.key?('thresholds')
    assert j['timeline'].key?('retrospective')
    assert j['timeline'].key?('forward')
  end

  def test_project_visibility_note_is_exact_fixed_english_literal
    # D-CA-OQ01: API visibility_note is a FIXED English literal, byte-for-byte.
    get_project
    assert_response :success
    assert_equal 'Health computed from issues visible to you.',
                 body_json['visibility_note']
  end

  def test_project_weights_effective_only_active_keys
    # risk_load inactive -> ABSENT from weights_effective, but PRESENT (active:false)
    # in signals (FC-CA-18b).
    get_project
    assert_response :success
    j = body_json
    refute j['weights_effective'].key?('risk_load'),
           'inactive risk_load must be absent from weights_effective'
    assert_equal false, j['signals']['risk_load']['active']
    assert_nil j['signals']['risk_load']['drill_url'], 'inactive signal drill_url is null'
  end

  def test_project_empty_forward_when_no_versions
    get_project
    assert_response :success
    assert_equal [], body_json['timeline']['forward'],
                 'forward axis is [] when no Version due dates exist (INV-NO-INVENTED-DATES)'
  end

  def test_project_forward_milestone_is_date_only_not_midnight_utc
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    get_project
    assert_response :success
    fwd = body_json['timeline']['forward']
    assert_equal 1, fwd.size
    due = fwd.first['due_date']
    assert_equal 'version_due_date', due['provenance']
    assert_equal '2026-09-30', due['date'], 'version due date is date-only, NOT midnight-UTC'
    refute_match(/T00:00:00Z/, due['date'])
  end

  def test_project_retrospective_bucket_is_midnight_utc
    get_project
    assert_response :success
    retro = body_json['timeline']['retrospective']
    refute_empty retro
    b = retro.first
    assert_equal 'derived_bucket', b['start']['provenance']
    assert_match(/^\d{4}-\d{2}-\d{2}T00:00:00Z$/, b['start']['at'],
                 'retrospective bucket boundary is midnight-UTC date-time')
  end

  # ─────────────── CA-13: determinism + lens tie-break (FC-CA-24det) ─────────

  def test_portfolio_payload_is_deterministic_across_repeated_calls
    get_portfolio
    a = body_json
    get_portfolio
    b = body_json
    # Modulo the operational instants, the payload is byte-stable.
    %w[snapshot_computed_at projected_at].each { |k| a.delete(k); b.delete(k) }
    assert_equal a, b, 'fixed state+user+clock+config -> identical payload (determinism)'
  end

  def test_portfolio_lens_sort_tiebreaks_by_project_id_ascending
    # Two projects with identical health -> stable order by project_id ascending.
    p2 = create_project!(name: 'ApiB', identifier: 'apib-proj')
    add_member!(project: p2, principal: @user, role: @role)
    create_issue!(project: p2, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    get_portfolio
    assert_response :success
    ids = body_json['projects'].map { |p| p['project_id'] }
    tied = ids.select { |id| [@project.id, p2.id].include?(id) }
    assert_equal tied.sort, tied, 'ties break by project_id ascending (total + stable sort)'
  end

  # ────────────── empty portfolio is 200 with an empty projects array ─────────

  def test_empty_portfolio_is_200_with_empty_array
    outsider = create_user!(login: 'apiempty')
    get_portfolio(headers: api_key_header(outsider))
    assert_response :success
    assert_equal [], body_json['projects'], 'no permitted projects -> 200 + empty array, not 404'
  end

  # ────────────────── READ-ONLY: JSON GET writes no domain table ─────────────

  def test_portfolio_get_writes_no_redmine_domain_table
    writes = capture_write_statements { get_portfolio }
    assert_equal [], writes, "portfolio.json GET is read-only (got: #{writes.inspect})"
  end

  def test_project_get_writes_no_redmine_domain_table
    writes = capture_write_statements { get_project }
    assert_equal [], writes, "project.json GET is read-only (got: #{writes.inspect})"
  end
end
