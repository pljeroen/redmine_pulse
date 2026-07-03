# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# CA-23 / FC-CA-30 / COND-CA-03 / COND-CA-01: SETTINGS VALIDATION to the EXACT
# ScoringConfig bounds (DG-07), I18n errors on rejection, defaults ship working
# (DEC-13), and a successful save bumps settings_version_hash so affected snapshots
# recompute on next GET (FC-CA-22 M5).
#
# The exact bounds are READ from the as-built ScoringConfig so the test pins the real
# contract, not informal ranges. Drives the admin settings POST through the harness.
# Postgres-gated (FC-CA-38). RED until A9 builds the settings partial + validation.
class SettingsValidationTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :users, :roles, :trackers, :enumerations, :issue_statuses

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    @admin = create_user!(login: 'pulseadm', admin: true)
  end

  def login_admin
    post '/login', params: { username: @admin.login, password: 'password' }
  rescue StandardError
    User.current = @admin
  end

  def save_settings(settings)
    login_admin
    post '/settings/plugin/redmine_pulse',
         params: { settings: settings }
  end

  def current_settings
    s = Setting.plugin_redmine_pulse
    s.is_a?(Hash) ? s : {}
  end

  # ─────────────── DEC-13: defaults ship working (valid ScoringConfig) ───────

  def test_defaults_yield_valid_scoring_config
    pulse_settings! # init.rb-style defaults
    assert_nothing_raised('defaults must produce a valid ScoringConfig (DEC-13)') do
      Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    end
  end

  # ──────── EXACT bounds (DG-07): each invalid input is REJECTED ─────────────

  def test_activity_window_days_zero_rejected
    save_settings(current_settings.merge('activity_window_days' => '0'))
    # Invalid -> rejected with a user-facing error; the persisted value must NOT be 0.
    refute_equal 0, current_settings['activity_window_days'].to_i,
                 'activity_window_days must be >= 1 (rejected, not persisted)'
  end

  def test_horizon_below_one_rejected
    %w[h_stale h_risk h_blocked].each do |h|
      pulse_settings!
      save_settings(current_settings.merge(h => '0'))
      refute_equal 0, current_settings[h].to_i, "#{h} must be >= 1 (rejected)"
    end
  end

  def test_rag_amber_above_green_rejected
    save_settings(current_settings.merge('rag_green_min' => '40', 'rag_amber_min' => '80'))
    s = current_settings
    refute(s['rag_amber_min'].to_i > s['rag_green_min'].to_i,
           'rag_amber_min must be <= rag_green_min (rejected)')
  end

  def test_rag_threshold_out_of_range_rejected
    save_settings(current_settings.merge('rag_green_min' => '150'))
    refute_equal 150, current_settings['rag_green_min'].to_i,
                 'RAG thresholds must lie in [0,100] (rejected)'
  end

  def test_weights_not_summing_to_one_rejected_or_normalized
    bad = { 'staleness' => '0.5', 'progress' => '0.5', 'momentum' => '0.5',
            'risk_load' => '0.5', 'blocked_load' => '0.5' } # sums to 2.5
    save_settings(current_settings.merge('weights' => bad))
    # Either rejected (weights unchanged-from-default) or normalized to sum 1.0; in no
    # case may the effective ScoringConfig be invalid.
    assert_nothing_raised('settings must never persist an invalid weight set') do
      Pulse::Adapters::RedmineSettingsProvider.new.scoring_config
    end
  end

  # ── CA-A10-001: invalid settings are REJECTED *and* a user-facing localized error is
  # surfaced — NOT silently sanitized. The current init.rb:114 `sanitized, = ...` discards
  # the SettingsSanitizer error array, so the fallback is persisted with NO observable
  # rejection. These two tests pin BOTH halves of the required behavior:
  #   (a) the prior VALID value remains persisted (unchanged) — invalid input not stored;
  #   (b) a user-visible / localized error is produced (flash[:error]/flash[:warning] or a
  #       settings-error rendered in the response), not a silent success.
  # RED against the silent-sanitize impl. ───────────────────────────────────────────────

  # Helper: the localized success notice Redmine emits on a clean save; a REJECTION must
  # NOT be reported as this. We assert an error is present in addition to non-persistence.
  def flash_error_text
    [flash[:error], flash[:warning]].compact.join(' ').to_s
  end

  def test_out_of_bounds_value_keeps_prior_value_persisted
    # Establish a known-good prior value, then submit an out-of-bounds one.
    save_settings(current_settings.merge('rag_green_min' => '70'))
    assert_equal 70, current_settings['rag_green_min'].to_i,
                 'precondition: a valid value persists'

    save_settings(current_settings.merge('rag_green_min' => '150')) # out of [0,100]
    assert_equal 70, current_settings['rag_green_min'].to_i,
                 'CA-A10-001(a): an out-of-bounds value must NOT be persisted; the prior ' \
                 'valid value (70) must remain unchanged'
  end

  def test_out_of_bounds_value_surfaces_user_facing_localized_error
    # Seed a valid value so the only change is the invalid one.
    save_settings(current_settings.merge('rag_green_min' => '70'))

    save_settings(current_settings.merge('rag_green_min' => '150')) # out of [0,100]

    # (b) A rejection MUST be observable to the user: a flash error/warning OR a settings
    # error rendered in the response body. A silent redirect with only a success notice
    # (or no message at all) FAILS this assertion.
    err = flash_error_text
    body = response.body.to_s
    observable_error =
      !err.empty? ||
      body =~ /(?:flash|settings)[-_ ]?error/i ||
      body =~ /\b(invalid|rejected|out of range|must be)\b/i

    refute_nil observable_error,
               'CA-A10-001(b): rejected settings must surface a user-facing error'
    assert observable_error,
           'CA-A10-001(b): an out-of-bounds settings value must produce an observable, ' \
           'user-facing (localized) rejection error — flash[:error]/[:warning] or a ' \
           'rendered settings error — not a silent sanitize'

    # The surfaced message must NOT be presented as a successful update.
    success = I18n.t(:notice_successful_update)
    if !err.empty?
      refute_equal success, err,
                   'CA-A10-001(b): a rejection must not be reported as a successful update'
    end
  end

  # ── settings-promote-momentum (CT-02): the 3 promoted FLOAT fields are validated ──
  # momentum_activity_half (> 0), momentum_direction_bias ([0,0.5]), on_track_threshold
  # ([0,1]). Each out-of-range input is REJECTED and the prior/stored value is RETAINED
  # (mirror test_activity_window_days_zero_rejected / test_horizon_below_one_rejected).
  # RED until A9 adds float sanitizers + the partial fields.

  def test_momentum_activity_half_non_positive_rejected
    # Seed a known-good prior value, then submit a non-positive one.
    save_settings(current_settings.merge('momentum_activity_half' => '6'))
    assert_in_delta 6.0, current_settings['momentum_activity_half'].to_f, 1e-9,
                    'precondition: a valid momentum_activity_half persists'
    save_settings(current_settings.merge('momentum_activity_half' => '0')) # not strictly positive
    assert_in_delta 6.0, current_settings['momentum_activity_half'].to_f, 1e-9,
                    'momentum_activity_half must be > 0 (rejected; prior value 6 retained)'
  end

  def test_momentum_activity_half_negative_rejected
    save_settings(current_settings.merge('momentum_activity_half' => '6'))
    save_settings(current_settings.merge('momentum_activity_half' => '-1'))
    assert_in_delta 6.0, current_settings['momentum_activity_half'].to_f, 1e-9,
                    'a negative momentum_activity_half must be rejected; prior value 6 retained'
  end

  def test_momentum_direction_bias_out_of_range_rejected
    save_settings(current_settings.merge('momentum_direction_bias' => '0.25'))
    assert_in_delta 0.25, current_settings['momentum_direction_bias'].to_f, 1e-9,
                    'precondition: a valid momentum_direction_bias persists'
    save_settings(current_settings.merge('momentum_direction_bias' => '0.9')) # > 0.5
    assert_in_delta 0.25, current_settings['momentum_direction_bias'].to_f, 1e-9,
                    'momentum_direction_bias must be in [0,0.5] (0.9 rejected; prior 0.25 retained)'
  end

  def test_on_track_threshold_out_of_range_rejected
    save_settings(current_settings.merge('on_track_threshold' => '0.6'))
    assert_in_delta 0.6, current_settings['on_track_threshold'].to_f, 1e-9,
                    'precondition: a valid on_track_threshold persists'
    save_settings(current_settings.merge('on_track_threshold' => '1.5')) # > 1
    assert_in_delta 0.6, current_settings['on_track_threshold'].to_f, 1e-9,
                    'on_track_threshold must be in [0,1] (1.5 rejected; prior 0.6 retained)'
  end

  # ── settings-promote-momentum BLANK_FIX: on an UPGRADED instance the 3 promoted
  # float keys (momentum_activity_half / momentum_direction_bias / on_track_threshold)
  # predate the settings, so they render BLANK. Clicking "Apply" must NOT reject fields
  # the admin never touched. A BLANK ("") or ABSENT value for these 3 means "use the
  # shipped default" (mirrors RedmineSettingsProvider#float_setting and the weights
  # sanitizer's blank => keep behaviour) — NOT an error. A PRESENT but invalid value
  # is STILL rejected (validation must not be disabled).
  #
  # These call SettingsSanitizer.sanitize directly so the contract is pinned at the unit
  # level. RED until the float-field block stops treating blank as invalid.
  PROMOTED_FLOAT_KEYS = %w[momentum_activity_half momentum_direction_bias on_track_threshold].freeze

  def sanitize(incoming, previous = {})
    Pulse::Adapters::SettingsSanitizer.sanitize(incoming, previous)
  end

  def test_blank_promoted_floats_are_not_errors
    # Admin clicks Apply on an upgraded instance: the 3 keys arrive BLANK, untouched.
    result, errors = sanitize(
      'momentum_activity_half' => '',
      'momentum_direction_bias' => '',
      'on_track_threshold' => ''
    )
    PROMOTED_FLOAT_KEYS.each do |k|
      refute_includes errors, k,
                      "BLANK #{k} must mean 'use default', NOT a rejection error"
      # No bogus value persisted: the key is unset (or carries a usable Numeric), so the
      # provider default applies at read time. A persisted blank/non-numeric is a bug.
      next unless result.key?(k)

      assert_kind_of Numeric, result[k],
                     "a persisted #{k} must be a real Numeric, never a blank/invalid value"
    end
  end

  def test_absent_promoted_floats_are_not_errors
    # The harder upgraded case: the keys are entirely ABSENT from the incoming hash.
    result, errors = sanitize({})
    PROMOTED_FLOAT_KEYS.each do |k|
      refute_includes errors, k,
                      "an ABSENT #{k} must mean 'use default', NOT a rejection error"
      next unless result.key?(k)

      assert_kind_of Numeric, result[k],
                     "an absent #{k} must not be persisted as a blank/invalid value"
    end
  end

  def test_present_invalid_promoted_floats_still_rejected
    # Regression guard: the blank-tolerance fix must NOT disable validation of PRESENT,
    # out-of-range values.
    prev = { 'momentum_activity_half' => 8.0,
             'momentum_direction_bias' => 0.15,
             'on_track_threshold' => 0.5 }
    result, errors = sanitize(
      { 'momentum_activity_half' => '0',      # not strictly positive
        'momentum_direction_bias' => '0.9',   # > 0.5
        'on_track_threshold' => '1.5' },       # > 1
      prev
    )
    PROMOTED_FLOAT_KEYS.each do |k|
      assert_includes errors, k,
                      "a PRESENT invalid #{k} must STILL be rejected"
      assert_in_delta prev[k], result[k].to_f, 1e-9,
                      "a rejected #{k} must retain the prior valid value"
    end
  end

  # ── remediation R1: FINITE-FLOAT sanitizer bypass. ─────────────────────────────────
  # SettingsSanitizer#strict_float does Float(raw.to_s.strip); in Ruby Float("1e309")
  # returns Float::INFINITY (NO error). float_strictly_positive only rejects <= 0.0, so an
  # OVERFLOW string like "1e309" for momentum_activity_half is ACCEPTED and PERSISTED as
  # Infinity — then Pulse::Domain::ScoringConfig raises on read. A non-finite float is NOT
  # a valid setting: it MUST be rejected exactly like any other present-but-invalid float
  # (mirror test_present_invalid_promoted_floats_still_rejected) — report the key + retain
  # the prior value. RED until strict_float rejects non-finite results.
  def test_overflow_momentum_activity_half_infinity_rejected
    prev = { 'momentum_activity_half' => 8.0 }
    # "1e309" overflows to Float::INFINITY via Float() — no ArgumentError is raised.
    assert_equal Float::INFINITY, Float('1e309'),
                 'precondition: "1e309" overflows to Infinity in this Ruby (Float() does not raise)'
    result, errors = sanitize({ 'momentum_activity_half' => '1e309' }, prev)
    assert_includes errors, 'momentum_activity_half',
                    'an overflow (Infinity) momentum_activity_half must be REJECTED, not persisted'
    assert_in_delta 8.0, result['momentum_activity_half'].to_f, 1e-9,
                    'a rejected overflow value must retain the prior valid value (8.0)'
    refute result['momentum_activity_half'].respond_to?(:finite?) &&
           !result['momentum_activity_half'].finite?,
           'the persisted momentum_activity_half must NEVER be a non-finite float'
  end

  def test_overflow_momentum_activity_half_larger_exponent_rejected
    prev = { 'momentum_activity_half' => 8.0 }
    result, errors = sanitize({ 'momentum_activity_half' => '1e400' }, prev)
    assert_includes errors, 'momentum_activity_half',
                    'an even-larger overflow ("1e400" => Infinity) must also be rejected'
    assert_in_delta 8.0, result['momentum_activity_half'].to_f, 1e-9,
                    'a rejected overflow value must retain the prior valid value (8.0)'
  end

  def test_direct_infinity_numeric_momentum_activity_half_rejected
    # The sanitizer's strict_float ALSO accepts a direct Numeric (raw.is_a?(Numeric) => to_f).
    # A direct Float::INFINITY must be rejected the same way as the overflow string.
    prev = { 'momentum_activity_half' => 8.0 }
    result, errors = sanitize({ 'momentum_activity_half' => Float::INFINITY }, prev)
    assert_includes errors, 'momentum_activity_half',
                    'a direct Float::INFINITY momentum_activity_half must be REJECTED'
    assert_in_delta 8.0, result['momentum_activity_half'].to_f, 1e-9,
                    'a rejected Infinity value must retain the prior valid value (8.0)'
  end

  # Defensive coverage: momentum_direction_bias ([0,0.5]) and on_track_threshold ([0,1])
  # have UPPER bounds, so Infinity already fails their range check — these are GREEN now.
  # They pin that the overflow is rejected on ALL three promoted floats regardless of the
  # (mechanism) so a future strict_float hardening cannot regress the range-checked pair.
  def test_overflow_range_checked_floats_already_rejected
    prev = { 'momentum_direction_bias' => 0.15, 'on_track_threshold' => 0.5 }
    result, errors = sanitize(
      { 'momentum_direction_bias' => '1e309', 'on_track_threshold' => '1e309' }, prev
    )
    assert_includes errors, 'momentum_direction_bias',
                    'Infinity is > 0.5 => momentum_direction_bias rejected (range check)'
    assert_includes errors, 'on_track_threshold',
                    'Infinity is > 1 => on_track_threshold rejected (range check)'
    assert_in_delta 0.15, result['momentum_direction_bias'].to_f, 1e-9,
                    'rejected momentum_direction_bias retains prior value'
    assert_in_delta 0.5, result['on_track_threshold'].to_f, 1e-9,
                    'rejected on_track_threshold retains prior value'
  end

  # ── WEIGHTS BLANK_FIX: on a fresh/upgraded instance the 5 weight inputs render
  # BLANK, so clicking "Apply" submits weights as a Hash of 5 empty strings. Per the
  # weights help text ("Leave every weight blank to use the shipped defaults.") and by
  # symmetry with the promoted-float blank-fix above, an ALL-BLANK weights submission
  # means "use the shipped defaults" — NOT a rejection. A PARTIAL set (some filled, some
  # blank) is STILL an incomplete/invalid set and is rejected. A complete invalid set
  # (non-numeric / negative / wrong key set / not summing to 1.0) is STILL rejected.
  # These call SettingsSanitizer.sanitize directly so the contract is pinned at the unit
  # level. RED until sanitize_weights stops treating an all-blank hash as invalid.
  ALL_BLANK_WEIGHTS = {
    'staleness' => '', 'progress' => '', 'momentum' => '',
    'risk_load' => '', 'blocked_load' => ''
  }.freeze

  def test_all_blank_weights_are_not_an_error
    # Admin clicks Apply on a fresh/upgraded instance: all 5 weights arrive BLANK.
    prev = { 'weights' => { 'staleness' => 0.3, 'progress' => 0.2, 'momentum' => 0.2,
                            'risk_load' => 0.15, 'blocked_load' => 0.15 } }
    result, errors = sanitize({ 'weights' => ALL_BLANK_WEIGHTS }, prev)
    refute_includes errors, 'weights',
                    'ALL-BLANK weights must mean "use the shipped defaults", NOT a rejection error'
    assert_equal prev['weights'], result['weights'],
                 'an all-blank weights submission must fall back to the previous/default weights'
  end

  def test_all_blank_weights_with_no_previous_fall_back_to_defaults
    result, errors = sanitize({ 'weights' => ALL_BLANK_WEIGHTS }, {})
    refute_includes errors, 'weights',
                    'ALL-BLANK weights with no prior value must mean defaults, NOT an error'
    assert_equal({}, result['weights'],
                 'with no previous, all-blank weights must yield {} (engine defaults), no error')
  end

  def test_partial_weights_set_still_rejected
    # Regression guard: an INCOMPLETE weight set (one filled, rest blank) is NOT all-blank;
    # it must STILL be rejected — you cannot persist a partial weight set.
    partial = ALL_BLANK_WEIGHTS.merge('staleness' => '0.5')
    prev = { 'weights' => { 'staleness' => 0.3, 'progress' => 0.2, 'momentum' => 0.2,
                            'risk_load' => 0.15, 'blocked_load' => 0.15 } }
    result, errors = sanitize({ 'weights' => partial }, prev)
    assert_includes errors, 'weights',
                    'a PARTIAL weight set (some filled, some blank) must STILL be rejected'
    assert_equal prev['weights'], result['weights'],
                 'a rejected partial weight set must retain the prior weights'
  end

  def test_valid_complete_weights_summing_to_one_accepted
    # Regression guard: a complete valid set summing to 1.0 is still accepted.
    valid = { 'staleness' => '0.3', 'progress' => '0.2', 'momentum' => '0.2',
              'risk_load' => '0.15', 'blocked_load' => '0.15' }
    result, errors = sanitize({ 'weights' => valid }, {})
    refute_includes errors, 'weights',
                    'a complete valid weight set summing to 1.0 must be accepted'
    assert_in_delta 1.0, result['weights'].values.sum, 1e-9,
                    'the accepted weight set must sum to 1.0'
  end

  def test_complete_weights_not_summing_to_one_rejected
    # Regression guard: a complete set that does NOT sum to 1.0 is still rejected.
    bad = { 'staleness' => '0.5', 'progress' => '0.5', 'momentum' => '0.5',
            'risk_load' => '0.5', 'blocked_load' => '0.5' } # sums to 2.5
    prev = { 'weights' => { 'staleness' => 0.3, 'progress' => 0.2, 'momentum' => 0.2,
                            'risk_load' => 0.15, 'blocked_load' => 0.15 } }
    result, errors = sanitize({ 'weights' => bad }, prev)
    assert_includes errors, 'weights',
                    'a complete weight set NOT summing to 1.0 must STILL be rejected'
    assert_equal prev['weights'], result['weights'],
                 'a rejected weight set must retain the prior weights'
  end

  # ── snapshot-max-age-refresh (CT-02 EVOLUTION): snapshot_max_age_minutes sanitize ──
  # Integer >= 0 (0 is VALID = disabled). A PRESENT-but-invalid value (negative /
  # non-numeric) is REJECTED: report + retain the prior value. A BLANK/ABSENT value
  # means "use the shipped default" — delete the key so the provider default 60 applies
  # (mirrors the momentum/weights blank-tolerance, NOT the legacy horizon intolerance).
  # These call SettingsSanitizer.sanitize directly so the contract is pinned at the unit
  # level. RED until GREEN adds the snapshot_max_age_minutes sanitizer.

  def test_snapshot_max_age_minutes_zero_is_accepted
    result, errors = sanitize({ 'snapshot_max_age_minutes' => '0' }, {})
    refute_includes errors, 'snapshot_max_age_minutes',
                    '0 is a VALID snapshot_max_age_minutes (disabled), NOT an error'
    assert_equal 0, result['snapshot_max_age_minutes'].to_i,
                 '0 must persist as the configured disabled value'
  end

  def test_snapshot_max_age_minutes_positive_is_accepted
    result, errors = sanitize({ 'snapshot_max_age_minutes' => '15' }, {})
    refute_includes errors, 'snapshot_max_age_minutes',
                    'a non-negative integer must be accepted'
    assert_equal 15, result['snapshot_max_age_minutes'].to_i,
                 'a valid snapshot_max_age_minutes must persist'
  end

  def test_snapshot_max_age_minutes_negative_rejected_and_prior_retained
    prev = { 'snapshot_max_age_minutes' => 30 }
    result, errors = sanitize({ 'snapshot_max_age_minutes' => '-5' }, prev)
    assert_includes errors, 'snapshot_max_age_minutes',
                    'a negative snapshot_max_age_minutes must be rejected'
    assert_equal 30, result['snapshot_max_age_minutes'].to_i,
                 'a rejected negative value must retain the prior value (30)'
  end

  def test_snapshot_max_age_minutes_non_numeric_rejected_and_prior_retained
    prev = { 'snapshot_max_age_minutes' => 30 }
    result, errors = sanitize({ 'snapshot_max_age_minutes' => 'abc' }, prev)
    assert_includes errors, 'snapshot_max_age_minutes',
                    'a non-numeric snapshot_max_age_minutes must be rejected'
    assert_equal 30, result['snapshot_max_age_minutes'].to_i,
                 'a rejected non-numeric value must retain the prior value (30)'
  end

  def test_blank_snapshot_max_age_minutes_is_not_an_error
    result, errors = sanitize({ 'snapshot_max_age_minutes' => '' }, {})
    refute_includes errors, 'snapshot_max_age_minutes',
                    'BLANK snapshot_max_age_minutes must mean "use the shipped default", NOT a rejection'
    if result.key?('snapshot_max_age_minutes')
      assert_kind_of Integer, result['snapshot_max_age_minutes'],
                     'a persisted snapshot_max_age_minutes must be a real Integer, never a blank'
    end
  end

  def test_absent_snapshot_max_age_minutes_is_not_an_error
    result, errors = sanitize({}, {})
    refute_includes errors, 'snapshot_max_age_minutes',
                    'an ABSENT snapshot_max_age_minutes must mean "use the shipped default", NOT a rejection'
    if result.key?('snapshot_max_age_minutes')
      assert_kind_of Integer, result['snapshot_max_age_minutes'],
                     'an absent snapshot_max_age_minutes must not persist as a blank/invalid value'
    end
  end

  # ── RT-07 (security-S3-defense): VALIDATE admin-set IDs at save. The enrichment
  # mappings effort_field / blocked_status / risk_trackers are currently PASSED THROUGH
  # verbatim (result[k] = incoming.fetch(...) / normalize_trackers only strips blanks) —
  # a non-integer / non-positive id is PERSISTED as-is and only fails safe downstream via
  # .to_i. Defense-in-depth: a PRESENT-but-INVALID id must be REJECTED at save and the
  # prior value RETAINED (mirror test_present_invalid_promoted_floats_still_rejected). A
  # VALID id still saves cleanly; a BLANK value means "unmapped" (use the default), NOT an
  # error. These call SettingsSanitizer.sanitize directly so the contract is pinned at the
  # unit level. RED until the sanitizer strict-integer-validates these three keys.

  # effort_field: a single custom-field id (positive integer). A non-integer ("abc") must
  # be REJECTED, not persisted verbatim; the prior value is retained.
  def test_effort_field_non_integer_rejected_and_prior_retained
    prev = { 'effort_field' => '5' }
    result, errors = sanitize({ 'effort_field' => 'abc' }, prev)
    assert_includes errors, 'effort_field',
                    'a PRESENT non-integer effort_field must be REJECTED (RT-07)'
    refute_equal 'abc', result['effort_field'],
                 'a rejected non-integer effort_field must NOT be persisted verbatim'
    assert_equal '5', result['effort_field'].to_s,
                 'a rejected effort_field must retain the prior valid value (5)'
  end

  # blocked_status: a single issue-status id (positive integer). Non-positive ("-1"/"0")
  # and non-integer ("x") must each be REJECTED, prior retained.
  def test_blocked_status_non_positive_or_non_integer_rejected_and_prior_retained
    %w[-1 0 x].each do |bad|
      prev = { 'blocked_status' => '7' }
      result, errors = sanitize({ 'blocked_status' => bad }, prev)
      assert_includes errors, 'blocked_status',
                      "a PRESENT invalid blocked_status (#{bad.inspect}) must be REJECTED (RT-07)"
      refute_equal bad, result['blocked_status'],
                   "a rejected blocked_status (#{bad.inspect}) must NOT be persisted verbatim"
      assert_equal '7', result['blocked_status'].to_s,
                   "a rejected blocked_status (#{bad.inspect}) must retain the prior value (7)"
    end
  end

  # risk_trackers: a LIST of tracker ids. normalize_trackers only strips blanks, so a
  # non-integer element ("notanint") is currently kept verbatim. The SANE behavior: a
  # non-integer tracker id must NOT be persisted verbatim — either the whole set is
  # retained (previous) OR only the valid integer ids survive. Assert the invalid element
  # is gone AND no non-integer string is persisted.
  def test_risk_trackers_with_non_integer_element_not_persisted_verbatim
    prev = { 'risk_trackers' => %w[3] }
    result, errors = sanitize({ 'risk_trackers' => %w[2 notanint] }, prev)

    persisted = Array(result['risk_trackers'])
    refute_includes persisted, 'notanint',
                    'a non-integer tracker id ("notanint") must NOT be persisted verbatim (RT-07)'
    # Every persisted tracker id must be a strict integer (string of digits or Integer).
    persisted.each do |t|
      assert_match(/\A\d+\z/, t.to_s,
                   "every persisted risk_trackers id must be a positive integer, got #{t.inspect}")
    end
    # SANE resolution: either the invalid element was dropped (only valid "2" kept) OR the
    # whole set was rejected and the prior retained. Both are acceptable; verbatim garbage
    # is NOT. An error may be reported (whole-set rejection) — do not require it, but if the
    # set is retained-with-drop the "2" survives.
    if errors.include?('risk_trackers')
      assert_equal %w[3], persisted,
                   'a whole-set rejection must retain the prior risk_trackers (3)'
    else
      assert_equal %w[2], persisted,
                   'a drop-invalid resolution must keep only the valid integer id (2)'
    end
  end

  # GUARD (GREEN): a fully VALID set of the three enrichment ids still saves cleanly — the
  # new validation must not over-reject legitimate values.
  def test_valid_enrichment_ids_still_accepted
    result, errors = sanitize(
      { 'effort_field' => '5', 'blocked_status' => '7', 'risk_trackers' => %w[2 4] },
      {}
    )
    %w[effort_field blocked_status risk_trackers].each do |k|
      refute_includes errors, k, "a VALID #{k} must NOT be rejected (no over-rejection)"
    end
    assert_equal '5', result['effort_field'].to_s, 'a valid effort_field persists'
    assert_equal '7', result['blocked_status'].to_s, 'a valid blocked_status persists'
    assert_equal %w[2 4], Array(result['risk_trackers']).map(&:to_s),
                 'a valid risk_trackers list persists'
  end

  # GUARD (GREEN): BLANK for any of the three means "unmapped" — use the default, NOT an
  # error (mirror the blank-tolerance the other fields have). A fresh instance renders
  # these blank; clicking Apply must not error.
  def test_blank_enrichment_ids_are_not_errors
    result, errors = sanitize(
      { 'effort_field' => '', 'blocked_status' => '', 'risk_trackers' => [''] },
      {}
    )
    %w[effort_field blocked_status risk_trackers].each do |k|
      refute_includes errors, k,
                      "a BLANK #{k} must mean 'unmapped/default', NOT a rejection error (RT-07)"
    end
    # No garbage persisted: blank scalars are unset/blank-ish, risk_trackers has no blank id.
    assert_empty Array(result['risk_trackers']).reject { |t| t.to_s.strip.empty? }
                 .reject { |t| t.to_s.match?(/\A\d+\z/) },
                 'a blank risk_trackers must not persist any non-integer id'
  end

  # security-S3-defense fix (MEDIUM-severity): an ABSENT effort_field / blocked_status
  # key means "unmapped" (delete the scalar => fall back to the default at read time) —
  # NOT "retain the prior mapping". This mirrors the momentum block (absent => unmapped)
  # and the snapshot block (absent => unmapped). The prior impl read
  # `incoming.fetch(k, previous[k])`, so an absent key silently RETAINED the prior value,
  # inconsistent with the stated contract and the sibling blocks. RED until the enrichment
  # scalars read `incoming[k]` so an absent key becomes nil => blank? => delete (unmapped).
  def test_absent_enrichment_ids_are_unmapped_not_retained
    # Empty incoming, prior values PRESENT. An untouched-on-this-POST key must UNMAP,
    # not persist the prior mapping.
    result, errors = sanitize({}, { 'effort_field' => 5, 'blocked_status' => 7 })
    %w[effort_field blocked_status].each do |k|
      refute_includes errors, k,
                      "an ABSENT #{k} must mean 'unmapped/default', NOT a rejection error"
      refute result.key?(k),
             "an ABSENT #{k} must be UNMAPPED (deleted), NOT retained from the prior mapping"
    end
  end

  # Companion parity assertion: the momentum block ALREADY unmaps an absent scalar. This
  # pins the intended parity the fix brings the enrichment block into (should be GREEN both
  # before and after the fix — it demonstrates the target behaviour).
  def test_absent_momentum_scalar_is_unmapped_parity
    result, errors = sanitize({}, { 'momentum_activity_half' => 8.0 })
    refute_includes errors, 'momentum_activity_half',
                    'an ABSENT momentum_activity_half must mean "use default", NOT an error'
    refute result.key?('momentum_activity_half'),
           'an ABSENT momentum_activity_half is UNMAPPED (deleted) — the parity the ' \
           'enrichment scalars must match'
  end

  # ──────────── successful save bumps settings_version_hash (M5) ─────────────

  def test_valid_save_bumps_settings_version_hash
    provider = Pulse::Adapters::RedmineSettingsProvider.new
    before = provider.settings_version_hash
    save_settings(current_settings.merge('rag_green_min' => '70'))
    after = Pulse::Adapters::RedmineSettingsProvider.new.settings_version_hash
    refute_equal before, after,
                 'a successful settings change must move settings_version_hash (FC-CA-22 M5)'
  end
end
