# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Deterministic, ORDER-INDEPENDENT proof that PulseAdapterTestSupport's teardown hook
# restores I18n.locale and User.current after every test.
#
# The defect: I18nLensAndUnitsTest#test_pulse_renders_dutch_labels_for_nl_user
# sets I18n.locale = :nl inside a request cycle with no post-test reset.
# Tests that call domain adapters directly (e.g. HtmlPresenter.signal_rows) then
# render in Dutch and fail on English label assertions. User.current suffers the
# same class of leak from login_as fallbacks in several functional tests.
#
# Design: ONE self-contained test method — poison-then-verify WITHIN the method, with
# no dependence on sibling-test ordering. The earlier two-method design (TestA poisons,
# TestB asserts) was only a genuine proof if TestA happened to run first; when minitest
# randomised TestB ahead of TestA it merely re-confirmed the initial defaults and proved
# nothing about restoration. This method instead:
#   (1) poisons BOTH globals (locale -> :nl, User.current -> a real logged-in user),
#   (2) fires the SAME teardown callback chain minitest runs between tests
#       (run_callbacks(:teardown)), so it exercises the ACTUAL registered hook — not a
#       re-implementation — and
#   (3) asserts both globals were restored.
# The order guarantee is intrinsic (poison and verify are the same method body), so the
# proof holds under any run order and on both fresh and warm DBs.
#
# Assertions are property-based (not identity-based) to be DB-freshness-independent:
#   - locale: assert I18n.locale == I18n.default_locale (stable framework constant)
#   - user:   assert User.current.anonymous? (semantic property — AnonymousUser
#             responds true; any real logged-in user responds false)
# This avoids the fragility of comparing against a User record captured at load
# time — on a freshly-reset DB the anonymous user row may have a different id.
class LocaleUserTeardownProofTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  # ── poison BOTH globals, fire the registered teardown chain, assert restoration ──
  def test_teardown_hook_restores_locale_and_user_after_poisoning
    # (1) Poison locale.
    I18n.locale = :nl
    assert_equal :nl, I18n.locale, 'precondition: locale is poisoned to :nl'

    # (1) Poison User.current to a logged-in (non-anonymous) user.
    real_user = User.where(admin: true).first || User.first
    skip 'no User rows available — cannot poison User.current' unless real_user
    User.current = real_user
    refute User.current.anonymous?,
           'precondition: User.current is poisoned to a non-anonymous user'

    # (2) Fire the EXACT teardown callback chain minitest runs between tests. This exercises
    #     the registered PulseAdapterTestSupport hook itself (not a copy of its logic), so a
    #     broken/unregistered hook fails this assertion. run_callbacks runs before/after too;
    #     the block is the test-body slot (already run), so we pass an empty block.
    run_callbacks(:teardown) { }

    # (3) Both globals must be back at their canonical defaults.
    assert_equal I18n.default_locale, I18n.locale,
                 'LOCALE LEAK: the PulseAdapterTestSupport teardown hook did not restore ' \
                 "I18n.locale to the default. Got #{I18n.locale.inspect}, " \
                 "expected #{I18n.default_locale.inspect}."
    assert User.current.anonymous?,
           'USER LEAK: the PulseAdapterTestSupport teardown hook did not restore ' \
           "User.current to an anonymous user. Got #{User.current.inspect}."
  ensure
    # The real between-tests teardown runs again after this method; make its work idempotent
    # by leaving the globals at defaults regardless of assertion outcome.
    I18n.locale = I18n.default_locale if defined?(I18n) && I18n.respond_to?(:locale=)
    User.current = User.anonymous if defined?(User) && User.respond_to?(:current=)
  end
end
