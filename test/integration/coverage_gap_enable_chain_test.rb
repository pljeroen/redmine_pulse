# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# A10-C2-005 — the END-TO-END coverage_gap ENABLE-CHAIN regression guard.
#
# The C2 unit tests proved each stage against a HANDCRAFTED 6-key config / 6-key settings
# hash; NONE of them exercised the REAL chain the shipped settings form drives:
#
#   default persisted settings (coverage_gap OFF, 5-key)
#     -> SettingsSanitizer.sanitize (as the admin POST writer does)
#     -> Setting.plugin_redmine_pulse=            (the real persistence)
#     -> RedmineSettingsProvider#scoring_config   (the real ScoringConfig build)
#     -> Pulse::Domain::Scoring.score             (the real signal dispatch + no-data gate)
#     -> HtmlPresenter.signal_rows / JsonSerializer.signal_set   (the real surfaces)
#
# This is the test that would have caught the CRITICAL A10-C2-001 (enable_coverage_gap
# persisted while ScoringConfig still enabled only the 5 C1 signals): it starts from the
# DEFAULT 5-key settings, enables coverage_gap the way the form POSTs (enable checkbox +
# the 5 weight inputs the form ships), and asserts the sixth signal is enabled, scored,
# NOT suppressed by no_data, and surfaced in BOTH presenters — then asserts the DEFAULT-OFF
# path is byte-identical (no coverage keys anywhere).
#
# HARNESS lane: RedmineSettingsProvider reads Setting.plugin_redmine_pulse and the presenters
# resolve plugin constants via Zeitwerk, so it must load under the Redmine test harness. It
# is NOT run in the pure `ruby -Itest -Ilib` lane (that lane cannot resolve Setting / the
# adapter constants); the orchestrator runs it via scripts/test-redmine/run-tests.sh.
#
# It MUST fail against the pre-A9 code (the enable flag would not enable the signal; the
# no-data short-circuit would suppress it; the label would be unused) and PASS against the
# current (A9-fixed) code. Discharges FR-C2-05/06/07, FC-C2-09/10/14/15.
class CoverageGapEnableChainTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  PLUGIN_KEY = 'plugin_redmine_pulse'
  CG = :coverage_gap
  # The dedicated localized "Planning coverage" display label (A10-C2-004).
  PLANNING_COVERAGE_LABEL = I18n.t(:label_pulse_planning_coverage)

  # The DEFAULT persisted plugin settings — coverage_gap OFF, the 5-key baseline the admin
  # form ships on a fresh instance (weights {} => the engine's 5 default weights at read time).
  DEFAULT_SETTINGS = {
    'rag_green_min' => 67, 'rag_amber_min' => 34,
    'h_stale' => 180, 'h_risk' => 50, 'h_blocked' => 20,
    'activity_window_days' => 30, 'weights' => {},
    'effort_field' => '', 'risk_trackers' => [], 'blocked_status' => ''
  }.freeze

  # The 5 weight inputs the settings form actually renders WHILE coverage_gap is OFF (the
  # 6th input appears only once enabled). Enabling POSTs the checkbox PLUS these 5 — the
  # exact shape that surfaced A10-C2-001 (a naive 6-key rejection left the config at 5).
  FORM_FIVE_WEIGHTS = {
    'staleness' => '0.25', 'progress' => '0.25', 'momentum' => '0.2',
    'risk_load' => '0.15', 'blocked_load' => '0.15'
  }.freeze

  def setup
    @saved = Setting.send(PLUGIN_KEY)
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
  end

  def teardown
    Setting.send("#{PLUGIN_KEY}=", @saved)
  end

  # ── the REAL settings writer: sanitize the admin POST, then persist. ────────────────
  # Mirrors init.rb's admin-POST path (SettingsSanitizer.sanitize -> Setting.plugin_...=).
  def persist_via_settings_writer(incoming)
    previous = current_settings
    sanitized, = Pulse::Adapters::SettingsSanitizer.sanitize(incoming, previous)
    Setting.send("#{PLUGIN_KEY}=", sanitized)
    sanitized
  end

  def current_settings
    s = Setting.send(PLUGIN_KEY)
    s.is_a?(Hash) ? s : {}
  end

  def scoring_config
    Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
  end

  # A coverage-bearing ProjectMetrics that is ALSO a C1 no-data candidate: effort_total 0,
  # empty event_series, no blockers, no risk issues — but open_issue_count > 0 with partial
  # coverage. Under C1 this would be no_data; with coverage_gap ENABLED it must be ACTIVE.
  def coverage_bearing_metrics(open_issue_count:, covered_sum:)
    Pulse::Domain::ProjectMetrics.new(
      project_id: 42,
      reference_date: Date.new(2026, 6, 1),
      effort_open: 0.0, effort_total: 0.0,
      risk_raw: 0.0, blocked_count: 0,
      risk_mapped: false, effort_mapped: false,
      event_series: [], version_due_dates: [],
      open_issue_count: open_issue_count, covered_sum: covered_sum
    )
  end

  # Minimal projection view-model the presenters read: .health / .project / .risk_tracker_ids.
  FakeProject = Struct.new(:id, :identifier, :name)
  FakeProjection = Struct.new(:health, :project, :risk_tracker_ids)

  def projection_for(health)
    FakeProjection.new(health, FakeProject.new(42, 'chain-demo', 'Chain Demo'), [])
  end

  def score(metrics, config)
    Pulse::Domain::Scoring.score(metrics, @clock, config)
  end

  def coverage_gap_row(rows)
    rows.find { |r| r.key.to_s == 'coverage_gap' }
  end

  # ────────────────────────────────────────────────────────────────────────────────────
  # 1..5 — ENABLE chain: default OFF -> POST enable -> provider -> scoring -> presentation.
  # ────────────────────────────────────────────────────────────────────────────────────
  def test_enable_chain_from_default_settings_reaches_all_surfaces
    # (1) Start from the DEFAULT persisted settings — coverage_gap OFF.
    Setting.send("#{PLUGIN_KEY}=", DEFAULT_SETTINGS.dup)
    refute scoring_config.enabled_signals.include?(CG),
           'precondition: the default (5-key) config does NOT enable coverage_gap'

    # (2) Enable coverage_gap the way the settings form POSTs: the enable checkbox PLUS the
    # 5 weight inputs the form ships while off. Write it through the REAL sanitize+persist
    # path (NOT a handcrafted 6-key hash) — this is the exact shape A10-C2-001 surfaced.
    persisted = persist_via_settings_writer(
      DEFAULT_SETTINGS.merge('enable_coverage_gap' => '1', 'weights' => FORM_FIVE_WEIGHTS)
    )
    assert_equal '1', persisted['enable_coverage_gap'],
                 'the enable flag is persisted as a scalar settings key'
    assert_includes persisted['weights'].keys.map(&:to_s), 'coverage_gap',
                    'the sanitizer SYNTHESIZED the 6-key weight map from the 5-input enable POST'

    # (3) Build the ScoringConfig via the REAL provider and assert the enabled set now
    # INCLUDES coverage_gap, and the 6 weights renormalized to sum 1.0.
    cfg = scoring_config
    assert_includes cfg.enabled_signals, CG,
                    'A10-C2-001 REGRESSION GUARD: enabling coverage_gap must make the provider ' \
                    'ScoringConfig enable the sixth signal (not silently stay at the 5 C1 signals)'
    assert_equal 6, cfg.enabled_signals.size, 'exactly the 6 signals are enabled'
    assert_in_delta 1.0, cfg.weights.values.sum, 1e-9, 'the 6 weights renormalize to Σ==1.0'

    # (4) Score a coverage-bearing project that would be no_data under C1 (no effort/activity/
    # risk/blockers) but has open issues with PARTIAL planning coverage. With coverage_gap
    # enabled it must NOT be suppressed by the no-data short-circuit (A10-C2-002).
    #   open_issue_count 4, covered_sum 1.0 => mean_cov 0.25 => gap raw_value 0.75, n 0.25.
    metrics = coverage_bearing_metrics(open_issue_count: 4, covered_sum: 1.0)
    assert Pulse::Domain::Scoring.coverage_gap_active?(metrics, cfg),
           'coverage_gap is active for the enabled config with open issues'
    refute Pulse::Domain::Scoring.no_data?(metrics, cfg),
           'A10-C2-002 REGRESSION GUARD: an enabled coverage-bearing project must NOT be ' \
           'suppressed to no_data before Signals.coverage_gap is dispatched'
    health = score(metrics, cfg)
    refute_equal Pulse::Domain::Scoring::NO_DATA_RAG, health.rag,
                 'the coverage-bearing project scores a real health band, not no_data'
    cg_result = health.breakdown.find { |s| s.key == CG }
    refute_nil cg_result, 'the breakdown carries a coverage_gap row'
    assert cg_result.active, 'the coverage_gap signal is ACTIVE in the HealthResult'
    assert_in_delta 0.75, cg_result.raw_value, 1e-12,
                    'raw_value is the mean planning-GAP fraction 1 - covered_sum/open_issue_count'

    # (5) Presentation surfaces both include coverage_gap.
    rows = Pulse::Adapters::HtmlPresenter.signal_rows(projection_for(health))
    row = coverage_gap_row(rows)
    refute_nil row, 'HtmlPresenter renders a coverage_gap row when it is in the breakdown'
    assert_equal PLANNING_COVERAGE_LABEL, row.label,
                 'A10-C2-004: the coverage_gap row uses the localized planning-coverage label'
    # The DISPLAYED value is the PLANNING-COVERAGE percentage 100*(1-raw_value) == 25, NOT the
    # raw gap 0.75 (mean_cov 0.25 => 25% planned).
    assert_in_delta 25.0, row.raw_value.to_f, 1e-9,
                    'HtmlPresenter renders planning coverage 100*(1-raw_value)=25%'

    set = Pulse::Adapters::JsonSerializer.signal_set(projection_for(health), with_drill: false)
    assert_includes set.keys, 'coverage_gap', 'JsonSerializer includes a coverage_gap entry'
    assert_equal true, set['coverage_gap']['active'], 'the JSON coverage_gap entry is active'
    # JSON emits the VERBATIM gap fraction (FC-CA-23 passthrough), NOT the planning-coverage %.
    assert_in_delta 0.75, set['coverage_gap']['raw_value'].to_f, 1e-12,
                    'JSON raw_value is the verbatim gap fraction (FC-CA-23 passthrough)'
  end

  # ── the empty-weights enable POST (fresh instance renders the 5 inputs blank => {}) also
  # yields the 6-signal enabled set — the provider synthesizes from the default weights when
  # the persisted weight hash drifts/absent. Pins BOTH form-POST shapes reach the sixth signal.
  def test_enable_chain_with_blank_weights_still_enables_coverage_gap
    Setting.send("#{PLUGIN_KEY}=", DEFAULT_SETTINGS.dup)
    persist_via_settings_writer(DEFAULT_SETTINGS.merge('enable_coverage_gap' => '1'))
    cfg = scoring_config
    assert_includes cfg.enabled_signals, CG,
                    'a blank-weights enable POST must still yield the 6-signal enabled set'
    assert_in_delta 1.0, cfg.weights.values.sum, 1e-9
  end

  # ────────────────────────────────────────────────────────────────────────────────────
  # 6 — DEFAULT-OFF (coverage_gap disabled): the whole chain is byte-identical to pre-C2:
  # no coverage key in the config/weights, coverage_gap ABSENT from HealthResult + both
  # presenters, even when the metrics carry non-zero coverage inputs (present-but-UNREAD).
  # ────────────────────────────────────────────────────────────────────────────────────
  def test_default_off_chain_surfaces_no_coverage_gap_anywhere
    Setting.send("#{PLUGIN_KEY}=", DEFAULT_SETTINGS.dup)
    cfg = scoring_config
    refute cfg.enabled_signals.include?(CG),
           'default-OFF: coverage_gap is not in the enabled set'
    refute cfg.weights.key?(CG), 'default-OFF: no coverage_gap weight key'
    assert_equal 5, cfg.enabled_signals.size, 'default-OFF: exactly the 5 C1 signals'

    # Metrics carry non-zero coverage inputs, but with coverage_gap OFF they must be UNREAD:
    # this project (no effort/activity/risk/blockers) is genuinely no_data on the default path.
    metrics = coverage_bearing_metrics(open_issue_count: 7, covered_sum: 3.5)
    assert Pulse::Domain::Scoring.no_data?(metrics, cfg),
           'default-OFF: coverage inputs are UNREAD, so this project is no_data (C1 behavior)'
    health = score(metrics, cfg)
    assert_nil health.breakdown.find { |s| s.key == CG },
               'default-OFF: coverage_gap is ABSENT from the HealthResult breakdown'
    assert_equal 5, health.breakdown.size, 'default-OFF: exactly the 5 C1 rows'

    rows = Pulse::Adapters::HtmlPresenter.signal_rows(projection_for(health))
    assert_nil coverage_gap_row(rows), 'default-OFF: HtmlPresenter renders no coverage_gap row'
    set = Pulse::Adapters::JsonSerializer.signal_set(projection_for(health), with_drill: false)
    refute_includes set.keys, 'coverage_gap', 'default-OFF: JsonSerializer emits no coverage_gap key'
  end

  # An ACTIVE scoring path (not no_data) is ALSO byte-identical off: a project WITH effort
  # scores its 5 C1 signals and never grows a coverage_gap row while disabled.
  def test_default_off_active_project_has_no_coverage_gap_row
    Setting.send("#{PLUGIN_KEY}=", DEFAULT_SETTINGS.dup)
    cfg = scoring_config
    metrics = Pulse::Domain::ProjectMetrics.new(
      project_id: 43, reference_date: Date.new(2026, 6, 15),
      effort_open: 4.0, effort_total: 10.0,
      risk_raw: 0.0, blocked_count: 1,
      risk_mapped: false, effort_mapped: true,
      event_series: [{ date: Date.new(2026, 6, 18), type: :issue_closed }],
      version_due_dates: [], open_issue_count: 5, covered_sum: 2.5
    )
    health = score(metrics, cfg)
    refute_equal Pulse::Domain::Scoring::NO_DATA_RAG, health.rag,
                 'precondition: this project scores an active health band'
    assert_nil health.breakdown.find { |s| s.key == CG },
               'default-OFF active project: coverage_gap is absent from the breakdown'
    set = Pulse::Adapters::JsonSerializer.signal_set(projection_for(health), with_drill: false)
    refute_includes set.keys, 'coverage_gap',
                    'default-OFF active project: no coverage_gap key in the JSON payload'
  end
end
