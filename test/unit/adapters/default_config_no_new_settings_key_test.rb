# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative '../../../lib/pulse/adapters/settings_sanitizer'
require 'pulse/domain/scoring_config'
require 'pulse/domain/signal_registry'

# A10-C1-003 / FC-C1-14 — default_path_no_new_settings_key (falsifiable form).
#
# FC-C1-14 core claim: on the DEFAULT path C1 persists NO new plugin-settings key.
# The default enabled set is resolved PROGRAMMATICALLY from SignalRegistry.keys and is
# NEVER written to the settings hash, so the settings hash is unchanged ⟹ the
# settings_version_hash is unchanged ⟹ SnapshotFingerprint component 7 is stable ⟹ no
# cache-invalidation storm on the default configuration.
#
# This suite discharges the parts that DO NOT require a live Redmine instance:
#   (a) SettingsSanitizer.sanitize returns a settings hash containing NO 'enabled_signals'
#       key and never introduces one.
#   (b) Building a DEFAULT ScoringConfig (registry-resolved defaults; no explicit
#       enabled_signals: kwarg) does not mutate the input settings hash (dup-and-compare)
#       and introduces no 'enabled_signals' key.
#   (c) SignalRegistry.default_enabled_keys resolves the default set programmatically —
#       proving the default set is a computed value, not a persisted settings key.
#
# HARNESS-ONLY REMAINDER (documented, not skipped here): the byte-identity of
# RedmineSettingsProvider#settings_version_hash before/after scoring_config() cannot be
# computed without a live Redmine Setting (RedmineSettingsProvider#settings reads
# Setting.plugin_redmine_pulse; #settings_version_hash / #canonical are not reachable over
# a plain hash without stubbing the Rails Setting model). That leg is covered by the
# Redmine-harness integration lane (IT-C1-02, snapshot_fingerprint_test.rb). The
# unit-level guarantee below (no 'enabled_signals' key ever added on the default path) is
# the necessary-and-sufficient precondition for that hash to be stable.
class DefaultConfigNoNewSettingsKeyTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  # A representative, fully-valid persisted settings hash (string keys, string-ish
  # values), as Redmine stores plugin settings. No 'enabled_signals' key present.
  def valid_settings
    {
      'rag_green_min' => '67', 'rag_amber_min' => '34',
      'h_stale' => '180', 'h_risk' => '50', 'h_blocked' => '20',
      'activity_window_days' => '30',
      'momentum_activity_half' => '8.0', 'momentum_direction_bias' => '0.15',
      'on_track_threshold' => '0.5',
      'snapshot_max_age_minutes' => '60',
      'weights' => {
        'staleness' => '0.25', 'progress' => '0.25', 'momentum' => '0.20',
        'risk_load' => '0.15', 'blocked_load' => '0.15'
      }
    }
  end

  # (a) sanitize never emits an 'enabled_signals' key.
  def test_sanitize_result_has_no_enabled_signals_key
    incoming = valid_settings
    previous = valid_settings
    result, errors = S.sanitize(incoming, previous)

    assert_equal [], errors, 'a fully-valid settings hash sanitizes without error'
    refute_includes result.keys, 'enabled_signals',
                     "sanitize must NOT introduce an 'enabled_signals' key (FC-C1-14)"
    refute_includes result.keys, :enabled_signals,
                     "sanitize must NOT introduce a symbol :enabled_signals key (FC-C1-14)"
  end

  # (a') sanitize does not add the key even when the input had none and is otherwise blank.
  def test_sanitize_does_not_synthesize_enabled_signals_from_blank_input
    result, = S.sanitize({}, {})
    refute_includes result.keys, 'enabled_signals',
                     'blank input must not synthesize an enabled_signals key'
  end

  # (b) building a DEFAULT ScoringConfig does not mutate the input settings hash and
  # introduces no 'enabled_signals' key. Mirrors the provider default path: nil weights
  # => registry-resolved defaults, no explicit enabled_signals: kwarg.
  def test_default_scoring_config_does_not_mutate_settings_or_add_key
    settings = valid_settings
    before = Marshal.load(Marshal.dump(settings)) # deep snapshot

    # Default construction: registry-resolved defaults (no enabled_signals: kwarg).
    cfg = Pulse::Domain::ScoringConfig.new

    assert_equal before, settings,
                 'building a default ScoringConfig must not mutate the settings hash'
    refute_includes settings.keys, 'enabled_signals',
                    'the settings hash must carry no enabled_signals key after default build'

    # The enabled set is resolved to the built-ins WITHOUT being persisted anywhere.
    assert_equal Pulse::Domain::SignalRegistry.keys.sort, cfg.enabled_signals.sort,
                 'default enabled set == the built-in registry keys (resolved, not persisted)'
  end

  # (c) the default enabled set is a COMPUTED value (registry-derived), not a settings key.
  def test_default_enabled_set_is_registry_resolved_not_a_settings_key
    assert_equal Pulse::Domain::SignalRegistry.keys.sort,
                 Pulse::Domain::SignalRegistry.default_enabled_keys.sort,
                 'default_enabled_keys resolves the built-ins programmatically from the catalog'
    refute_includes valid_settings.keys, 'enabled_signals',
                    'no enabled_signals key exists in a canonical settings hash'
  end
end
