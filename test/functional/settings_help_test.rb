# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# settings-help behavior: every scoring setting on the plugin settings page
# carries an inline, i18n-keyed help paragraph (<em class="info">) stating what it
# influences + its shipped default, grouped under a per-fieldset intro.
#
# These tests render the REAL admin settings partial through the harness (the
# settings render is the historically-fragile surface — the settings-500 crash),
# and assert the help is actually present in the rendered output, not just that the
# keys exist. Requires the partial + en.yml help keys.
#
# Postgres-gated (matches the existing settings_render_test evidence lane).
class SettingsHelpTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :users, :roles, :trackers, :enumerations, :issue_statuses

  # The 17 per-setting help keys + 4 group-intro keys from HELP_SPEC.
  # 14 original + 3 promoted momentum settings: the momentum activity-half, momentum
  # direction-bias and on-track threshold each carry inline help.
  FIELD_HELP_KEYS = %i[
    label_pulse_help_effort_field label_pulse_help_risk_trackers label_pulse_help_blocked_status
    label_pulse_help_weight_staleness label_pulse_help_weight_progress label_pulse_help_weight_momentum
    label_pulse_help_weight_risk_load label_pulse_help_weight_blocked_load
    label_pulse_help_rag_green_min label_pulse_help_rag_amber_min
    label_pulse_help_h_stale label_pulse_help_h_risk label_pulse_help_h_blocked
    label_pulse_help_activity_window_days
    label_pulse_help_momentum_activity_half label_pulse_help_momentum_direction_bias
    label_pulse_help_on_track_threshold
    label_pulse_help_snapshot_max_age_minutes
  ].freeze

  GROUP_INTRO_KEYS = %i[
    label_pulse_help_group_enrichment label_pulse_help_group_weights
    label_pulse_help_group_thresholds label_pulse_help_group_windows
  ].freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @admin = create_user!(login: 'pulsehelp', admin: true)
    @tracker = (trackers(:trackers_001) rescue Tracker.first)
    @tracker ||= Tracker.generate!(default_status: open_status)
  end

  def login_admin
    post '/login', params: { username: @admin.login, password: 'password' }
  rescue StandardError
    User.current = @admin
  end

  # ── 1. every help + group-intro i18n key exists and is non-empty ────────────
  def test_every_help_key_exists_and_is_nonempty
    (FIELD_HELP_KEYS + GROUP_INTRO_KEYS).each do |key|
      val = I18n.t(key, default: '')
      assert val.to_s.strip.length.positive?,
             "missing/empty i18n help key #{key} (settings-help)"
    end
  end

  # ── 2. the settings page renders one inline help element per setting ────────
  def test_settings_page_renders_inline_help_per_field
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    # >= 14 field helps; group intros add more. Inline <em class="info"> (Redmine hint).
    assert_select 'em.info', { minimum: FIELD_HELP_KEYS.size },
                  "expected an inline 'em.info' help paragraph for each of the " \
                  "#{FIELD_HELP_KEYS.size} settings (settings-help)"
  end

  # ── 3. the help text states the shipped defaults ────────────────────────────
  def test_help_shows_shipped_defaults
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    body = response.body
    [
      'Default: 180 days', # h_stale
      'Default: 50',       # h_risk
      'Default: 20',       # h_blocked
      'Default: 30 days',  # activity_window_days
      'Default: 67',       # rag_green_min
      'Default: 34',       # rag_amber_min
      'Default: 0.25',     # staleness/progress weights
      'Default: 0.20',     # momentum weight
      'Default: 0.15',     # risk_load/blocked_load weights
      'Default: blank',    # effort_field / blocked_status
      'Default: none selected', # risk_trackers
      'Default: 8',        # momentum_activity_half (settings-promote-momentum)
      'Default: 0.15',     # momentum_direction_bias (settings-promote-momentum)
      'Default: 0.5'       # on_track_threshold (settings-promote-momentum)
    ].each do |phrase|
      assert_includes body, phrase,
                      "settings help must surface the shipped default phrase #{phrase.inspect}"
    end
  end

  # ── 4. each fieldset carries its group intro ────────────────────────────────
  def test_group_intros_render
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    body = response.body
    [
      'standard Redmine data',     # enrichment intro (scores on standard Redmine data alone)
      'must add up to 1.0',        # weights intro
      'health chips',              # thresholds intro (Red, Amber and Green health chips)
      'quiet, risky or blocked'    # windows intro (how quickly a project is flagged)
    ].each do |phrase|
      assert_includes body, phrase,
                      "settings page must render the group intro phrase #{phrase.inspect}"
    end
  end

  # ── snapshot-max-age-refresh: the freshness-cap help renders, states its shipped
  # default (60), and its i18n key resolves. Requires the
  # label_pulse_help_snapshot_max_age_minutes key + the partial help paragraph.

  def test_snapshot_max_age_minutes_help_key_resolves
    val = I18n.t(:label_pulse_help_snapshot_max_age_minutes, default: '')
    assert val.to_s.strip.length.positive?,
           'missing/empty i18n help key label_pulse_help_snapshot_max_age_minutes'
  end

  def test_snapshot_max_age_minutes_help_states_default_60
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_includes response.body, 'Default: 60',
                    'the snapshot_max_age_minutes help must state its shipped default (Default: 60)'
  end

  # ── 5. regression guard: the settings page still renders 200 (no 500) ───────
  def test_settings_page_still_renders_200
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success,
                    'adding inline help must not regress the settings render'
  end
end
