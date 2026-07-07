# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# Note: pure-adapter unit test — add lib/ to $LOAD_PATH before requiring the adapter.
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative '../../../lib/pulse/adapters/settings_sanitizer'

# Alert settings — two new alert settings keys, ALERT-OFF defaults:
#   (1) pulse_alert_auto_subscribe_role_id (Integer|nil; nil = disabled, DEFAULT)
#   (2) pulse_alert_score_delta_threshold  (Numeric|nil; nil/0 = disabled, DEFAULT)
# SettingsSanitizer validates them ADDITIVELY (existing keys sanitize exactly as before —
# a settings hash without these keys is unaffected). Invalid values are REJECTED and the
# PRIOR valid value is kept (the existing guard pattern); the key is reported in `errors`.
# Nil/zero defaults ensure NO alert fires on install until the operator configures.
#
# The sanitizer surface: SettingsSanitizer.sanitize(incoming, previous) -> [sanitized, errors].
# Pure-adapter lane: ruby -Itest -Ilib.
class SettingsSanitizerAlertKeysTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  ROLE_KEY = 'pulse_alert_auto_subscribe_role_id'
  N_KEY = 'pulse_alert_score_delta_threshold'

  def san(incoming, previous = {})
    S.sanitize(incoming, previous)
  end

  # ── additivity: absence of the new keys does not disturb the existing contract
  def test_absent_alert_keys_do_not_appear_and_no_error
    sanitized, errors = san({ 'rag_green_min' => 67 })
    refute errors.include?(ROLE_KEY)
    refute errors.include?(N_KEY)
    refute sanitized.key?(ROLE_KEY), 'no alert-role key is synthesized when absent'
    refute sanitized.key?(N_KEY)
  end

  # ── auto_subscribe_role_id: valid positive integer accepted ─────────────────
  def test_valid_role_id_accepted
    sanitized, errors = san({ ROLE_KEY => 5 })
    refute_includes errors, ROLE_KEY
    assert_equal 5, sanitized[ROLE_KEY]
  end

  # ── auto_subscribe_role_id: nil (disabled) accepted as the OFF default ───────
  def test_nil_role_id_is_valid_disabled
    sanitized, errors = san({ ROLE_KEY => nil })
    refute_includes errors, ROLE_KEY
    assert_nil sanitized[ROLE_KEY], 'nil role id => auto-subscribe disabled (valid)'
  end

  # ── auto_subscribe_role_id: non-integer / non-positive rejected, prior kept ──
  def test_non_integer_role_id_rejected_keeps_prior
    sanitized, errors = san({ ROLE_KEY => 'abc' }, { ROLE_KEY => 3 })
    assert_includes errors, ROLE_KEY, 'a non-integer role id is reported'
    assert_equal 3, sanitized[ROLE_KEY], 'the prior valid value is kept on reject'
  end

  def test_non_positive_role_id_rejected
    _sanitized, errors = san({ ROLE_KEY => 0 }, {})
    assert_includes errors, ROLE_KEY, 'a non-positive role id is rejected (0 is not a role)'
  end

  # ── score_delta_threshold: valid numeric accepted ───────────────────────────
  def test_valid_score_delta_threshold_accepted
    sanitized, errors = san({ N_KEY => 15 })
    refute_includes errors, N_KEY
    assert_equal 15, sanitized[N_KEY]
  end

  # ── score_delta_threshold: 0 / nil = disabled default, accepted ─────────────
  def test_zero_threshold_is_valid_disabled
    sanitized, errors = san({ N_KEY => 0 })
    refute_includes errors, N_KEY
    assert_equal 0, sanitized[N_KEY], '0 => score_delta disabled (valid default)'
  end

  # ── score_delta_threshold: negative / non-numeric rejected, prior kept ──────
  def test_negative_threshold_rejected_keeps_prior
    sanitized, errors = san({ N_KEY => -5 }, { N_KEY => 20 })
    assert_includes errors, N_KEY, 'a negative threshold is rejected'
    assert_equal 20, sanitized[N_KEY], 'the prior valid value is kept on reject'
  end

  def test_non_numeric_threshold_rejected
    _sanitized, errors = san({ N_KEY => 'big' }, {})
    assert_includes errors, N_KEY, 'a non-numeric threshold is rejected'
  end
end
