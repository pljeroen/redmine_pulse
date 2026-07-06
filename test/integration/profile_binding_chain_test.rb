# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# IT-C4-07 (END-TO-END CHAIN, the C2 lesson) — the whole-chain regression guard, modeled on
# coverage_gap_enable_chain_test.rb. The C2 unit tests each proved one stage against a
# HANDCRAFTED hash; NONE exercised the REAL chain the shipped settings form drives. This
# test starts from DEFAULT settings and walks the REAL wiring:
#
#   default persisted settings (no admin profiles)
#     -> admin publishes a profile + binds it to a ROLE (SettingsSanitizer.sanitize as the
#        admin POST writer does) -> Setting.plugin_redmine_pulse=            (real persistence)
#     -> RedmineSettingsProvider#pulse_profiles                             (real read)
#     -> RedmineProfileProvider#resolve(viewer, project, nil)              (real precedence)
#     -> SnapshotFingerprint(..., active_profile_id: active.id)            (real cache key)
#     -> ActiveRecordSnapshotStore                                        (real cache row)
#     -> Pulse::Domain::Scoring.score(metrics, clock, active.config)      (real scoring)
#     -> HtmlPresenter.panel_view(...).active_profile_name                (real surface)
#
# It MUST fail against pre-A9 HEAD (no RedmineProfileProvider; SnapshotFingerprint takes no
# active_profile_id:; the Engine takes no profile_provider:; the presenter has no
# active_profile_name) and PASS against the A9-wired code. Discharges FR-C4-02/03/04/05/06/08,
# FC-C4-05, FC-C4-06, FC-C4-08, FC-C4-09, FC-C4-10SC, FC-C4-14, FC-C4-17.
#
# HARNESS lane (RED-by-construction): reads Setting.plugin_redmine_pulse + resolves plugin
# constants via Zeitwerk, so it loads under the Redmine harness — NOT the pure lane. The
# orchestrator runs it via scripts/test-redmine/run-tests.sh. Postgres-gated evidence lane.
class ProfileBindingChainTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  PLUGIN_KEY = 'plugin_redmine_pulse'

  # A reweighted profile config that scores DISTINCTLY from the default (staleness-heavy).
  PROFILE_WEIGHTS = {
    'staleness' => '0.60', 'progress' => '0.10', 'momentum' => '0.10',
    'risk_load' => '0.10', 'blocked_load' => '0.10'
  }.freeze

  DEFAULT_SETTINGS = {
    'rag_green_min' => 67, 'rag_amber_min' => 34,
    'h_stale' => 180, 'h_risk' => 50, 'h_blocked' => 20,
    'activity_window_days' => 30, 'weights' => {},
    'effort_field' => '', 'risk_trackers' => [], 'blocked_status' => ''
  }.freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @saved = Setting.send(PLUGIN_KEY)
    Setting.send("#{PLUGIN_KEY}=", DEFAULT_SETTINGS.dup)
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @project = create_project!(name: 'ChainBind', identifier: 'chain-bind')
    @role = create_role!(name: 'ChainRole', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse view_changesets])
    @user = create_user!(login: 'chain_user')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def teardown
    Setting.send("#{PLUGIN_KEY}=", @saved)
  end

  # The REAL admin-POST writer: sanitize the incoming settings, then persist.
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

  def settings_provider
    Pulse::Adapters::RedmineSettingsProvider.new
  end

  def profile_provider
    Pulse::Adapters::RedmineProfileProvider.new(settings_provider: settings_provider)
  end

  def ms
    Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: settings_provider, clock: @clock
    )
  end

  def engine
    Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: ms, store: Pulse::Adapters::ActiveRecordSnapshotStore.new,
      settings_provider: settings_provider, clock: @clock,
      profile_provider: profile_provider
    )
  end

  # ── the full chain: admin binds a profile to the viewer's role -> cockpit reflects it ──
  def test_admin_binds_profile_to_role_and_viewer_cockpit_reflects_it
    # (1) Precondition: the DEFAULT settings publish no admin profiles — only the synthetic
    # default resolves for the viewer.
    assert_equal 'default', profile_provider.resolve(@user, @project, nil).id,
                 'precondition: with no admin profiles, the viewer resolves to the default'

    # (2) Admin publishes a "risk-heavy" profile AND binds it to the viewer's role, through
    # the REAL sanitize+persist path (NOT a handcrafted settings hash).
    persist_via_settings_writer(
      DEFAULT_SETTINGS.merge(
        'pulse_profiles' => {
          'profiles' => { 'risk-heavy' => { 'name' => 'Risk Heavy', 'weights' => PROFILE_WEIGHTS } },
          'role_bindings' => { @role.id.to_s => 'risk-heavy' }
        }
      )
    )

    # (3) The REAL provider reads pulse_profiles and resolves the BOUND profile for the viewer
    # (role-binding beats default; no explicit selection).
    active = profile_provider.resolve(@user, @project, nil)
    assert_equal 'risk-heavy', active.id,
                 'the role-bound profile must resolve for a viewer holding the bound role (FC-C4-06)'
    assert_equal 'Risk Heavy', active.name, 'the resolved profile carries the published name'
    assert_includes profile_provider.profiles.map(&:id), 'risk-heavy',
                    'the published set includes the admin-defined profile + the synthetic default'
    assert_includes profile_provider.profiles.map(&:id), 'default'

    # (4) The snapshot is fingerprinted + cached under the RESOLVED profile id — distinct from
    # the default fingerprint (component folded), and a distinct cache row.
    fp_active = Pulse::Adapters::SnapshotFingerprint.new(
      @user, @project, settings_provider: settings_provider, active_profile_id: active.id
    ).value
    fp_default = Pulse::Adapters::SnapshotFingerprint.new(
      @user, @project, settings_provider: settings_provider, active_profile_id: 'default'
    ).value
    refute_equal fp_default, fp_active,
                 'the non-default resolved profile folds a distinct fingerprint component (FC-C4-09)'

    proj = engine.project_projection(@user, @project, nil) # resolves the bound profile internally
    row = Pulse::Adapters::ActiveRecordSnapshotStore::PulseSnapshot
          .where(project_id: @project.id, snapshot_fingerprint: fp_active).first
    refute_nil row,
               'the snapshot is cached under the resolved (bound) profile\'s fingerprint (FC-C4-08/09)'

    # (5) Scoring reflects the profile config (staleness-heavy => distinct from the default score).
    default_config = settings_provider.scoring_config
    default_h = Pulse::Domain::Scoring.score(proj.metrics, @clock, default_config)
    refute_equal default_h.health_score, proj.health.health_score,
                 'the projection scored under the bound profile differs from the default-config ' \
                 'score (scoring reflects active_profile.config, FC-C4-10SC)'

    # (6) The presenter surfaces the active profile NAME (FC-C4-17).
    view = Pulse::Adapters::HtmlPresenter.panel_view(proj, now: @clock.now)
    assert_equal 'Risk Heavy', view.active_profile_name,
                 'the cockpit shows "scored under: Risk Heavy" (FC-C4-17)'
  end

  # ── an EXPLICIT transient selection (?profile_id) overrides the role binding through the
  # full engine chain (FR-C4-03 level-1 transient path). ─────────────────────────────────
  def test_transient_selection_overrides_role_binding_through_engine
    persist_via_settings_writer(
      DEFAULT_SETTINGS.merge(
        'pulse_profiles' => {
          'profiles' => {
            'risk-heavy' => { 'name' => 'Risk Heavy', 'weights' => PROFILE_WEIGHTS },
            'stale-light' => { 'name' => 'Stale Light',
                               'weights' => { 'staleness' => '0.10', 'progress' => '0.30',
                                              'momentum' => '0.30', 'risk_load' => '0.15',
                                              'blocked_load' => '0.15' } }
          },
          'role_bindings' => { @role.id.to_s => 'risk-heavy' }
        }
      )
    )
    # The viewer is bound to risk-heavy, but explicitly selects stale-light via the transient
    # ?profile_id param — the selection must win (FC-C4-06 level 1).
    active = profile_provider.resolve(@user, @project, 'stale-light')
    assert_equal 'stale-light', active.id,
                 'an explicit transient selection overrides the role binding (FC-C4-06 level 1)'

    proj_selected = engine.project_projection(@user, @project, 'stale-light')
    view = Pulse::Adapters::HtmlPresenter.panel_view(proj_selected, now: @clock.now)
    assert_equal 'Stale Light', view.active_profile_name,
                 'the cockpit reflects the explicitly-selected profile name through the engine'
  end
end
