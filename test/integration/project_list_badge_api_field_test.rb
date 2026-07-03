# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'
require 'json-schema'
require 'yaml'

# project-list-badge contract — PLB-15-API-FIELD (FR-PLB-15 / D-PLB-C01 + D-PLB-C01a).
# The additive, localized `main_concern` field on BOTH portfolio.json (project_health) and
# project.json (top level), produced by a SINGLE shared adapter module reused by
# HtmlPresenter AND JsonSerializer (DG-PLB-02). Schemas updated additively (main_concern in
# properties AND required, additionalProperties:false preserved); seeds carry main_concern.
#
# This file asserts the SCHEMA/value half (Ruby-testable). The DOM render half
# (PLB-08-15-MAINCONCERN-RENDER) is AIEYES_LIVE, verified later.
#
# Authoritative label mapping (DG-PLB-02, en.yml-confirmed):
#   staleness->"Stale", momentum->"Losing momentum", progress->"Behind schedule",
#   risk_load->"At risk", blocked_load->"Blocked", nil->null.
#
# Postgres-gated (FC-CA-38). RED until A9 adds the field + shared module + schema/seed
# updates. Until then: schema validation rejects the field (required key absent) and the
# shared module constant is undefined.
class ProjectListBadgeApiFieldTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  SPEC = File.expand_path('../../../docs/specs/redmine-pulse/contracts', File.expand_path(__FILE__))
  PORTFOLIO_SCHEMA = File.join(SPEC, 'schemas/portfolio.json')
  PROJECT_SCHEMA   = File.join(SPEC, 'schemas/project.json')

  # The cockpit's authoritative localized labels (the badge MUST equal these).
  # momentum-broaden adds the on_track -> "On track" mapping (D2).
  EXPECTED_LABELS = {
    'staleness' => 'Stale',
    'momentum' => 'Losing momentum',
    'progress' => 'Behind schedule',
    'risk_load' => 'At risk',
    'blocked_load' => 'Blocked',
    'on_track' => 'On track'
  }.freeze

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'McAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'mcuser')
    @project = create_project!(name: 'Mc', identifier: 'mc-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def get_portfolio(user: @user)
    with_settings rest_api_enabled: '1' do
      get '/pulse/portfolio.json', headers: api_key_header(user)
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

  # ── (1) the SHARED label module is the single source, reused by both presenters ──

  def test_shared_main_concern_label_module_exists_and_is_authoritative
    # The mapping is EXTRACTED into ONE adapter module under lib/pulse/adapters/ (stays out
    # of the domain — it uses Rails I18n). ABSENT until A9 -> NameError -> RED.
    assert defined?(Pulse::Adapters::MainConcernLabels),
           'FR-PLB-15: a SHARED Pulse::Adapters::MainConcernLabels module MUST exist (DRY single source)'

    EXPECTED_LABELS.each do |signal, label|
      assert_equal label, Pulse::Adapters::MainConcernLabels.label(signal),
                   "shared module MUST map #{signal} -> #{label.inspect} (DG-PLB-02)"
    end
    assert_nil Pulse::Adapters::MainConcernLabels.label(nil),
               'shared module MUST map nil (no-data) -> nil (mirrors dominant_signal)'
  end

  def test_html_presenter_and_json_serializer_use_one_shared_label_source
    # Both presenters MUST produce IDENTICAL labels for the same signal (no duplicated
    # table). We compare the cockpit's main_concern_label against the shared module for
    # every signal — they MUST agree (proving HtmlPresenter delegates to the shared source).
    EXPECTED_LABELS.each_key do |signal|
      cockpit = Pulse::Adapters::HtmlPresenter.main_concern_label(signal.to_sym)
      shared  = Pulse::Adapters::MainConcernLabels.label(signal)
      assert_equal shared, cockpit,
                   "HtmlPresenter and the shared module MUST agree for #{signal} (single source, FR-PLB-15)"
    end
  end

  # ── (2) seeds validate against the updated schemas WITH main_concern ─────────

  def test_portfolio_seed_carries_and_validates_main_concern
    seed = YAML.load_file(File.join(SPEC, 'seeds/portfolio.yaml'))
    seed['projects'].each do |row|
      assert row.key?('main_concern'),
             "FR-PLB-15: every portfolio seed project_health row MUST carry main_concern (got #{row['identifier']})"
    end
    assert_schema(PORTFOLIO_SCHEMA, seed)
  end

  def test_project_seed_carries_and_validates_main_concern
    seed = YAML.load_file(File.join(SPEC, 'seeds/project.yaml'))
    assert seed.key?('main_concern'),
           'FR-PLB-15 (D-PLB-C01a): the project seed top level MUST carry main_concern'
    assert_schema(PROJECT_SCHEMA, seed)
  end

  # ── (3) the schemas REQUIRE main_concern (nullable) — additive contract ──────

  def test_portfolio_schema_requires_nullable_main_concern_on_project_health
    schema = JSON.parse(File.read(PORTFOLIO_SCHEMA))
    ph = schema.dig('$defs', 'project_health')
    refute_nil ph, 'portfolio schema must define project_health'
    assert_includes ph['required'], 'main_concern',
                    'FR-PLB-15: portfolio project_health MUST require main_concern'
    type = ph.dig('properties', 'main_concern', 'type')
    assert_equal %w[string null].sort, Array(type).sort,
                 'main_concern MUST be ["string","null"] (mirrors dominant_signal nullability)'
    assert_equal false, ph['additionalProperties'],
                 'additionalProperties:false MUST be preserved (additive, not loosened)'
  end

  def test_project_schema_requires_nullable_main_concern_top_level
    schema = JSON.parse(File.read(PROJECT_SCHEMA))
    assert_includes schema['required'], 'main_concern',
                    'FR-PLB-15 (D-PLB-C01a): project.json MUST require top-level main_concern'
    type = schema.dig('properties', 'main_concern', 'type')
    assert_equal %w[string null].sort, Array(type).sort,
                 'project.json main_concern MUST be ["string","null"]'
    assert_equal false, schema['additionalProperties'],
                 'additionalProperties:false MUST be preserved'
  end

  # ── (4) LIVE payloads carry main_concern == the shared/cockpit label ─────────

  def test_live_portfolio_main_concern_equals_shared_label
    get_portfolio
    assert_response :success
    j = JSON.parse(response.body)
    assert_schema(PORTFOLIO_SCHEMA, j) # validates WITH the additive required field
    row = j['projects'].find { |p| p['identifier'] == 'mc-proj' }
    refute_nil row, 'the viewer\'s project must appear'
    assert row.key?('main_concern'), 'live portfolio row MUST carry main_concern'
    expected = Pulse::Adapters::MainConcernLabels.label(row['dominant_signal'])
    assert_equal expected, row['main_concern'],
                 'live main_concern MUST equal the shared-module label for its dominant_signal'
  end

  def test_live_project_main_concern_equals_shared_label
    get_project
    assert_response :success
    j = JSON.parse(response.body)
    assert_schema(PROJECT_SCHEMA, j)
    assert j.key?('main_concern'), 'live project.json MUST carry top-level main_concern'
    expected = Pulse::Adapters::MainConcernLabels.label(j['dominant_signal'])
    assert_equal expected, j['main_concern'],
                 'live project main_concern MUST equal the shared-module label'
  end

  # ── momentum-broaden D2: the dominant_signal enum includes on_track; an on-track
  #    project's main_concern == "On track" ──────────────────────────────────────

  def test_shared_module_maps_on_track_to_localized_label
    assert_equal 'On track', Pulse::Adapters::MainConcernLabels.label(:on_track),
                 'momentum-broaden D2: MainConcernLabels.label(:on_track) -> localized "On track"'
    assert_equal 'On track', Pulse::Adapters::MainConcernLabels.label('on_track'),
                 'string form maps identically'
  end

  def test_portfolio_schema_dominant_signal_enum_includes_on_track
    schema = JSON.parse(File.read(PORTFOLIO_SCHEMA))
    enum = schema.dig('$defs', 'project_health', 'properties', 'dominant_signal', 'enum')
    assert_includes enum, 'on_track',
                    'momentum-broaden §9: portfolio dominant_signal enum MUST include on_track'
  end

  def test_project_schema_dominant_signal_enum_includes_on_track
    schema = JSON.parse(File.read(PROJECT_SCHEMA))
    enum = schema.dig('properties', 'dominant_signal', 'enum')
    assert_includes enum, 'on_track',
                    'momentum-broaden §9: project.json dominant_signal enum MUST include on_track'
  end

  # An "on track" project (worst active signal n >= 0.5) serializes dominant_signal
  # "on_track" and main_concern "On track" (D2).
  #
  # The request path uses the real SystemClock (Time.zone.today), so the activity window is
  # [today-30, today). We seed RELATIVE to Time.now so the scenario stays in-window over
  # time (no clock injection on the HTTP path). To make every active signal >= 0.5:
  #   - momentum: 4 issues CREATED before the window (so issue_created is filtered out =>
  #     opened 0) and CLOSED via a REAL journaled status transition INSIDE the window. Each
  #     in-window close journal contributes BOTH an :issue_closed (closed +1) AND an
  #     :issue_commented (the journal, comments +1) activity event => activity 8
  #     (base 8/16 = 0.5), direction (4-0)/4 = +1 => n = clamp(0.5 + 0.15) = 0.65 (>= 0.5).
  #   - staleness: updated_on stamped recent (close at) => fresh, n well above 0.5.
  #   - progress + risk_load: INACTIVE under default settings (no effort_field, no
  #     risk_trackers) => not in the active set.
  #   - blocked_load: no blockers => n 1.0.
  # => worst active signal (momentum, 0.65) >= 0.5 => dominant_signal :on_track.
  def test_on_track_project_main_concern_is_on_track_label
    fresh = create_project!(name: 'OnTrack', identifier: 'mc-ontrack')
    add_member!(project: fresh, principal: @user, role: @role)
    created_at = (Time.now.utc - 40 * 86_400)   # before the 30-day window => opened 0
    closed_at  = (Time.now.utc - 10 * 86_400)   # inside the window => closed + commented
    4.times do |k|
      i = create_issue!(project: fresh, author: @user, status: open_status,
                        created_on: created_at, updated_on: created_at)
      add_close_journal!(issue: i, user: @user, from_status: open_status,
                         to_status: closed_status, at: closed_at + k * 3600)
      stamp!(i, updated_on: closed_at + k * 3600) # fresh staleness
    end
    get_project('mc-ontrack')
    assert_response :success
    j = JSON.parse(response.body)
    assert_schema(PROJECT_SCHEMA, j)
    assert_equal 'on_track', j['dominant_signal'],
                 'D2: a project whose worst active signal n >= 0.5 is on_track ' \
                 "(got #{j['dominant_signal'].inspect}, main_concern=#{j['main_concern'].inspect})"
    assert_equal 'On track', j['main_concern'],
                 'D2: an on_track project main_concern == localized "On track"'
  end

  # ── no-data path: main_concern is JSON null (mirrors dominant_signal) ────────

  def test_no_data_project_main_concern_is_null
    nodata = create_project!(name: 'McNoData', identifier: 'mc-nodata')
    add_member!(project: nodata, principal: @user, role: @role)
    get_project('mc-nodata')
    assert_response :success, 'a 0-issue (no-data) project must serialize'
    j = JSON.parse(response.body)
    assert_nil j['dominant_signal'], 'no-data: dominant_signal is null'
    assert j.key?('main_concern'), 'no-data project.json MUST still carry the main_concern key'
    assert_nil j['main_concern'],
               'FR-PLB-15: main_concern is JSON null on the no-data path (mirrors dominant_signal)'
    assert_schema(PROJECT_SCHEMA, j)
  end

  def test_no_data_project_in_portfolio_main_concern_is_null
    nodata = create_project!(name: 'McNoDataPf', identifier: 'mc-nodata-pf')
    add_member!(project: nodata, principal: @user, role: @role)
    get_portfolio
    assert_response :success
    j = JSON.parse(response.body)
    row = j['projects'].find { |p| p['identifier'] == 'mc-nodata-pf' }
    refute_nil row, 'the no-data project must appear in the portfolio'
    assert_nil row['dominant_signal']
    # The KEY must be present (additive required field) AND its value JSON null — asserting
    # only `assert_nil` would pass vacuously while the field is still absent (false green).
    assert row.key?('main_concern'),
           'FR-PLB-15: portfolio no-data row MUST carry the main_concern key (additive required field)'
    assert_nil row['main_concern'],
               'FR-PLB-15: portfolio no-data row main_concern is JSON null'
    assert_schema(PORTFOLIO_SCHEMA, j)
  end
end
