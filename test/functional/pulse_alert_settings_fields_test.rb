# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# C6 remediation (FR-C6-08 auto-subscribe role + FR-C6-06 score_delta N): the ADMIN settings
# fields. The plugin settings page must:
#   (1) render the auto_subscribe_role_id <select> (blank + one option per givable role) and
#       the score_delta threshold number input;
#   (2) POST them through Redmine's SettingsController#plugin path and PERSIST the two
#       Setting.plugin_redmine_pulse keys (SettingsSanitizer validates them);
#   (3) drive real behavior: a persisted auto_subscribe_role_id makes that role's members
#       candidates in subscribers_for; a persisted score_delta threshold is read live by the
#       scan.
#
# Postgres-gated (FC-CA-38) for parity with the sibling settings/alert suites.
class PulseAlertSettingsFieldsTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :users, :roles, :trackers, :enumerations, :issue_statuses

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @admin = create_user!(login: 'alertadm', admin: true)
    @role = create_role!(name: 'AlertSubRole', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
  end

  def login_admin
    post '/login', params: { username: @admin.login, password: 'password' }
  rescue StandardError
    User.current = @admin
  end

  def save_settings(settings)
    login_admin
    post '/settings/plugin/redmine_pulse', params: { settings: settings }
  end

  def current_settings
    s = Setting.plugin_redmine_pulse
    s.is_a?(Hash) ? s : {}
  end

  # ─────────────── (1) both fields render on the settings page ────────────────

  def test_settings_page_renders_auto_subscribe_role_select
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select 'select[name=?]', 'settings[pulse_alert_auto_subscribe_role_id]' do
      # A blank "disabled" option plus the givable role must both be offered.
      assert_select 'option[value=""]', { minimum: 1 },
                    'the role select must offer a blank (auto-subscribe disabled) option'
      assert_select "option[value=?]", @role.id.to_s, { minimum: 1 },
                    'the role select must offer the givable role as an option'
    end
  end

  def test_settings_page_renders_score_delta_threshold_input
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success
    assert_select "input[type=number][name=?]", 'settings[pulse_alert_score_delta_threshold]',
                  { minimum: 1 },
                  'the score-delta threshold number input must render (FR-C6-06)'
  end

  def test_settings_page_with_alert_fields_still_renders_200_not_500
    login_admin
    get '/settings/plugin/redmine_pulse'
    assert_response :success,
                    'adding the two alert settings fields must not regress the render to a 500'
  end

  # ─────────────── (2) POST persists both keys ────────────────────────────────

  def test_post_persists_auto_subscribe_role_id
    save_settings(current_settings.merge('pulse_alert_auto_subscribe_role_id' => @role.id.to_s))
    assert_equal @role.id, current_settings['pulse_alert_auto_subscribe_role_id'],
                 'a valid role id must persist (SettingsSanitizer accepts Integer >= 1)'
  end

  def test_post_persists_score_delta_threshold
    save_settings(current_settings.merge('pulse_alert_score_delta_threshold' => '15'))
    assert_equal 15, current_settings['pulse_alert_score_delta_threshold'],
                 'a valid score-delta threshold N must persist'
  end

  def test_blank_role_select_disables_auto_subscribe
    # First set it, then blank it — blank must persist as nil (disabled), the default OFF state.
    save_settings(current_settings.merge('pulse_alert_auto_subscribe_role_id' => @role.id.to_s))
    assert_equal @role.id, current_settings['pulse_alert_auto_subscribe_role_id']
    save_settings(current_settings.merge('pulse_alert_auto_subscribe_role_id' => ''))
    assert_nil current_settings['pulse_alert_auto_subscribe_role_id'],
               'a blank role select must persist as nil (auto-subscribe disabled)'
  end

  # ─────────────── (3) the persisted fields drive real behavior ───────────────

  def test_persisted_auto_subscribe_role_makes_members_candidates
    project = create_project!(name: 'AlertSetP', identifier: 'alert-set-p',
                              modules: %w[issue_tracking pulse repository])
    member = create_user!(login: 'autosub_u')
    add_member!(project: project, principal: member, role: @role)
    create_issue!(project: project, author: User.where(admin: true).first || User.first,
                  status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))

    # Before persisting the role => not a candidate (auto-subscribe OFF).
    refute_includes Pulse::Adapters::RedmineSubscriptionStore.new
                                                             .subscribers_for(project.id).map(&:login),
                    member.login,
                    'auto-subscribe OFF by default: role members are not candidates'

    # Persist the auto-subscribe role through the settings POST path.
    save_settings(current_settings.merge('pulse_alert_auto_subscribe_role_id' => @role.id.to_s))
    assert_equal @role.id, current_settings['pulse_alert_auto_subscribe_role_id']

    assert_includes Pulse::Adapters::RedmineSubscriptionStore.new
                                                             .subscribers_for(project.id).map(&:login),
                    member.login,
                    'after persisting the auto-subscribe role, a permitted role member is a candidate'
  end

  def test_persisted_score_delta_threshold_is_read_live_by_settings
    save_settings(current_settings.merge('pulse_alert_score_delta_threshold' => '25'))
    # The stored value is what the scan reads live (RedmineSettingsProvider / plugin_settings).
    assert_equal 25, Setting.plugin_redmine_pulse['pulse_alert_score_delta_threshold'],
                 'the persisted score-delta threshold is read live from plugin settings by the scan'
  end
end
