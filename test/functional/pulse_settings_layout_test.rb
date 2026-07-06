# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'nokogiri'

# settings-ui-overlap-remediation (CT-03 BUGFIX): the two settings-page label-overlap
# defects. Redmine core CSS floats EVERY `p label` into a fixed ~200px left column, so a
# settings `<p>` containing MORE THAN ONE `<label>` stacks those labels on top of each
# other. The plugin ships redmine_pulse.css but defines NO float-neutralizing rule for the
# two multi-control rows, so their labels fall back to the floated core style and overlap.
#
#   DEF-01 (AC-01) — role-bindings entry `<p>` (partial lines 138-145) has TWO plain
#     <label> children (role_id + profile_id); both float into the same grid column.
#   DEF-02 (AC-02) — the event-filter group labels carry class="pulse-webhook-event-filter"
#     in markup (partial lines 258-267) but that class is UNDEFINED in the stylesheet, so
#     the four event-type checkbox labels float and jumble too.
#
# T-01 (structural render) + T-02 (CSS rule presence) are RED now against the current
# buggy markup/CSS and pass only once A9's fix lands. T-03 is a standing no-field-dropped
# regression guard (INV-01 byte-identical POST) — green before AND after.
#
# Postgres-gated for the RENDERED tests (T-01, T-03) to match the existing settings render
# evidence lane (settings_render_test.rb / FC-CA-38). T-02 is a pure static CSS file read
# with NO DB dependency, so it runs on EVERY adapter (it does not consult the Postgres gate).
class PulseSettingsLayoutTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :users, :roles, :trackers, :enumerations, :issue_statuses

  SETTINGS_ROUTE = '/settings/plugin/redmine_pulse'
  PLUGIN_ROOT = File.expand_path('../../..', File.expand_path(__FILE__))
  STYLESHEET = File.join(PLUGIN_ROOT, 'assets', 'stylesheets', 'redmine_pulse.css')

  # The grouping classes that OPT OUT of the floated grid column: a grouped/inline label is
  # NOT a "grid-level" label. The event-filter checkbox items use the fixed
  # `pulse-webhook-event-filter` class; the (not-yet-named) role-binding inline sub-labels
  # will use some `inline`-bearing class. Any label carrying one of these is excluded from
  # the "at most one grid-level label per <p>" count.
  GROUPING_CLASS_EXACT = 'pulse-webhook-event-filter'
  GROUPING_CLASS_SUBSTR = 'inline'

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    @admin = create_user!(login: 'pulselayout', admin: true)
    @tracker = (trackers(:trackers_001) rescue Tracker.first)
    @tracker ||= Tracker.generate!(default_status: open_status)
  end

  # The RENDERED tests need Redmine + a real render; gate them on the Postgres evidence
  # adapter exactly like the sibling settings suites. Called from T-01/T-03 (NOT setup) so
  # the static CSS test (T-02) still runs on the MySQL/SQLite legs.
  def require_render_lane!
    return if ActiveRecord::Base.connection.adapter_name =~ /postgres/i

    skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
  end

  def login_admin
    post '/login', params: { username: @admin.login, password: 'password' }
  rescue StandardError
    User.current = @admin
  end

  def render_settings_page
    login_admin
    get SETTINGS_ROUTE
    assert_response :success,
                    "the Pulse plugin settings page must render HTTP 200 at #{SETTINGS_ROUTE}"
    Nokogiri::HTML(response.body)
  end

  # A label is "grid-level" (floated into the ~200px left column by core CSS) UNLESS it
  # carries a grouping/opt-out class. Fix-agnostic: it does not care WHICH class the fix
  # adds to the role-binding sub-labels, only that they carry an `inline`-bearing (or the
  # known event-filter) grouping class so core's `p label` float no longer applies.
  def grid_level_label?(label)
    classes = label['class'].to_s.split(/\s+/)
    return true if classes.empty?

    !classes.any? do |c|
      c == GROUPING_CLASS_EXACT || c.include?(GROUPING_CLASS_SUBSTR)
    end
  end

  # ── T-01 (AC-01 / DEF-01, DEF-02, FR-03) — RED NOW ──────────────────────────
  # Every settings <p> in the Pulse form must expose AT MOST ONE grid-level (floated)
  # <label>. Fails today because the role-bindings entry <p> (partial 138-145) holds two
  # plain <label>s (role_id + profile_id), and (once markup is examined) the event-filter
  # row can only pass if its grouped labels carry the opt-out class. Falsifier: a settings
  # <p> with >1 grid-level DIRECT-CHILD label => FAIL. After the fix it passes.
  def test_no_settings_paragraph_has_more_than_one_grid_level_label
    require_render_lane!
    doc = render_settings_page

    # Scope to the Pulse settings fieldsets only (class prefix pulse-settings-*), so an
    # unrelated core <p> on the admin chrome can never mask or trip the assertion.
    scope = doc.css('fieldset[class*="pulse-settings-"]')
    assert scope.any?, 'expected the Pulse settings fieldsets (pulse-settings-*) to render'

    offenders = []
    scope.css('p').each do |p|
      # DIRECT-CHILD labels only (a wrapping grouped <label> around a checkbox is fine;
      # we count top-level labels of the <p>, which are what core floats).
      direct_labels = p.xpath('./label')
      grid_labels = direct_labels.select { |l| grid_level_label?(l) }
      next if grid_labels.size <= 1

      offenders << p
    end

    assert_empty offenders,
                 'AC-01/DEF-01: every settings <p> must expose AT MOST ONE grid-level ' \
                 '(floated) <label>; grouped labels must carry the non-floating opt-out ' \
                 "class. Offending <p>(s):\n" +
                 offenders.map { |p| "  * #{p.text.gsub(/\s+/, ' ').strip.inspect}" }.join("\n")
  end

  # ── T-02 (AC-02 / DEF-02) — RED NOW ─────────────────────────────────────────
  # redmine_pulse.css must define a float-NEUTRALIZING rule for the grouped event-filter
  # labels (`.pulse-webhook-event-filter` => float:none + a non-grid width/inline display),
  # AND at least one `float:none` rule scoped to SOME `pulse-`-prefixed settings class (the
  # role-binding inline sub-labels — class name not yet fixed, so assert the weaker
  # fix-agnostic property). Fails today: the class is applied in the ERB but has NO CSS
  # rule, and the stylesheet contains no float:none anywhere. Falsifier: a stylesheet with
  # no such rule fails. Whitespace-insensitive matching so formatting is irrelevant.
  def test_stylesheet_neutralizes_float_for_grouped_labels
    assert File.exist?(STYLESHEET),
           "the plugin stylesheet must exist at #{STYLESHEET}"
    # Collapse ALL whitespace so `float : none ;` and `float:none;` match identically.
    css = File.read(STYLESHEET).gsub(/\s+/, '')

    # (a) a rule for the event-filter group: the selector must appear AND its block must
    # neutralize the float. We check the two facts robustly against the whitespace-stripped
    # text rather than parsing the cascade: the selector token is present, `float:none;` is
    # present, and a non-grid width/inline-display token is present.
    assert_includes css, '.pulse-webhook-event-filter',
                    'AC-02/DEF-02: redmine_pulse.css must define a rule targeting ' \
                    '.pulse-webhook-event-filter (the class is applied in the ERB but ' \
                    'currently UNDEFINED in CSS)'
    assert_match(/float:none;?/, css,
                 'AC-02/DEF-02: the event-filter group must neutralize the core float ' \
                 '(float:none) so the four checkbox labels no longer stack')
    assert_match(/width:auto;?|display:inline(?:-block)?;?/, css,
                 'AC-02/DEF-02: the grouped labels must drop the fixed grid width ' \
                 '(width:auto or display:inline*) so they lay out inline, not in the ' \
                 '~200px float column')

    # (b) fix-agnostic guard for the role-binding inline sub-labels: at least one
    # `float:none` declaration must be scoped to SOME `pulse-`-prefixed settings class, so
    # A9 must add a REAL neutralizing rule (not a no-op). We assert a `.pulse-...` selector
    # co-occurs with a float:none block. The event-filter rule above already satisfies this
    # weaker property, but we assert it explicitly so the intent is a standing falsifier:
    # a stylesheet whose ONLY float:none is unscoped (bare `label { float:none }`) fails.
    pulse_float_none = css.scan(/\.pulse-[a-z0-9-]+[^{}]*\{[^}]*float:none;?[^}]*\}/i)
    assert pulse_float_none.any?,
           'AC-02/FR-01: at least one float:none rule must be scoped to a pulse-prefixed ' \
           'settings class (the role-binding inline sub-labels), so the fix is real CSS ' \
           'and not a no-op / unscoped override'
  end

  # ── T-03 (INV-01 no-field-dropped regression guard) — STANDING (green before + after) ──
  # The presentation fix MUST NOT silently drop any load-bearing form field. Assert the
  # rendered settings form STILL contains every load-bearing input `name` so the POST stays
  # byte-identical across the fix. Falsifier: a fix that renames/removes any of these names
  # (breaking the byte-identical-POST invariant) fails this guard.
  def test_settings_form_retains_all_load_bearing_field_names
    require_render_lane!
    doc = render_settings_page

    # Role-binding pair inputs (the __new__ blank slot always renders): role_id + profile_id.
    assert doc.css('input[name*="[role_bindings_pairs]"][name$="[role_id]"]').any?,
           'INV-01: the role-binding role_id input must remain in the form'
    assert doc.css('input[name*="[role_bindings_pairs]"][name$="[profile_id]"]').any?,
           'INV-01: the role-binding profile_id input must remain in the form'

    # Webhook event_filter[] checkboxes for ALL FOUR event types (the blank __new__ endpoint
    # row always renders them), each an <input ... value="<event>">.
    %w[rag_transition dominant_change no_data_appeared score_delta].each do |et|
      assert doc.css("input[name$='[event_filter][]'][value='#{et}']").any?,
             "INV-01: the webhook event_filter checkbox for #{et} must remain in the form"
    end

    # The webhook endpoint editor fields (url/secret/enabled/ssrf_override/allow_http/
    # redaction) — the checkbox trio has a hidden `0` companion + the checkbox; assert both
    # url + secret text inputs and each toggle name is present at least once.
    assert doc.css("input[name$='[url]']").any?,
           'INV-01: the webhook endpoint url input must remain in the form'
    assert doc.css("input[name$='[secret]']").any?,
           'INV-01: the webhook endpoint secret input must remain in the form'
    %w[enabled ssrf_override allow_http redaction].each do |field|
      assert doc.css("input[name$='[#{field}]']").any?,
             "INV-01: the webhook endpoint #{field} control must remain in the form"
    end
  end
end
