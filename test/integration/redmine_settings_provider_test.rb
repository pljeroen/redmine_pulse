# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# RedmineSettingsProvider: builds ScoringConfig from plugin Settings (defaults when
# absent) + a deterministic settings_version_hash. Also validates the effort field
# is numeric-format at read time.
#
# Canonical API:
#   sp = Pulse::Adapters::RedmineSettingsProvider.new
#   sp.scoring_config        -> Pulse::Domain::ScoringConfig
#   sp.settings_version_hash -> String (deterministic; changes when settings change)
#   sp.effort_mapped?        -> Boolean (true iff configured AND numeric-format)
class RedmineSettingsProviderTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :enumerations, :trackers

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @plugin_key = 'plugin_redmine_pulse'
    @saved = Setting.send(@plugin_key)
  end

  def teardown
    Setting.send("#{@plugin_key}=", @saved)
  end

  def set_settings(hash)
    Setting.send("#{@plugin_key}=", hash)
  end

  # --- defaults when unconfigured ------------------------------

  def test_scoring_config_uses_defaults_when_unconfigured
    set_settings({})
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_instance_of Pulse::Domain::ScoringConfig, cfg
    assert_equal 67, cfg.rag_green_min
    assert_equal 34, cfg.rag_amber_min
    assert_equal 30, cfg.activity_window_days
    assert_in_delta 1.0, cfg.weights.values.sum, 1e-9
  end

  def test_scoring_config_reflects_configured_values
    set_settings({ 'rag_green_min' => 80, 'rag_amber_min' => 40,
                   'activity_window_days' => 45 })
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_equal 80, cfg.rag_green_min
    assert_equal 40, cfg.rag_amber_min
    assert_equal 45, cfg.activity_window_days
  end

  # --- configured horizons override engine defaults -
  # The ScoringConfig defaults are h_stale=180, h_risk=50, h_blocked=20.
  # The provider must BUILD ScoringConfig from the configured horizons,
  # not silently fall through to the engine defaults. Set NON-default values and
  # assert they survive into the ScoringConfig.
  def test_scoring_config_uses_configured_horizons
    set_settings({ 'h_stale' => 90, 'h_risk' => 25, 'h_blocked' => 10 })
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_equal 90, cfg.h_stale,
                 'configured h_stale must override the scoring-engine default 180'
    assert_equal 25, cfg.h_risk,
                 'configured h_risk must override the scoring-engine default 50'
    assert_equal 10, cfg.h_blocked,
                 'configured h_blocked must override the scoring-engine default 20'
  end

  def test_scoring_config_horizons_default_when_absent
    set_settings({})
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_equal 180, cfg.h_stale, 'absent h_stale -> default 180'
    assert_equal 50, cfg.h_risk, 'absent h_risk -> default 50'
    assert_equal 20, cfg.h_blocked, 'absent h_blocked -> default 20'
  end

  # --- promoted momentum settings: the 3 promoted FLOAT fields ----------
  # The provider parses momentum_activity_half / momentum_direction_bias /
  # on_track_threshold via a float_setting helper (blank/absent -> default; else
  # Float(raw) with a rescue -> default) into ScoringConfig.

  def test_scoring_config_momentum_onctrack_default_when_unconfigured
    set_settings({})
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_in_delta 8.0, cfg.momentum_activity_half, 1e-9, 'absent momentum_activity_half -> default 8.0'
    assert_in_delta 0.15, cfg.momentum_direction_bias, 1e-9, 'absent momentum_direction_bias -> default 0.15'
    assert_in_delta 0.5, cfg.on_track_threshold, 1e-9, 'absent on_track_threshold -> default 0.5'
  end

  def test_scoring_config_reflects_configured_momentum_onctrack_values
    set_settings({ 'momentum_activity_half' => '4.0',
                   'momentum_direction_bias' => '0.3',
                   'on_track_threshold' => '0.7' })
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_in_delta 4.0, cfg.momentum_activity_half, 1e-9,
                    'configured momentum_activity_half (string "4.0") must Float-parse into the config'
    assert_in_delta 0.3, cfg.momentum_direction_bias, 1e-9
    assert_in_delta 0.7, cfg.on_track_threshold, 1e-9
  end

  def test_scoring_config_momentum_onctrack_blank_falls_back_to_default
    # blank strings -> defaults (mirror int_setting blank handling).
    set_settings({ 'momentum_activity_half' => '',
                   'momentum_direction_bias' => '',
                   'on_track_threshold' => '' })
    cfg = Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    assert_in_delta 8.0, cfg.momentum_activity_half, 1e-9, 'blank momentum_activity_half -> default 8.0'
    assert_in_delta 0.15, cfg.momentum_direction_bias, 1e-9, 'blank momentum_direction_bias -> default 0.15'
    assert_in_delta 0.5, cfg.on_track_threshold, 1e-9, 'blank on_track_threshold -> default 0.5'
  end

  # --- snapshot-max-age-refresh: the snapshot_max_age_minutes ----
  # OPERATIONAL cache knob. It lives on the settings provider (NOT on the pure-domain
  # ScoringConfig, which stays scoring-only). Read via the existing int_setting pattern
  # (blank/absent -> shipped default 60; else raw.to_i). Requires the reader.

  def test_snapshot_max_age_minutes_default_when_unconfigured
    set_settings({})
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal 60, sp.snapshot_max_age_minutes,
                 'absent snapshot_max_age_minutes -> shipped default 60'
  end

  def test_snapshot_max_age_minutes_reflects_configured_value
    set_settings({ 'snapshot_max_age_minutes' => '15' })
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal 15, sp.snapshot_max_age_minutes,
                 'configured snapshot_max_age_minutes (string "15") must int-parse'
  end

  def test_snapshot_max_age_minutes_zero_is_configured_disabled
    set_settings({ 'snapshot_max_age_minutes' => '0' })
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal 0, sp.snapshot_max_age_minutes,
                 '0 is a VALID configured value (disabled), NOT the default'
  end

  def test_snapshot_max_age_minutes_blank_falls_back_to_default
    set_settings({ 'snapshot_max_age_minutes' => '' })
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal 60, sp.snapshot_max_age_minutes,
                 'blank snapshot_max_age_minutes -> shipped default 60'
  end

  # --- settings_version_hash determinism + change --------------

  def test_settings_version_hash_is_deterministic
    set_settings({ 'rag_green_min' => 70 })
    a = Pulse::Adapters::RedmineSettingsProvider.new.settings_version_hash
    b = Pulse::Adapters::RedmineSettingsProvider.new.settings_version_hash
    assert_kind_of String, a
    assert_equal a, b
  end

  def test_settings_version_hash_changes_on_settings_change
    set_settings({ 'rag_green_min' => 70 })
    before = Pulse::Adapters::RedmineSettingsProvider.new.settings_version_hash
    set_settings({ 'rag_green_min' => 71 })
    after = Pulse::Adapters::RedmineSettingsProvider.new.settings_version_hash
    refute_equal before, after, 'any settings change yields a different hash'
  end

  # --- effort field numeric-format validation at read time ------

  def test_effort_mapped_true_for_numeric_field
    field = numeric_custom_field!(name: 'NumEffort', format: 'float')
    set_settings({ 'effort_field' => field.id.to_s })
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal true, sp.effort_mapped?, 'numeric-format effort field -> mapped'
  end

  def test_effort_mapped_false_for_non_numeric_field
    field = IssueCustomField.create!(name: 'TextEffort', field_format: 'text', is_for_all: true)
    set_settings({ 'effort_field' => field.id.to_s })
    sp = Pulse::Adapters::RedmineSettingsProvider.new
    assert_equal false, sp.effort_mapped?,
                 'text-format field rejected at read time -> effort_mapped false'
  end

  def test_effort_mapped_false_when_unconfigured
    set_settings({ 'effort_field' => '' })
    assert_equal false, Pulse::Adapters::RedmineSettingsProvider.new.effort_mapped?
  end
end
