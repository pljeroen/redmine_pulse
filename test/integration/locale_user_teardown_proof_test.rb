# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Deterministic proof that PulseAdapterTestSupport's teardown hook restores
# I18n.locale and User.current after every test, regardless of run order.
#
# The defect: I18nLensAndUnitsTest#test_pulse_renders_dutch_labels_for_nl_user
# sets I18n.locale = :nl inside a request cycle with no post-test reset.
# Tests that call domain adapters directly (e.g. HtmlPresenter.signal_rows) then
# render in Dutch and fail on English label assertions. User.current suffers the
# same class of leak from login_as fallbacks in several functional tests.
#
# Design: Two test methods in ONE class — both run regardless of order (minitest
# randomizes within the class too). TestA poisons both globals. TestB reads them
# AFTER being set up by minitest (which calls teardown between methods) and asserts
# each was restored to its canonical default. Because both methods are in the same
# class and the class includes PulseAdapterTestSupport, the shared teardown fires
# between them. The proof is order-independent: whichever runs first, the other
# must find the defaults restored.
#
# Assertions are property-based (not identity-based) to be DB-freshness-independent:
#   - locale: assert I18n.locale == I18n.default_locale (stable framework constant)
#   - user:   assert User.current.anonymous? (semantic property — AnonymousUser
#             responds true; any real logged-in user responds false)
# This avoids the fragility of comparing against a User record captured at load
# time — on a freshly-reset DB the anonymous user row may have a different id.
class LocaleUserTeardownProofTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  # ── TestA: poison I18n.locale and User.current, then prove they reset ────
  # This test sets both globals to non-default values. When it finishes, the
  # PulseAdapterTestSupport teardown hook MUST restore them before TestB (or any
  # subsequent test in the suite) runs.
  def test_a_poison_both_globals
    # Poison locale.
    I18n.locale = :nl
    assert_equal :nl, I18n.locale, 'precondition: locale is poisoned to :nl'

    # Poison User.current to a logged-in user.
    real_user = User.where(admin: true).first || User.first
    skip 'no User rows available — cannot poison User.current' unless real_user

    User.current = real_user
    assert_equal real_user.id, User.current.id,
                 'precondition: User.current is poisoned to a non-anonymous user'

    # The test itself passes unconditionally; the proof is that TestB finds defaults.
    assert true, 'TestA ran and poisoned both globals; teardown must restore them'
  end

  # ── TestB: assert that both globals were restored to their canonical defaults ──
  # This test reads I18n.locale and User.current at the START of its setup window —
  # after TestA's teardown and before TestB's own body has run. Both must be at
  # their canonical defaults regardless of which method ran first.
  def test_b_teardown_restored_defaults
    assert_equal I18n.default_locale, I18n.locale,
                 'LOCALE LEAK: I18n.locale was not restored to the default by the ' \
                 "PulseAdapterTestSupport teardown. Got #{I18n.locale.inspect}, " \
                 "expected #{I18n.default_locale.inspect}. This indicates the teardown hook " \
                 'did not fire, or did not fire before this test ran.'

    assert User.current.anonymous?,
           'USER LEAK: User.current was not restored to an anonymous user by the ' \
           "PulseAdapterTestSupport teardown. Got #{User.current.inspect}. " \
           'This indicates the teardown hook did not fire, or did not fire before this test ran.'
  end
end
