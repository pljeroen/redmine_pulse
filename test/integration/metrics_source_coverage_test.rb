# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# FC-C2-12 — RedmineMetricsSource populates open_issue_count / covered_sum from ONLY the
# OPEN issues VISIBLE to the requesting viewer, computing the three per-issue dimensions
# (has_estimate = estimated_hours present AND > 0; has_assignee = assigned_to non-nil;
# has_schedule = due_date OR fixed_version present). All READ-ONLY. Discharges FR-C2-02,
# FR-C2-03, AC-C2-04, AC-C2-06, INV-READ-ONLY, INV-VISIBILITY.
#
# HARNESS lane (RED-by-construction): needs the isolated Redmine harness (AR-over-fixtures).
# RED until A9 adds coverage_inputs(visible) to RedmineMetricsSource + the ProjectMetrics
# open_issue_count/covered_sum fields. Postgres-gated (COND-A8-004) as the sibling adapter
# integration tests are.
class MetricsSourceCoverageTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @admin = create_user!(login: 'covadmin', admin: true)
    @role  = create_role!(name: 'CovAll', issues_visibility: 'all',
                          permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'Cov', identifier: 'cov-proj')
    add_member!(project: @project, principal: @admin, role: @role)
  end

  def provider(settings_version: 'v0')
    cfg = Pulse::Domain::ScoringConfig.new
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:settings_version_hash) { settings_version }
      # A10-C2-003 remediation: coverage gathering runs ONLY when the provider says
      # coverage_gap is enabled (the adapter gate added by A9). All tests in this
      # file exercise the gathering path, so enable it here.
      define_method(:coverage_gap_enabled?) { true }
    end.new
  end

  def metrics_for(user, project)
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    ms.metrics_for(user, project_ids: [project.id]).first
  end

  # Set coverage-bearing attributes on an issue post-create (callback-free write).
  def stamp_coverage!(issue, estimated_hours: nil, due_date: nil, fixed_version_id: nil)
    cols = {}
    cols[:estimated_hours] = estimated_hours unless estimated_hours.nil?
    cols[:due_date] = due_date unless due_date.nil?
    cols[:fixed_version_id] = fixed_version_id unless fixed_version_id.nil?
    Issue.where(id: issue.id).update_all(cols) unless cols.empty?
    issue.reload
  end

  # --- (d) oic == 0 => [0, 0.0] (no open issues) --------------------------------------
  def test_no_open_issues_yields_zero_baseline
    m = metrics_for(@admin, @project)
    assert_equal 0, m.open_issue_count, 'no open issues => open_issue_count 0'
    assert_equal 0.0, m.covered_sum, 'no open issues => covered_sum 0.0'
  end

  # --- open_issue_count counts only OPEN issues; covered_sum aggregates the 3 dims -----
  def test_open_count_and_covered_sum_over_open_issues
    # Issue A: fully covered (estimate>0 + assignee + due_date) => fraction 1.0.
    a = create_issue!(project: @project, author: @admin, status: open_status, assigned_to: @admin)
    stamp_coverage!(a, estimated_hours: 4.0, due_date: Date.new(2026, 7, 1))
    # Issue B: fully UNcovered (no estimate, no assignee, no schedule) => fraction 0.0.
    create_issue!(project: @project, author: @admin, status: open_status)
    m = metrics_for(@admin, @project)
    assert_equal 2, m.open_issue_count, 'two open issues counted'
    # covered_sum = (est_count 1 + asgn_count 1 + sched_count 1)/3 == 1.0 (only A is covered).
    assert_in_delta 1.0, m.covered_sum, 1e-9,
                    'covered_sum aggregates the 3 dimension counts over open issues'
  end

  # --- (b) a CLOSED issue is EXCLUDED (open-scoped) ------------------------------------
  def test_closed_issue_excluded
    open_i = create_issue!(project: @project, author: @admin, status: open_status)
    closed_i = create_issue!(project: @project, author: @admin, status: open_status, assigned_to: @admin)
    stamp_coverage!(closed_i, estimated_hours: 8.0)
    closed_i.update_column(:status_id, closed_status.id)
    m = metrics_for(@admin, @project)
    assert_equal 1, m.open_issue_count, 'only the OPEN issue is counted (closed excluded)'
    # Only the open (uncovered) issue counts => covered_sum 0.0.
    assert_in_delta 0.0, m.covered_sum, 1e-9, 'closed issue does not contribute to coverage'
    open_i.reload
  end

  # --- (a) AC-C2-06: an OPEN issue INVISIBLE to the viewer is EXCLUDED -----------------
  def test_invisible_open_issue_excluded
    # A private issue that the LIMITED viewer cannot see must not enter oic or any dim count.
    limited_role = create_role!(name: 'CovOwn', issues_visibility: 'own',
                                permissions: %i[view_issues view_pulse])
    viewer = create_user!(login: 'covviewer')
    add_member!(project: @project, principal: viewer, role: limited_role)

    # Visible to viewer: an open issue authored by viewer.
    create_issue!(project: @project, author: viewer, status: open_status)
    # Invisible to viewer: a private issue authored+assigned to the admin (own-only viewer
    # cannot see it), fully covered — must NOT leak into the viewer's counts.
    hidden = create_issue!(project: @project, author: @admin, status: open_status,
                           assigned_to: @admin, is_private: true)
    stamp_coverage!(hidden, estimated_hours: 6.0, due_date: Date.new(2026, 7, 1))

    m = metrics_for(viewer, @project)
    assert_equal 1, m.open_issue_count,
                 'the invisible private issue is excluded from open_issue_count (AC-C2-06)'
    assert_in_delta 0.0, m.covered_sum, 1e-9,
                    'the invisible covered issue does not leak into covered_sum (INV-VISIBILITY)'
  end

  # --- (c) has_estimate: estimated_hours == 0 counts as NOT covered (AA-01) ------------
  def test_zero_estimate_is_not_has_estimate
    i = create_issue!(project: @project, author: @admin, status: open_status)
    stamp_coverage!(i, estimated_hours: 0.0) # 0 => NOT has_estimate
    m = metrics_for(@admin, @project)
    assert_equal 1, m.open_issue_count
    assert_in_delta 0.0, m.covered_sum, 1e-9,
                    'estimated_hours == 0 does NOT satisfy has_estimate (AA-01)'
  end

  # --- (c) AC-C2-04: fixed_version WITHOUT due_date counts as has_schedule -------------
  def test_fixed_version_without_due_date_is_has_schedule
    version = create_version!(project: @project, name: 'v1')
    i = create_issue!(project: @project, author: @admin, status: open_status)
    stamp_coverage!(i, fixed_version_id: version.id) # version present, no due_date
    m = metrics_for(@admin, @project)
    assert_equal 1, m.open_issue_count
    # Only has_schedule is satisfied => fraction 1/3 => covered_sum (0+0+1)/3.
    assert_in_delta 1.0 / 3.0, m.covered_sum, 1e-9,
                    'fixed_version alone satisfies has_schedule (AC-C2-04)'
  end

  def test_due_date_without_fixed_version_is_has_schedule
    i = create_issue!(project: @project, author: @admin, status: open_status)
    stamp_coverage!(i, due_date: Date.new(2026, 8, 1)) # due_date present, no version
    m = metrics_for(@admin, @project)
    assert_in_delta 1.0 / 3.0, m.covered_sum, 1e-9,
                    'due_date alone satisfies has_schedule (AC-C2-04)'
  end

  # --- (e) INV-READ-ONLY: gathering coverage writes NO Redmine row --------------------
  def test_coverage_gathering_is_read_only
    create_issue!(project: @project, author: @admin, status: open_status, assigned_to: @admin)
    counts_before = {
      issues: Issue.count, journals: Journal.count, versions: Version.count
    }
    metrics_for(@admin, @project)
    assert_equal counts_before[:issues], Issue.count, 'no Issue row written during coverage gathering'
    assert_equal counts_before[:journals], Journal.count, 'no Journal row written'
    assert_equal counts_before[:versions], Version.count, 'no Version row written'
  end
end
