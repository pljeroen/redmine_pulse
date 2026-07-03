# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# INV-READ-ONLY runtime complement (FC-02): no INSERT/UPDATE/DELETE on any Redmine
# domain table occurs during #metrics_for / fingerprint computation. RED until A9.
class ReadOnlyTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @user = create_user!(login: 'rouser')
    @role = create_role!(name: 'ROAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse view_changesets])
    @project = create_project!(name: 'RO', identifier: 'ro-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status)
    closed = create_issue!(project: @project, author: @user, status: open_status)
    add_close_journal!(issue: closed, user: @user, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 5, 1, 0))
    repo = create_repository!(@project)
    create_changeset!(repository: repo, committer: @user.login, committed_on: Time.utc(2026, 5, 2, 0))
    create_version!(project: @project, name: 'rov', effective_date: Date.new(2026, 9, 1))
  end

  def provider
    cfg = Pulse::Domain::ScoringConfig.new
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:settings_version_hash) { 'v0' }
    end.new
  end

  def test_metrics_for_performs_no_writes_on_redmine_tables
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    writes = capture_write_statements do
      ms.metrics_for(@user, project_ids: [@project.id])
    end
    assert_equal [], writes,
                 "no INSERT/UPDATE/DELETE on Redmine domain tables (got: #{writes.inspect})"
  end

  def test_metrics_for_does_not_change_row_counts
    ms = Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
    assert_no_difference ['Issue.count', 'Journal.count', 'IssueRelation.count',
                          'Version.count', 'Changeset.count', 'Project.count'] do
      ms.metrics_for(@user, project_ids: [@project.id])
    end
  end

  def test_fingerprint_and_context_perform_no_writes
    writes = capture_write_statements do
      Pulse::Adapters::VisibilityContext.new(@user, @project).id
      Pulse::Adapters::SnapshotFingerprint.new(@user, @project, settings_provider: provider).value
    end
    assert_equal [], writes, "fingerprint/context are read-only (got: #{writes.inspect})"
  end
end
