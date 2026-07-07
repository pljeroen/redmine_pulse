# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Aggregate-derivation correctness for RedmineMetricsSource against KNOWN fixture
# data. Runs on PostgreSQL (the production engine).
#
# Adapter API exercised here:
#   ms = Pulse::Adapters::RedmineMetricsSource.new(
#          settings_provider: <SettingsProvider>, clock: <Clock>)
#   ms.metrics_for(user, project_ids: [id]) -> Array<Pulse::Domain::ProjectMetrics>
#     ordered by project_id asc.
class MetricsSourceAggregationTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @admin = create_user!(login: 'pulseadmin', admin: true)
    @role  = create_role!(name: 'PulseAll', issues_visibility: 'all',
                          permissions: %i[view_issues view_pulse view_changesets browse_repository])
    @project = create_project!(name: 'Agg', identifier: 'agg-proj')
    add_member!(project: @project, principal: @admin, role: @role)
  end

  # A default settings provider (no effort/risk/blocked mappings) unless overridden.
  def provider(scoring_config: nil, settings_version: 'v0')
    cfg = scoring_config || Pulse::Domain::ScoringConfig.new
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:settings_version_hash) { settings_version }
    end.new
  end

  def metrics_for(project, settings_provider: provider)
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: settings_provider, clock: @clock)
    ms.metrics_for(@admin, project_ids: [project.id]).first
  end

  # --- reference_date = max of three branches + fallback --------

  def test_reference_date_is_max_of_issue_updated_on
    # Control project.created_on to a PAST date so issue.updated_on is the max (TD-001).
    @project.update_column(:created_on, Time.utc(2026, 1, 1, 0))
    create_issue!(project: @project, author: @admin, subject: 'old',
                  updated_on: Time.utc(2026, 1, 1, 12))
    create_issue!(project: @project, author: @admin, subject: 'new',
                  updated_on: Time.utc(2026, 5, 10, 12))
    m = metrics_for(@project)
    assert_instance_of Date, m.reference_date
    assert_equal Date.new(2026, 5, 10), m.reference_date
  end

  def test_reference_date_reflects_changeset_when_newer_than_issues
    # Control project.created_on to a PAST date so changeset.committed_on is the max (TD-001).
    @project.update_column(:created_on, Time.utc(2026, 1, 1, 0))
    create_issue!(project: @project, author: @admin, updated_on: Time.utc(2026, 2, 1, 12))
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 4, 15, 9))
    m = metrics_for(@project)
    assert_equal Date.new(2026, 4, 15), m.reference_date
  end

  def test_reference_date_falls_back_to_project_created_on_when_empty
    @project.update_column(:created_on, Time.utc(2026, 3, 3, 0))
    m = metrics_for(@project)
    assert_instance_of Date, m.reference_date
    assert_equal Date.new(2026, 3, 3), m.reference_date
  end

  # project.created_on is a FULL max participant, not a
  # fallback. A freshly-created project (created_on NEWER than its latest visible
  # issue.updated_on AND latest visible changeset.committed_on) is FRESH:
  #   reference_date == max(issue.updated_on, changeset.committed_on, created_on)
  #                  == project.created_on.
  def test_reference_date_uses_created_on_when_newest_of_all_three
    # project created AFTER all issue/changeset activity.
    @project.update_column(:created_on, Time.utc(2026, 6, 10, 0))
    create_issue!(project: @project, author: @admin, updated_on: Time.utc(2026, 5, 1, 12))
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 5, 20, 9))
    m = metrics_for(@project) # @admin has view_changesets
    assert_instance_of Date, m.reference_date
    assert_equal Date.new(2026, 6, 10), m.reference_date,
                 'created_on is a full max() participant: a fresh project reads as fresh'
  end

  # --- changeset needs :view_changesets, NOT :browse_repository -

  def test_changeset_excluded_for_browse_repository_only_user
    # Control project.created_on to a PAST date so the issue date is the max (TD-001).
    @project.update_column(:created_on, Time.utc(2026, 1, 1, 0))
    issue_date = Time.utc(2026, 2, 1, 12)
    create_issue!(project: @project, author: @admin, updated_on: issue_date)
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 5, 1, 9))

    browser = create_user!(login: 'browseronly')
    browse_role = create_role!(name: 'BrowseOnly', issues_visibility: 'all',
                               permissions: %i[view_issues view_pulse browse_repository])
    add_member!(project: @project, principal: browser, role: browse_role)

    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    m = ms.metrics_for(browser, project_ids: [@project.id]).first
    # No :view_changesets -> changeset date excluded -> reference_date is the issue date.
    assert_equal Date.new(2026, 2, 1), m.reference_date
  end

  def test_changeset_included_for_view_changesets_user
    # Control project.created_on to a PAST date so changeset.committed_on is the max (TD-001).
    @project.update_column(:created_on, Time.utc(2026, 1, 1, 0))
    create_issue!(project: @project, author: @admin, updated_on: Time.utc(2026, 2, 1, 12))
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 5, 1, 9))
    m = metrics_for(@project) # @admin's role has view_changesets
    assert_equal Date.new(2026, 5, 1), m.reference_date
  end

  # --- effort sum from numeric field -----------------------------

  def test_effort_sum_from_numeric_field_open_and_total
    field = numeric_custom_field!(name: 'StoryPoints', format: 'int')
    @project.trackers.each { |t| t.custom_fields << field unless t.custom_fields.include?(field) }
    o1 = create_issue!(project: @project, author: @admin, status: open_status)
    o2 = create_issue!(project: @project, author: @admin, status: open_status)
    c1 = create_issue!(project: @project, author: @admin, status: closed_status)
    set_custom_value!(issue: o1, field: field, value: '3')
    set_custom_value!(issue: o2, field: field, value: '5')
    set_custom_value!(issue: c1, field: field, value: '8')

    cfg = Pulse::Domain::ScoringConfig.new
    sp = provider(scoring_config: cfg)
    sp.define_singleton_method(:effort_mapped?) { true }
    sp.define_singleton_method(:effort_custom_field_id) { field.id }

    m = metrics_for(@project, settings_provider: sp)
    assert_equal true, m.effort_mapped, 'numeric effort field -> effort_mapped true'
    assert_equal 16, m.effort_total, 'total over all visible issues (3+5+8)'
    assert_equal 8, m.effort_open, 'open over visible open issues (3+5)'
  end

  # --- per-issue NULL/blank/unparseable = 0 (not excluded) -----

  def test_effort_per_issue_null_blank_unparseable_count_as_zero
    field = numeric_custom_field!(name: 'SP2', format: 'int')
    @project.trackers.each { |t| t.custom_fields << field unless t.custom_fields.include?(field) }
    valid = create_issue!(project: @project, author: @admin, status: open_status)
    set_custom_value!(issue: valid, field: field, value: '4')
    create_issue!(project: @project, author: @admin, status: open_status) # no CustomValue -> 0
    blank = create_issue!(project: @project, author: @admin, status: open_status)
    set_custom_value!(issue: blank, field: field, value: '') # blank -> 0

    sp = provider
    sp.define_singleton_method(:effort_mapped?) { true }
    sp.define_singleton_method(:effort_custom_field_id) { field.id }

    m = metrics_for(@project, settings_provider: sp)
    # 3 visible open issues, only one contributes 4: NULL/blank are 0, not excluded.
    assert_equal 4, m.effort_open
    assert_equal 4, m.effort_total
  end

  # --- count fallback when unmapped + empty boundary -------------

  def test_effort_count_fallback_when_unmapped
    create_issue!(project: @project, author: @admin, status: open_status)
    create_issue!(project: @project, author: @admin, status: open_status)
    create_issue!(project: @project, author: @admin, status: closed_status)
    m = metrics_for(@project) # default provider: effort unmapped
    assert_equal false, m.effort_mapped
    assert_equal 3, m.effort_total, 'count(visible)'
    assert_equal 2, m.effort_open, 'count(visible open)'
  end

  def test_effort_total_zero_on_empty_project
    m = metrics_for(@project)
    assert_equal 0, m.effort_total
    assert_equal 0, m.effort_open
    assert_equal false, m.effort_mapped
  end

  # --- risk_raw = Σ priority.position over visible OPEN risk-tracker

  def test_risk_raw_sum_of_priority_positions_visible_open_only
    risk_tracker = tracker_for(@project)
    priorities = IssuePriority.order(:position).to_a
    skip 'need >=2 priorities' if priorities.size < 2
    lo, hi = priorities[0], priorities[1]
    create_issue!(project: @project, author: @admin, tracker: risk_tracker,
                  status: open_status, priority: lo)
    create_issue!(project: @project, author: @admin, tracker: risk_tracker,
                  status: open_status, priority: hi)
    create_issue!(project: @project, author: @admin, tracker: risk_tracker,
                  status: closed_status, priority: hi) # closed -> excluded

    sp = provider
    sp.define_singleton_method(:risk_mapped?) { true }
    sp.define_singleton_method(:risk_tracker_ids) { [risk_tracker.id] }

    m = metrics_for(@project, settings_provider: sp)
    assert_equal true, m.risk_mapped
    assert_equal (lo.position + hi.position), m.risk_raw,
                 'sum of positions over visible OPEN risk-tracker issues'
  end

  # --- no risk tracker -> risk_raw 0, risk_mapped false ----------

  def test_risk_unmapped_degrades_to_zero
    create_issue!(project: @project, author: @admin, status: open_status)
    m = metrics_for(@project)
    assert_equal 0, m.risk_raw
    assert_equal false, m.risk_mapped
  end

  # --- blocked_count relation + status, OR, once ---------

  def test_blocked_count_relation_rule_both_endpoints_visible
    blocked = create_issue!(project: @project, author: @admin, status: open_status)
    blocker = create_issue!(project: @project, author: @admin, status: open_status)
    add_blocks_relation!(blocker: blocker, blocked: blocked)
    m = metrics_for(@project)
    assert_equal 1, m.blocked_count
  end

  # the status rule applies to visible OPEN issues ONLY.
  # (a) a visible OPEN issue whose status_id == configured blocked_status_id -> counted.
  # EXACT value.
  def test_blocked_count_status_rule_counts_open_issue_by_id
    blocked_status = open_status # configured blocked status, matched by integer id
    create_issue!(project: @project, author: @admin, status: open_status)

    sp = provider
    sp.define_singleton_method(:blocked_status_id) { blocked_status.id }
    m = metrics_for(@project, settings_provider: sp)
    assert_equal 1, m.blocked_count,
                 'exactly one visible OPEN issue carries the configured blocked status'
  end

  # (b) a visible CLOSED issue whose status_id == configured blocked_status_id MUST NOT
  # be counted: blocked_count is over visible OPEN issues only. This is the
  # This exercises the status branch, which must select from the full
  # visible set, counting the closed issue). EXACT value 0.
  def test_blocked_count_status_rule_excludes_closed_issue
    blocked_status = closed_status # configured blocked status is itself a CLOSED status
    create_issue!(project: @project, author: @admin, status: closed_status) # carries it, closed
    create_issue!(project: @project, author: @admin, status: open_status)    # open, does not carry it

    sp = provider
    sp.define_singleton_method(:blocked_status_id) { blocked_status.id }
    m = metrics_for(@project, settings_provider: sp)
    assert_equal 0, m.blocked_count,
                 'a CLOSED issue with the configured blocked status is excluded (open-only rule)'
  end

  def test_blocked_relation_and_status_counted_once
    blocked = create_issue!(project: @project, author: @admin, status: open_status)
    blocker = create_issue!(project: @project, author: @admin, status: open_status)
    add_blocks_relation!(blocker: blocker, blocked: blocked)
    # `blocked` satisfies BOTH the relation rule AND the status rule (its own open status
    # is the configured blocked status). It MUST be counted exactly once (OR-combined).
    sp = provider
    sp.define_singleton_method(:blocked_status_id) { blocked.status_id }
    m = metrics_for(@project, settings_provider: sp)
    assert_equal 1, m.blocked_count, 'an issue satisfying both rules is counted exactly once'
  end

  # --- event_series tz-normalized + shape -----------------------

  def test_event_series_dates_normalized_to_instance_timezone
    Setting.default_language = 'en'
    with_time_zone('Pacific/Kiritimati') do # UTC+14; a day-boundary stressor
      # created_on 2026-05-01 11:00 UTC -> 2026-05-02 in UTC+14
      create_issue!(project: @project, author: @admin,
                    created_on: Time.utc(2026, 5, 1, 11), updated_on: Time.utc(2026, 5, 1, 11))
      m = metrics_for(@project)
      created = m.event_series.select { |e| e[:type] == :issue_created }
      assert_equal 1, created.size
      assert_instance_of Date, created.first[:date]
      assert_equal Date.new(2026, 5, 2), created.first[:date],
                   'date normalized via in_time_zone(instance_tz).to_date, not UTC date'
    end
  end

  # momentum-broaden: event_series now also emits :issue_commented (issue journals in
  # the activity window) and :commit (changesets in the window). The allowed-type set is
  # broadened to the four canonical event types.
  ALLOWED_EVENT_TYPES = %i[issue_created issue_closed issue_commented commit].freeze

  def test_event_series_only_allowed_symbol_types
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 1, 0))
    m = metrics_for(@project)
    m.event_series.each do |e|
      assert_includes ALLOWED_EVENT_TYPES, e[:type]
      assert_instance_of Date, e[:date]
    end
  end

  # Append a NON-status comment journal (notes only) timestamped at `at`. Every
  # journal whose created_on (local date) is within the activity window counts as an
  # :issue_commented activity event.
  def add_comment_journal!(issue:, user:, at:, notes: 'a comment')
    j = Journal.new(journalized: issue, user: user, notes: notes)
    j.save!
    j.update_column(:created_on, at)
    j
  end

  # --- momentum-broaden: :issue_commented from in-window journals --------------

  def test_event_series_emits_issue_commented_for_in_window_journal
    # @clock.today is 2026-06-20; default activity_window_days 30 => window [2026-05-21, today).
    issue = create_issue!(project: @project, author: @admin, status: open_status,
                          created_on: Time.utc(2026, 1, 1, 0)) # created BEFORE window
    add_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 6, 10, 12)) # in-window
    m = metrics_for(@project)
    commented = m.event_series.select { |e| e[:type] == :issue_commented }
    assert_equal 1, commented.size, 'a journal created_on inside the window emits one :issue_commented'
    assert_instance_of Date, commented.first[:date]
    assert_equal Date.new(2026, 6, 10), commented.first[:date]
  end

  def test_event_series_omits_issue_commented_for_out_of_window_journal
    issue = create_issue!(project: @project, author: @admin, status: open_status,
                          created_on: Time.utc(2026, 1, 1, 0))
    add_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 1, 15, 12)) # FAR before window
    m = metrics_for(@project)
    assert_equal 0, m.event_series.count { |e| e[:type] == :issue_commented },
                 'a journal outside the activity window emits NO :issue_commented (window-bounded payload)'
  end

  # Append an in-window PRIVATE-notes journal (private_notes = true) timestamped at `at`.
  def add_private_comment_journal!(issue:, user:, at:, notes: 'a private comment')
    j = Journal.new(journalized: issue, user: user, notes: notes, private_notes: true)
    j.save!
    j.update_column(:created_on, at)
    j
  end

  # --- permission-safe: :issue_commented private-notes permission gate ---
  # A journal whose notes are PRIVATE (private_notes = true) is counted as
  # :issue_commented ONLY when the requester has :view_private_notes on the issue's
  # project; otherwise it is EXCLUDED (symmetric with the :commit gate). A
  # non-privileged user must not be able to infer private-note activity timing via
  # momentum/health. Non-private journals are always counted (subject to issue
  # visibility + window).
  def test_issue_commented_private_note_excluded_for_user_without_view_private_notes
    # @clock.today is 2026-06-20; default activity_window_days 30 => window [2026-05-21, today).
    issue = create_issue!(project: @project, author: @admin, status: open_status,
                          created_on: Time.utc(2026, 1, 1, 0)) # created BEFORE window
    # (a) a normal in-window journal — always visible/counted.
    add_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 6, 10, 12))
    # (b) an in-window PRIVATE-notes journal authored by the admin.
    add_private_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 6, 11, 12))

    # A requester WITHOUT :view_private_notes: issues visible (issues_visibility all,
    # view_pulse), but cannot see the private note.
    viewer = create_user!(login: 'noprivnotes')
    role = create_role!(name: 'NoPrivNotes', issues_visibility: 'all',
                        permissions: %i[view_issues view_pulse])
    add_member!(project: @project, principal: viewer, role: role)

    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    m = ms.metrics_for(viewer, project_ids: [@project.id]).first
    commented = m.event_series.select { |e| e[:type] == :issue_commented }
    assert_equal 1, commented.size,
                 'a user without :view_private_notes counts only the non-private in-window journal'
    assert_equal [Date.new(2026, 6, 10)], commented.map { |e| e[:date] },
                 'the private-notes journal date must NOT leak into the series'
  end

  def test_issue_commented_private_note_counted_for_user_with_view_private_notes
    issue = create_issue!(project: @project, author: @admin, status: open_status,
                          created_on: Time.utc(2026, 1, 1, 0))
    add_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 6, 10, 12))         # non-private
    add_private_comment_journal!(issue: issue, user: @admin, at: Time.utc(2026, 6, 11, 12)) # private

    # A requester WITH :view_private_notes sees BOTH journals.
    viewer = create_user!(login: 'hasprivnotes')
    role = create_role!(name: 'HasPrivNotes', issues_visibility: 'all',
                        permissions: %i[view_issues view_pulse view_private_notes])
    add_member!(project: @project, principal: viewer, role: role)

    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    m = ms.metrics_for(viewer, project_ids: [@project.id]).first
    commented = m.event_series.select { |e| e[:type] == :issue_commented }
    assert_equal 2, commented.size,
                 'a user WITH :view_private_notes counts both the non-private and the private journal'
    assert_equal [Date.new(2026, 6, 10), Date.new(2026, 6, 11)], commented.map { |e| e[:date] }.sort
  end

  def test_issue_commented_private_note_counted_for_admin
    issue = create_issue!(project: @project, author: @admin, status: open_status,
                          created_on: Time.utc(2026, 1, 1, 0))
    # author is a third party so the admin is not the journal's own user (tests the
    # permission path, not the own-author path).
    third = create_user!(login: 'thirdcommenter')
    add_member!(project: @project, principal: third, role: @role)
    add_private_comment_journal!(issue: issue, user: third, at: Time.utc(2026, 6, 11, 12))

    m = metrics_for(@project) # @admin is admin -> allowed_to? anything
    assert_equal 1, m.event_series.count { |e| e[:type] == :issue_commented },
                 'an admin (allowed :view_private_notes) counts the private-notes journal'
  end

  # --- momentum-broaden: :commit from in-window changesets, gated + fallback ---

  def test_event_series_emits_commit_for_in_window_changeset
    @project.enabled_module_names = (@project.enabled_module_names + %w[repository]).uniq
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 6, 12, 9)) # in-window
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 1, 5, 9))  # out-of-window -> ignored
    m = metrics_for(@project) # @admin has view_changesets + repository module
    commits = m.event_series.select { |e| e[:type] == :commit }
    assert_equal 1, commits.size, 'only the in-window changeset emits a :commit event'
    assert_equal Date.new(2026, 6, 12), commits.first[:date]
  end

  # ── commit_changesets counts ONLY in-window changesets ──
  # CHARACTERIZATION guard for a perf refactor that pushes the activity-window filter into
  # SQL (currently commit_changesets plucks ALL changesets and filters in Ruby; the refactor
  # windows in the query). This test pins the observable behavior — the :commit events reflect
  # ONLY changesets whose committed_on is inside [today - activity_window_days, today) — so it
  # passes BOTH before and after that refactor. The window source is the injected scoring
  # config's activity_window_days (@clock.today is the upper bound). Uses a NON-default window
  # so the boundary is unambiguously exercised, not incidentally satisfied by the default 30.
  def test_commit_events_reflect_only_in_window_changesets_per_activity_window
    # @clock.today = 2026-06-20. Custom activity_window_days = 10 => window [2026-06-10, 2026-06-20).
    cfg = Pulse::Domain::ScoringConfig.new(activity_window_days: 10)
    sp = provider(scoring_config: cfg)

    @project.enabled_module_names = (@project.enabled_module_names + %w[repository]).uniq
    repo = create_repository!(@project)
    # In-window (inside [2026-06-10, 2026-06-20)):
    create_changeset!(repository: repo, committer: @admin.login, committed_on: Time.utc(2026, 6, 12, 9))
    create_changeset!(repository: repo, committer: @admin.login, committed_on: Time.utc(2026, 6, 19, 9))
    # Out-of-window on BOTH sides:
    create_changeset!(repository: repo, committer: @admin.login, committed_on: Time.utc(2026, 6,  9, 9)) # before start
    create_changeset!(repository: repo, committer: @admin.login, committed_on: Time.utc(2026, 6, 20, 9)) # == today (excluded, half-open upper)
    create_changeset!(repository: repo, committer: @admin.login, committed_on: Time.utc(2026, 1, 1, 9))  # far before

    m = metrics_for(@project, settings_provider: sp) # @admin has view_changesets + repository
    commits = m.event_series.select { |e| e[:type] == :commit }
    assert_equal 2, commits.size,
                 'only the two in-window changesets ([today-activity_window_days, today)) ' \
                 'produce :commit events; out-of-window commits are excluded'
    assert_equal [Date.new(2026, 6, 12), Date.new(2026, 6, 19)], commits.map { |e| e[:date] }.sort,
                 'the :commit dates are exactly the in-window changeset committed_on dates'
  end

  def test_event_series_commit_gated_on_view_changesets_permission
    @project.enabled_module_names = (@project.enabled_module_names + %w[repository]).uniq
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @admin.login,
                      committed_on: Time.utc(2026, 6, 12, 9))
    # A user WITHOUT view_changesets must get NO :commit events (same gate as
    # latest_changeset_committed_on): graceful fallback to none.
    browser = create_user!(login: 'commitbrowse')
    browse_role = create_role!(name: 'CommitBrowse', issues_visibility: 'all',
                               permissions: %i[view_issues view_pulse browse_repository])
    add_member!(project: @project, principal: browser, role: browse_role)
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    m = ms.metrics_for(browser, project_ids: [@project.id]).first
    assert_equal 0, m.event_series.count { |e| e[:type] == :commit },
                 'no :view_changesets => no :commit events (gated, like the changeset reference_date branch)'
  end

  def test_event_series_commit_graceful_fallback_when_no_repository
    # No repository module / no repo => :commit events simply absent (no crash, fallback none).
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 6, 12, 0))
    m = metrics_for(@project)
    assert_equal 0, m.event_series.count { |e| e[:type] == :commit },
                 'no repository => no :commit events (graceful fallback to none)'
  end

  # --- momentum-broaden: stable defined order with the broadened type_rank ----
  # type_rank = { issue_created: 0, issue_closed: 1, issue_commented: 2, commit: 3 }.
  # Same-date events sort by that rank; the public series stays in [date, type_rank, ...] order.
  def test_event_series_stable_order_with_broadened_type_rank
    @project.enabled_module_names = (@project.enabled_module_names + %w[repository]).uniq
    repo = create_repository!(@project)
    same = Time.utc(2026, 6, 12, 9)
    # An issue created and closed on the same in-window date, plus a comment + a commit that
    # date — exercising all four ranks on one date.
    i = create_issue!(project: @project, author: @admin, status: open_status, created_on: same)
    add_close_journal!(issue: i, user: @admin, from_status: open_status,
                       to_status: closed_status, at: same)
    add_comment_journal!(issue: i, user: @admin, at: same)
    create_changeset!(repository: repo, committer: @admin.login, committed_on: same)

    m = metrics_for(@project)
    on_date = m.event_series.select { |e| e[:date] == Date.new(2026, 6, 12) }
    rank = { issue_created: 0, issue_closed: 1, issue_commented: 2, commit: 3 }
    ranks = on_date.map { |e| rank[e[:type]] }
    assert_equal ranks.sort, ranks,
                 'same-date events must be in type_rank order [created<closed<commented<commit]'
    assert_includes on_date.map { |e| e[:type] }, :commit, 'the in-window commit is present on that date'
    assert_includes on_date.map { |e| e[:type] }, :issue_commented, 'the in-window comment is present'
  end

  # --- closing-event classification golden ----------------------

  def test_issue_created_event_per_visible_issue
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 1, 0))
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 2, 0))
    m = metrics_for(@project)
    assert_equal 2, m.event_series.count { |e| e[:type] == :issue_created }
  end

  def test_close_transition_emits_one_issue_closed
    i = create_issue!(project: @project, author: @admin, status: open_status,
                      created_on: Time.utc(2026, 5, 1, 0))
    add_close_journal!(issue: i, user: @admin, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 5, 10, 0))
    m = metrics_for(@project)
    closed = m.event_series.select { |e| e[:type] == :issue_closed }
    assert_equal 1, closed.size
    assert_equal Date.new(2026, 5, 10), closed.first[:date]
  end

  def test_created_directly_in_closed_status_emits_issue_closed
    create_issue!(project: @project, author: @admin, status: closed_status,
                  created_on: Time.utc(2026, 5, 4, 0))
    m = metrics_for(@project)
    assert_equal 1, m.event_series.count { |e| e[:type] == :issue_closed }
  end

  def test_reopen_then_reclose_emits_one_closed_per_reclose
    i = create_issue!(project: @project, author: @admin, status: open_status,
                      created_on: Time.utc(2026, 5, 1, 0))
    add_close_journal!(issue: i, user: @admin, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 5, 5, 0))
    add_close_journal!(issue: i, user: @admin, from_status: closed_status,
                       to_status: open_status, at: Time.utc(2026, 5, 6, 0)) # reopen -> no event
    add_close_journal!(issue: i, user: @admin, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 5, 7, 0)) # reclose -> 1 event
    m = metrics_for(@project)
    assert_equal 2, m.event_series.count { |e| e[:type] == :issue_closed },
                 'created-as-open + two closes => exactly two close events'
  end

  # --- retention horizon >= 60d --------------------------------

  def test_event_series_covers_at_least_60_day_horizon
    today = @clock.today
    [-10, -45, -59].each do |d|
      create_issue!(project: @project, author: @admin,
                    created_on: (today + d).to_time(:utc))
    end
    m = metrics_for(@project)
    within = m.event_series.select do |e|
      e[:type] == :issue_created && e[:date] >= today - 60
    end
    assert within.size >= 3, 'all within-60d created events present (adapter does not pre-filter window)'
  end

  # --- event_series determinism + stable defined order -----

  # Repeated invocations over fixed state MUST produce deeply-equal ProjectMetrics
  # event_series uses SQL row order with no ORDER BY unless it sorts, which is not
  # deterministic.
  def test_metrics_for_is_deterministic_across_invocations
    # Insertion order deliberately differs from date order.
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 20, 0))
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 1, 0))
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 10, 0))

    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    a = ms.metrics_for(@admin, project_ids: [@project.id]).first
    b = ms.metrics_for(@admin, project_ids: [@project.id]).first

    assert_equal a.event_series, b.event_series,
                 'event_series must be deeply equal across repeated invocations'
    assert_equal a.version_due_dates, b.version_due_dates
    assert_equal a.reference_date, b.reference_date
    assert_equal a.effort_open, b.effort_open
    assert_equal a.effort_total, b.effort_total
    assert_equal a.blocked_count, b.blocked_count
  end

  # event_series ordering MUST be a stable, defined order independent of the DB row
  # order in which the issues were inserted. The defined order is ascending
  # by [date, type]; with insertion order scrambled relative to date, the emitted
  # series MUST still be sorted (guards against an unsorted SQL row order with no ORDER BY).
  def test_event_series_has_stable_defined_order_independent_of_db_order
    # Insertion order: 20th, 1st, 10th (NOT chronological).
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 20, 0))
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 1, 0))
    create_issue!(project: @project, author: @admin, created_on: Time.utc(2026, 5, 10, 0))

    m = metrics_for(@project)
    created = m.event_series.select { |e| e[:type] == :issue_created }
    dates = created.map { |e| e[:date] }
    assert_equal dates.sort, dates,
                 'event_series must be in a stable [date,type] order, not raw DB row order'
    assert_equal [Date.new(2026, 5, 1), Date.new(2026, 5, 10), Date.new(2026, 5, 20)], dates
  end

  # --- version_due_dates plain Date, empty when none ------------

  def test_version_due_dates_are_plain_dates
    create_version!(project: @project, name: 'v1', effective_date: Date.new(2026, 9, 1))
    create_version!(project: @project, name: 'v-nodate', effective_date: nil)
    m = metrics_for(@project)
    assert_equal 1, m.version_due_dates.size, 'version with NULL effective_date excluded'
    entry = m.version_due_dates.first
    assert_instance_of Date, entry[:due_date]
    assert_kind_of Integer, entry[:version_id]
    assert_equal Date.new(2026, 9, 1), entry[:due_date]
    # the adapter populates :name from Version#name.
    # RedmineMetricsSource#version_due_dates must pluck :name.
    assert_kind_of String, entry[:name], 'adapter must populate entry[:name] from Version#name'
    refute_empty entry[:name], 'version name is a non-empty String (Version#name is non-nullable)'
    assert_equal 'v1', entry[:name], 'name passed through from the Version'
  end

  def test_version_due_dates_empty_array_when_none
    m = metrics_for(@project)
    assert_equal [], m.version_due_dates
  end

  # --- ProjectMetrics field shape, frozen, no AR ----------------

  def test_project_metrics_field_shape_frozen_no_activerecord
    create_issue!(project: @project, author: @admin)
    m = metrics_for(@project)
    assert_instance_of Pulse::Domain::ProjectMetrics, m
    assert m.frozen?, 'ProjectMetrics must be frozen'
    assert_kind_of Integer, m.project_id
    assert_equal @project.id, m.project_id
    refute m.reference_date.is_a?(ActiveRecord::Base)
    m.event_series.each do |e|
      refute e[:date].is_a?(ActiveRecord::Base)
      assert_instance_of Date, e[:date]
      assert_kind_of Symbol, e[:type]
    end
    m.version_due_dates.each do |v|
      assert_kind_of Integer, v[:version_id]
      assert_instance_of Date, v[:due_date]
      # each entry carries a non-empty String :name (adapter-populated).
      assert_kind_of String, v[:name]
      refute_empty v[:name]
    end
  end

  # --- result ordered by project_id ascending -------------------

  def test_result_ordered_by_project_id_asc
    p2 = create_project!(name: 'Agg2', identifier: 'agg-proj-2')
    add_member!(project: p2, principal: @admin, role: @role)
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    result = ms.metrics_for(@admin, project_ids: [p2.id, @project.id])
    ids = result.map(&:project_id)
    assert_equal ids.sort, ids, 'Array<ProjectMetrics> ordered project_id ascending'
  end

  private

  def with_time_zone(zone)
    old = Time.zone
    Time.zone = zone
    yield
  ensure
    Time.zone = old
  end
end
