# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# H1 I18n sweep — RED guards for the two HTML-surface i18n gaps (F8, F6).
#
#   I18N-F8  app/views/pulse/index.html.erb:17 — the lens selector renders the RAW
#            machine key (<%= lens %>) as the <option> display text instead of the
#            localized label t("label_pulse_lens_#{lens}"). A non-English user sees
#            "at_risk" in the dropdown. The 5 label_pulse_lens_* keys already exist.
#
#   I18N-F6  lib/pulse/adapters/html_presenter.rb#humanize_span — the unit words
#            ('seconds'/'minutes'/'hours'/'days', and their singular forms) must resolve
#            through I18n (pulse.unit_*) and be interpolated into the (localized)
#            pulse.computed_ago string, so a translated wrapper emits a translated unit.
#
# Both once caught the hardcoded-string signature (pre-fix RED); they PASS now that the
# labels and unit words are localized.
# Postgres-only evidence lane (mirrors pulse_controller_test); skips on non-Postgres so
# the CI MySQL legs stay green.
class I18nLensAndUnitsTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'I18nAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'i18nuser')
    @project = create_project!(name: 'I18nProj', identifier: 'i18n-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  # ── I18N-F8 : lens <option> text must be the localized label, not the raw key ──

  # Isolate the lens <select> element body so we scan ONLY the option text, not the
  # whole page (the raw key appears legitimately as the option VALUE attribute and in
  # ?lens= URLs; the DEFECT is specifically the visible option TEXT).
  def lens_select_body(html)
    html[%r{<select[^>]*id=["']pulse-lens["'][^>]*>(.*?)</select>}m, 1]
  end

  def test_lens_option_text_is_localized_label_not_raw_key
    login_as(@user)
    get '/pulse'
    assert_response :success
    body = lens_select_body(response.body)
    refute_nil body, 'the lens <select id="pulse-lens"> must be present'

    # The visible option TEXT (between > and </option>) for the at_risk lens must be the
    # localized label ("At risk"), NOT the raw machine key "at_risk".
    at_risk_label = I18n.t(:label_pulse_lens_at_risk) # "At risk"
    option_texts = body.scan(%r{<option[^>]*>(.*?)</option>}m).flatten.map(&:strip)

    assert_includes option_texts, at_risk_label,
                    'I18N-F8: the lens <option> display TEXT must be the localized label ' \
                    "#{at_risk_label.inspect} (t(:label_pulse_lens_at_risk)), not a raw key"
    refute_includes option_texts, 'at_risk',
                    'I18N-F8: the raw machine key "at_risk" must NOT be the visible <option> ' \
                    'text (index.html.erb:17 renders <%= lens %> verbatim today)'
  end

  def test_every_lens_option_text_resolves_to_its_localized_label
    login_as(@user)
    get '/pulse'
    assert_response :success
    body = lens_select_body(response.body)
    refute_nil body, 'the lens <select id="pulse-lens"> must be present'
    option_texts = body.scan(%r{<option[^>]*>(.*?)</option>}m).flatten.map(&:strip)

    %w[health at_risk stale done blocked].each do |lens|
      label = I18n.t("label_pulse_lens_#{lens}")
      assert_includes option_texts, label,
                      "I18N-F8: lens '#{lens}' option text must render the localized label " \
                      "#{label.inspect}, not the raw key"
      refute_includes option_texts, lens,
                      "I18N-F8: the raw lens key '#{lens}' must NOT appear as visible option text"
    end
  end

  # ── nl locale: the plugin renders Dutch strings when the viewer's language is nl ──

  def test_pulse_renders_dutch_labels_for_nl_user
    @user.update_column(:language, 'nl')
    login_as(@user)
    get '/pulse'
    assert_response :success
    # label_pulse_portfolio (nl) = "Portfoliogezondheid"; the English heading must be gone.
    assert_match(/Portfoliogezondheid/, response.body,
                 'the portfolio heading must render the Dutch label for an nl user (nl.yml loaded)')
    refute_match(/Portfolio health/, response.body,
                 'the English portfolio heading must not appear for an nl user')
    # label_pulse_main_concern (nl) = "Belangrijkste aandachtspunt".
    assert_match(/Belangrijkste aandachtspunt/, response.body,
                 'the main-concern column header must render in Dutch')
  end

  # ── I18N-F6 : the computed-ago time UNIT must resolve through I18n, not be raw English ──

  # Drive the rendered cockpit under a TEMPORARY override of the pulse.unit_* keys: if the
  # presenter resolves the unit through I18n (pulse.unit_days etc.), the override changes
  # the rendered unit; if it emits a hardcoded English 'days'/'hours', the override has NO
  # effect and the English word still appears -> RED. We override only the unit keys (and
  # keep computed_ago's wrapper intact) so the assertion isolates the unit slot.
  def with_unit_overrides
    sentinel = {
      unit_seconds: 'XSEC', unit_minutes: 'XMIN', unit_hours: 'XHOUR', unit_days: 'XDAY',
      # Singular forms too, so the assertion holds whatever the rendered N happens to be.
      unit_second: 'XSEC', unit_minute: 'XMIN', unit_hour: 'XHOUR', unit_day: 'XDAY'
    }
    backend = I18n.backend
    # Force the backend to load its on-disk translations FIRST, so the sentinel below is
    # merged ON TOP of them. If we store while the backend is still lazy-uninitialized, the
    # first lookup during the request triggers init_translations, which merges en.yml over
    # our sentinel and wipes it — a seed/order-dependent flake.
    I18n.t(:label_pulse)
    backend.store_translations(:en, pulse: sentinel)
    yield
  ensure
    # Best-effort: drop the sentinels so other tests see the real (or absent) keys again.
    I18n.backend.reload!
  end

  def test_computed_ago_unit_resolves_through_i18n
    login_as(@user)
    rendered = nil
    with_unit_overrides do
      get '/pulse'
      assert_response :success
      rendered = response.body
    end

    # The portfolio row carries a "computed N <unit> ago" string. With the pulse.unit_*
    # keys overridden to sentinels, a presenter that resolves the unit via I18n emits the
    # sentinel (XDAY/XHOUR/XMIN/XSEC). A presenter that hardcoded the English word would emit
    # 'days'/'hours'/... regardless -> this assertion would then FAIL (the pre-fix state).
    computed_fragment = rendered[/computed\s+\d+\s+\S+\s+ago/i]
    refute_nil computed_fragment,
               'the portfolio must render a "computed N <unit> ago" string'
    assert_match(/X(?:SEC|MIN|HOUR|DAY)/, computed_fragment,
                 'I18N-F6: the time UNIT in "computed N <unit> ago" must resolve through ' \
                 'I18n (pulse.unit_*) — overriding the unit keys must change the rendered ' \
                 "unit. Got: #{computed_fragment.inspect} (must not bypass I18n)")
    refute_match(/\b(?:seconds|minutes|hours|days)\b/i, computed_fragment,
                 'I18N-F6: a raw English unit word must NOT bypass I18n in the computed-ago string')
  end
end
