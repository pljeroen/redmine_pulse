# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'
require 'json-schema'
require 'yaml'

# CA-18/19 + FC-CA-18a/18b/19/32 + CA-15/16/17 + COND-A8-001: JSON SCHEMA conformance
# of the LIVE portfolio + project payloads AND the seed examples against the frozen
# schemas, PLUS the non-schema (functional) facts schema validation cannot catch:
#   * source/provenance distinction (snapshot_computed_at vs projected_at);
#   * exact projection values equal the active ScoringConfig;
#   * domain non-mutation (lib/pulse/domain git-diff-unchanged by this contract);
#   * the EXACT English visibility_note literal (D-CA-OQ01).
#
# Postgres-gated (FC-CA-38). RED until A9.
class ApiSchemaTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  SPEC = File.expand_path('../../../docs/specs/redmine-pulse/contracts', File.expand_path(__FILE__))
  PORTFOLIO_SCHEMA = File.join(SPEC, 'schemas/portfolio.json')
  PROJECT_SCHEMA   = File.join(SPEC, 'schemas/project.json')
  VISIBILITY_LITERAL = 'Health computed from issues visible to you.'

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
    @role = create_role!(name: 'SchAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'schuser')
    @project = create_project!(name: 'Sch', identifier: 'sch-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def get_portfolio(params: {}, user: @user)
    with_settings rest_api_enabled: '1' do
      get '/pulse/portfolio.json', params: params, headers: api_key_header(user)
    end
  end

  def get_project(identifier = @project.identifier)
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{identifier}.json", headers: api_key_header(@user)
    end
  end

  def assert_schema(schema_path, payload)
    errs = JSON::Validator.fully_validate(schema_path, payload, strict: false)
    assert_empty errs, "schema validation failed:\n#{errs.join("\n")}"
  end

  # ─────────────────── seed examples validate (AC-API-SCHEMA) ────────────────

  def test_portfolio_seed_validates
    seed = YAML.load_file(File.join(SPEC, 'seeds/portfolio.yaml'))
    assert_schema(PORTFOLIO_SCHEMA, seed)
  end

  def test_project_seed_validates
    seed = YAML.load_file(File.join(SPEC, 'seeds/project.yaml'))
    assert_schema(PROJECT_SCHEMA, seed)
  end

  # ─────────────────── live responses validate (cold + warm) ────────────────

  def test_live_portfolio_validates_cold_and_warm
    get_portfolio
    assert_response :success
    assert_schema(PORTFOLIO_SCHEMA, JSON.parse(response.body)) # cold (miss)
    get_portfolio
    assert_response :success
    assert_schema(PORTFOLIO_SCHEMA, JSON.parse(response.body)) # warm (hit)
  end

  def test_live_project_validates
    get_project
    assert_response :success
    assert_schema(PROJECT_SCHEMA, JSON.parse(response.body))
  end

  def test_live_project_with_version_and_inactive_signal_validates
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    get_project
    assert_response :success
    assert_schema(PROJECT_SCHEMA, JSON.parse(response.body))
  end

  def test_empty_portfolio_validates
    outsider = create_user!(login: 'schempty')
    get_portfolio(user: outsider)
    assert_response :success
    j = JSON.parse(response.body)
    assert_equal [], j['projects']
    assert_schema(PORTFOLIO_SCHEMA, j)
  end

  # ─── R-A no-data downstream (THAW-RB-001): a 0-issue project's payload validates ──
  # against the schema with NULL health_score / dominant_signal / lens values. RED until
  # the schema makes lens_keys.{health,at_risk,stale,blocked} nullable (A9-R-A gap, thaw-
  # scoped here): the current schema types them as plain "number", so a no-data payload
  # (all lens values nil) fails validation.

  def test_no_data_project_validates_with_null_health_and_lens_keys
    nodata = create_project!(name: 'SchNoData', identifier: 'sch-nodata')
    add_member!(project: nodata, principal: @user, role: @role)
    get_project('sch-nodata')
    assert_response :success, 'a 0-issue (no-data) project must serialize, not crash'
    j = JSON.parse(response.body)
    # R-A no-data shape: health_score nil, rag 'no_data', dominant_signal nil, lens values nil.
    assert_nil j['health_score'], 'no-data project: health_score is null (R-A)'
    assert_equal 'no_data', j['rag'], 'no-data project: rag is no_data (R-A)'
    assert_nil j['dominant_signal'], 'no-data project: dominant_signal is null (R-A)'
    %w[health at_risk stale done blocked].each do |k|
      assert_nil j['lens_keys'][k], "no-data project: lens_keys.#{k} is null (R-A)"
    end
    # The payload MUST validate against the (now-nullable) schema. RED until lens_keys.*
    # is made nullable in project.json.
    assert_schema(PROJECT_SCHEMA, j)
  end

  def test_no_data_project_in_portfolio_validates
    nodata = create_project!(name: 'SchNoDataPf', identifier: 'sch-nodata-pf')
    add_member!(project: nodata, principal: @user, role: @role)
    get_portfolio
    assert_response :success
    j = JSON.parse(response.body)
    row = j['projects'].find { |p| p['identifier'] == 'sch-nodata-pf' }
    refute_nil row, 'the no-data project must appear in the portfolio'
    assert_nil row['health_score'], 'portfolio no-data row: health_score is null (R-A)'
    assert_equal 'no_data', row['rag']
    # The whole portfolio payload (incl. the null-lens no-data row) must validate. RED
    # until portfolio.json lens_keys.* is made nullable.
    assert_schema(PORTFOLIO_SCHEMA, j)
  end

  # ─── finding 3 (JSON side) — DELIBERATELY NOT a blanket "no long float" test ──
  # The task asked to assert JSON numerics are rounded. A BLANKET /\d+\.\d{6,}/ refutation
  # over the whole JSON body would DIRECTLY CONTRADICT the frozen FC-CA-23 explainability
  # invariant (test/functional/explainability_passthrough_test.rb), which REQUIRES
  # `contribution` and `effective_weight` to be emitted VERBATIM from the domain (those raw
  # values ARE long floats, e.g. 0.3846153846153846). A test forcing both GREEN is
  # unsatisfiable, so it is not authored (Symmetric Refusal / Falsifiability — surfaced to
  # A9 in the RUN_LEDGER). The JSON float concern is bounded to the HTML PRESENTATION
  # (pulse_controller_test#test_show_panel_has_no_long_float_in_value_cells), where rounding
  # for DISPLAY does not violate the API's explainability passthrough.

  # ─── COND-A8-001: NON-schema facts (functional, not schema-only) ───────────

  def test_visibility_note_exact_english_literal
    get_project
    assert_response :success
    assert_equal VISIBILITY_LITERAL, JSON.parse(response.body)['visibility_note'],
                 'D-CA-OQ01: API visibility_note is the EXACT fixed English literal'
  end

  def test_two_timestamps_have_distinct_sources
    # snapshot_computed_at derives from stored pulse_snapshots.computed_at; projected_at
    # from the request clock. They are sourced from DIFFERENT instants (not aliased).
    get_project
    assert_response :success
    j = JSON.parse(response.body)
    stored = ActiveRecord::Base.connection.select_value(
      "SELECT computed_at FROM pulse_snapshots WHERE project_id = #{@project.id.to_i} LIMIT 1"
    )
    refute_nil stored, 'a snapshot row was stored'
    assert_equal 'computed', j['snapshot_computed_at']['provenance']
    assert_equal 'computed', j['projected_at']['provenance']
    # The snapshot_computed_at value must trace to the stored computed_at, not Clock.now.
    snap_at = Time.parse(j['snapshot_computed_at']['at']).to_i
    assert_in_delta Time.parse(stored.to_s).to_i, snap_at, 2,
                    'snapshot_computed_at must derive from the stored computed_at'
  end

  def test_projection_block_equals_active_scoring_config
    get_project
    assert_response :success
    proj = JSON.parse(response.body)['projection']
    cfg = real_settings_provider.scoring_config
    assert_equal cfg.activity_window_days, proj['activity_window_days']
    assert_equal cfg.h_stale, proj['horizons']['staleness']
    assert_equal cfg.h_risk, proj['horizons']['risk_load']
    assert_equal cfg.h_blocked, proj['horizons']['blocked_load']
    assert_match(/^\d{4}-\d{2}-\d{2}$/, proj['clock_today'], 'clock_today date-only')
  end

  def test_domain_layer_unchanged_by_this_contract
    # FC-CA-25: lib/pulse/domain/** is git-diff-unchanged by the controllers-api contract.
    root = File.expand_path('../../..', File.expand_path(__FILE__))
    diff = `cd #{root} && git diff --name-only HEAD -- lib/pulse/domain 2>/dev/null`.strip
    assert_equal '', diff,
                 "no lib/pulse/domain file may be modified by this contract (got: #{diff.inspect})"
  end
end
