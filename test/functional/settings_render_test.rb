# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# GET-rendering the plugin settings page must return HTTP 200 with a POPULATED
# risk-tracker multi-select — NOT a 500 / NameError.
#
# The defect: app/views/settings/_pulse_settings.html.erb calls `pulse_tracker_options`,
# a PulseSettingsHelper method that init.rb `include`s into SettingsController. But when
# Redmine renders the plugin settings partial it executes in the VIEW context, where a
# bare controller `include` does NOT expose the method to the template — so the ERB
# raises NameError (undefined local variable or method `pulse_tracker_options`) and the
# admin page 500s. NO existing test rendered the settings partial, so this was missed.
#
# This is THE test that would have caught the 500. It drives the real admin settings
# render through the harness and asserts 200 + the multi-select is present + populated.
# (The helper must be exposed to the VIEW, not just `include`d into the controller.)
#
# Runs on PostgreSQL (the production engine).
class SettingsRenderTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :users, :roles, :trackers, :enumerations, :issue_statuses

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # Runs on PostgreSQL (the production engine) — skip on non-Postgres adapters
    # (counted as skips, not failures) so the MySQL CI legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @admin = create_user!(login: 'pulserender', admin: true)
    # At least one tracker must exist so the multi-select is genuinely populated.
    @tracker = trackers(:trackers_001) rescue Tracker.first
    @tracker ||= Tracker.generate!(default_status: open_status)
  end

  def login_admin
    post '/login', params: { username: @admin.login, password: 'password' }
  rescue StandardError
    User.current = @admin
  end

  # ─────────── finding 1: the settings page renders 200, not a 500 ────────────

  def test_plugin_settings_page_renders_200_not_500
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success,
                    'the Pulse plugin settings page must render HTTP 200 — the present ' \
                    'pulse_tracker_options helper is out of VIEW scope and raises NameError -> 500'
  end

  def test_plugin_settings_page_does_not_raise_name_error
    login_admin
    get '/settings/plugin/redmine_pulse'
    # A 500 here renders the exception; assert the tell-tale NameError text is ABSENT.
    refute_match(/NameError|undefined (?:local variable or )?method .?pulse_tracker_options/,
                 response.body,
                 'the settings partial must not raise NameError on pulse_tracker_options ' \
                 '(helper must be in VIEW scope)')
  end

  def test_plugin_settings_page_renders_populated_risk_tracker_multiselect
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    # The risk_trackers control is a native multi-select targeting settings[risk_trackers][].
    assert_select 'select[name=?][multiple]', 'settings[risk_trackers][]' do
      # ...and it is POPULATED with the project trackers (at least one <option>), proving
      # pulse_tracker_options actually resolved in view scope.
      assert_select 'option', minimum: 1,
                    text: nil # any option presence; existence is the assertion
    end
  end

  def test_plugin_settings_page_lists_the_existing_tracker_by_name
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_match(/#{Regexp.escape(@tracker.name)}/, response.body,
                 'the populated risk-tracker multi-select must list the existing tracker by name ' \
                 '(proves pulse_tracker_options resolved + rendered)')
  end

  # ── the 3 promoted momentum/on-track inputs render, and the page stays 200 ──
  # The promoted momentum/on-track settings get number inputs in the Windows
  # (momentum_activity_half, momentum_direction_bias) and Thresholds
  # (on_track_threshold) fieldsets.

  def test_plugin_settings_page_renders_momentum_activity_half_input
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select "input[name='settings[momentum_activity_half]']", { minimum: 1 },
                  'the momentum_activity_half number input must render'
  end

  def test_plugin_settings_page_renders_momentum_direction_bias_input
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select "input[name='settings[momentum_direction_bias]']", { minimum: 1 },
                  'the momentum_direction_bias number input must render'
  end

  def test_plugin_settings_page_renders_on_track_threshold_input
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select "input[name='settings[on_track_threshold]']", { minimum: 1 },
                  'the on_track_threshold number input must render'
  end

  def test_plugin_settings_page_with_new_fields_still_renders_200_not_500
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success,
                    'adding the 3 promoted momentum/on-track inputs must not regress the render ' \
                    'to a 500'
  end

  # ── the snapshot_max_age_minutes number input renders in the Windows fieldset, and the
  # page stays 200 (no 500).

  def test_plugin_settings_page_renders_snapshot_max_age_minutes_input
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select "input[name='settings[snapshot_max_age_minutes]']", { minimum: 1 },
                  'the snapshot_max_age_minutes number input must render'
  end

  def test_plugin_settings_page_with_snapshot_field_still_renders_200_not_500
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success,
                    'adding the snapshot_max_age_minutes input must not regress the render to a 500'
  end

  # ── effort-field auto-detect (suggest-only): the settings page surfaces the numeric
  # custom fields whose name looks like effort / story points as a discovery HINT when the
  # effort field is unset. Suggestion only — no auto-apply; blank still means the
  # issue-count Progress mode.

  def blank_effort_field!
    Setting.plugin_redmine_pulse = (Setting.plugin_redmine_pulse || {}).merge('effort_field' => '')
  end

  def test_settings_suggests_matching_numeric_effort_fields_when_blank
    IssueCustomField.generate!(name: 'Story Points', field_format: 'int', is_for_all: true)
    IssueCustomField.generate!(name: 'Effort hours', field_format: 'float', is_for_all: true)
    IssueCustomField.generate!(name: 'Priority score', field_format: 'int', is_for_all: true)
    IssueCustomField.generate!(name: 'Effort notes', field_format: 'text', is_for_all: true)
    blank_effort_field!
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select 'p.pulse-effort-candidates' do
      assert_select 'span.pulse-effort-candidate', text: /Story Points \(id \d+\)/
      assert_select 'span.pulse-effort-candidate', text: /Effort hours \(id \d+\)/
    end
    # A numeric field whose name does NOT match, and a name-matching NON-numeric field,
    # must NOT be offered.
    refute_match(/Priority score/, response.body, 'non-matching numeric field must not be suggested')
    refute_match(/Effort notes/, response.body, 'name-matching non-numeric field must not be suggested')
  end

  def test_settings_omits_effort_suggestions_when_field_is_set
    cf = IssueCustomField.generate!(name: 'Story Points', field_format: 'int', is_for_all: true)
    Setting.plugin_redmine_pulse = (Setting.plugin_redmine_pulse || {}).merge('effort_field' => cf.id.to_s)
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select 'p.pulse-effort-candidates', false,
                  'no suggestion hint once an effort field is explicitly set'
  end

  def test_settings_effort_suggestions_absent_when_no_matching_fields
    IssueCustomField.generate!(name: 'Priority score', field_format: 'int', is_for_all: true)
    blank_effort_field!
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select 'p.pulse-effort-candidates', false,
                  'no hint when no numeric field name looks like effort/story points'
  end

  def test_settings_effort_pattern_is_word_bounded_and_separator_aware
    # Separator variants MATCH; word-boundary false positives do NOT.
    IssueCustomField.generate!(name: 'story_points', field_format: 'int', is_for_all: true)
    IssueCustomField.generate!(name: 'Story-Points', field_format: 'int', is_for_all: true)
    IssueCustomField.generate!(name: 'History Points', field_format: 'int', is_for_all: true)
    IssueCustomField.generate!(name: 'Effortless tracking', field_format: 'int', is_for_all: true)
    blank_effort_field!
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select 'span.pulse-effort-candidate', text: /story_points \(id \d+\)/
    assert_select 'span.pulse-effort-candidate', text: /Story-Points \(id \d+\)/
    refute_match(/History Points/, response.body, 'word-boundary: History Points must not match')
    refute_match(/Effortless tracking/, response.body, 'word-boundary: effortless must not match')
  end
end
