# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# C1 lesson: pure-adapter unit test — add lib/ to $LOAD_PATH before requiring the adapter.
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative '../../../lib/pulse/adapters/settings_sanitizer'

# IT-C4-06 (sanitizer slice) — FR-C4-02/04/09 / FC-C4-05, FC-C4-14.
# Admin-defined profiles + role-bindings live under the "pulse_profiles" settings key.
# SettingsSanitizer validates that key ADDITIVELY (the existing C1/C2 sanitizer contract is
# unchanged — a settings hash without pulse_profiles sanitizes exactly as before):
#   * each profile entry: non-empty id (NOT the reserved "default"), non-empty name,
#     per-field-bounded config (reusing the C1/C2 ScoringConfig weight bounds: exactly the
#     required keys, finite >= 0, Σ == 1.0);
#   * each role-binding: positive-integer role_id, profile_id in the defined set (or "default");
#   * invalid entries are REJECTED/DROPPED entirely (never partially persisted) and reported;
#   * the system default is SYNTHETIC — its presence requires NO settings entry;
#   * id "default" is RESERVED — an admin profile entry with id "default" is rejected.
#
# The sanitizer surface these tests pin (A9 implements to match): SettingsSanitizer.sanitize
# returns [sanitized_hash, errors]; the sanitized hash carries a validated 'pulse_profiles'
# sub-hash { 'profiles' => {id => {name, weights, ...}}, 'role_bindings' => {role_id => id} };
# `errors` names each rejected pulse_profiles entry.
#
# RED NOW: SettingsSanitizer.sanitize does not yet validate 'pulse_profiles' — the key passes
# through unvalidated (or is dropped). GREEN after A9 adds the additive pulse_profiles
# validation per FC-C4-14. Pure-adapter lane: ruby -Itest -Ilib.
class SettingsSanitizerProfilesTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  FIVE = {
    'staleness' => 0.25, 'progress' => 0.25, 'momentum' => 0.20,
    'risk_load' => 0.15, 'blocked_load' => 0.15
  }.freeze

  # A base (profiles-free) previous settings hash.
  def previous
    { 'rag_green_min' => 67, 'rag_amber_min' => 34, 'h_stale' => 180, 'h_risk' => 50,
      'h_blocked' => 20, 'activity_window_days' => 30, 'weights' => FIVE.dup }
  end

  def pulse_profiles(profiles:, role_bindings: {})
    { 'profiles' => profiles, 'role_bindings' => role_bindings }
  end

  def valid_profile(name: 'Balanced', weights: FIVE)
    { 'name' => name, 'weights' => weights.dup }
  end

  def sanitized_profiles(result)
    result['pulse_profiles'] || {}
  end

  # === FC-C4-14 (a): a valid pulse_profiles hash sanitizes clean ================
  def test_valid_profiles_and_bindings_sanitize_clean
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(
        profiles: { 'balanced' => valid_profile }, role_bindings: { '3' => 'balanced' }
      )
    )
    result, errors = S.sanitize(incoming, previous)
    refute_includes errors, 'pulse_profiles',
                    'FC-C4-14(a): a valid pulse_profiles hash must sanitize without error'
    profiles = sanitized_profiles(result)['profiles'] || {}
    assert profiles.key?('balanced') || profiles.key?(:balanced),
           'the valid profile is preserved'
    bindings = sanitized_profiles(result)['role_bindings'] || {}
    assert_equal 'balanced', (bindings['3'] || bindings[3]),
                 'the valid role-binding is preserved'
  end

  # === FC-C4-05 / FC-C4-14 (b): the reserved id "default" is rejected ============
  def test_reserved_default_id_is_rejected
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(profiles: { 'default' => valid_profile })
    )
    result, errors = S.sanitize(incoming, previous)
    assert_includes errors, 'pulse_profiles',
                    'FC-C4-14(b): an admin profile with the RESERVED id "default" must be rejected'
    profiles = sanitized_profiles(result)['profiles'] || {}
    refute(profiles.key?('default') || profiles.key?(:default),
           'the reserved "default" id must never be persisted as an admin profile')
  end

  # === FC-C4-14 (b): empty id / empty name / bad weights => rejected ============
  def test_empty_name_profile_is_rejected
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(profiles: { 'p1' => valid_profile(name: '') })
    )
    _, errors = S.sanitize(incoming, previous)
    assert_includes errors, 'pulse_profiles', 'an empty profile name must be rejected'
  end

  def test_bad_weights_profile_is_rejected
    # Σweights != 1.0 — must be rejected (the config bounds are reused, not bypassed).
    bad = valid_profile(weights: { 'staleness' => 0.9, 'progress' => 0.9,
                                   'momentum' => 0.9, 'risk_load' => 0.9, 'blocked_load' => 0.9 })
    incoming = previous.merge('pulse_profiles' => pulse_profiles(profiles: { 'p1' => bad }))
    _, errors = S.sanitize(incoming, previous)
    assert_includes errors, 'pulse_profiles',
                    'a profile whose weights do not sum to 1.0 must be rejected (config bounds reused)'
  end

  def test_rejected_profile_is_dropped_not_partially_persisted
    bad = valid_profile(weights: { 'staleness' => 2.0 }) # single-key, Σ != 1.0, wrong key set
    incoming = previous.merge('pulse_profiles' => pulse_profiles(profiles: { 'p1' => bad }))
    result, = S.sanitize(incoming, previous)
    profiles = sanitized_profiles(result)['profiles'] || {}
    refute(profiles.key?('p1') || profiles.key?(:p1),
           'a rejected profile must be DROPPED entirely, never partially persisted')
  end

  # === FC-C4-14 (c): role-binding with bad role_id or dangling profile_id =======
  def test_role_binding_with_non_positive_role_id_is_rejected
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(
        profiles: { 'balanced' => valid_profile }, role_bindings: { '0' => 'balanced' }
      )
    )
    result, errors = S.sanitize(incoming, previous)
    assert_includes errors, 'pulse_profiles',
                    'a role-binding with a non-positive role_id must be rejected'
    bindings = sanitized_profiles(result)['role_bindings'] || {}
    refute(bindings.key?('0') || bindings.key?(0),
           'the invalid role-binding must not be persisted')
  end

  def test_role_binding_to_undefined_profile_is_rejected
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(
        profiles: { 'balanced' => valid_profile }, role_bindings: { '3' => 'gone' }
      )
    )
    result, errors = S.sanitize(incoming, previous)
    assert_includes errors, 'pulse_profiles',
                    'a role-binding to an undefined profile_id must be rejected (FC-C4-14 c)'
    bindings = sanitized_profiles(result)['role_bindings'] || {}
    refute_equal 'gone', (bindings['3'] || bindings[3]),
                 'the dangling role-binding must not be persisted'
  end

  def test_role_binding_to_default_is_allowed
    incoming = previous.merge(
      'pulse_profiles' => pulse_profiles(
        profiles: { 'balanced' => valid_profile }, role_bindings: { '3' => 'default' }
      )
    )
    _, errors = S.sanitize(incoming, previous)
    refute_includes errors, 'pulse_profiles',
                    'a role-binding to the reserved "default" id is a VALID binding target'
  end

  # === FC-C4-14 (d): absence of pulse_profiles => no error (additive, synthetic default) =
  def test_absent_pulse_profiles_produces_no_error
    result, errors = S.sanitize(previous.dup, previous)
    refute_includes errors, 'pulse_profiles',
                    'FC-C4-14(d): a settings hash without pulse_profiles must sanitize clean ' \
                    '(the synthetic default needs no entry)'
    # ADDITIVE: the existing weight sanitization is unchanged.
    assert_in_delta 1.0, result['weights'].values.map(&:to_f).sum, 1e-9,
                    'the existing (non-profile) sanitizer contract is unchanged'
  end

  # The C1/C2 sanitizer contract remains byte-stable when no pulse_profiles is present:
  # the sanitized result for a profiles-free input must equal the pre-C4 sanitized result.
  def test_profiles_free_sanitize_is_backward_compatible
    incoming = previous.merge('weights' => FIVE.dup)
    result, errors = S.sanitize(incoming, previous)
    assert_empty errors, 'a profiles-free valid input sanitizes with zero errors (unchanged)'
    refute result.key?('pulse_profiles'),
           'no synthetic pulse_profiles key is injected when the admin defined none'
  end
end
