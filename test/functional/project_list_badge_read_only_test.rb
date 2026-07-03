# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# project-list-badge contract — PLB-13-READONLY (INV-READONLY / FR-PLB-13).
# The view hook emits only HTML tag strings (read) and the new shared label / serializer
# path performs NO write on any Redmine domain table. Mirrors test/functional/
# read_only_test.rb's write-capture mechanism (capture_write_statements): zero
# INSERT/UPDATE/DELETE on a Redmine domain table across a hook emission.
#
# pulse_snapshots is the plugin-owned cache table the warm path is permitted to write
# (FC-CA-11) — the guard set (REDMINE_DOMAIN_TABLES) deliberately EXCLUDES it; this test
# asserts no REDMINE DOMAIN write, exactly as read_only_test.rb does.
#
# RED until A9 writes lib/redmine_pulse/hooks.rb (RedminePulseHooks ABSENT -> NameError).
class ProjectListBadgeReadOnlyTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  HEAD_HOOK = :view_layouts_base_html_head

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'BadgeRO', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'badgerouser')
    @project = create_project!(name: 'BadgeRO', identifier: 'badge-ro')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    # Pre-warm the snapshot cache so the hook emission under capture is a pure cache READ
    # (the warm path writes only pulse_snapshots, which is NOT a Redmine domain table —
    # but pre-warming makes the assertion unambiguous: zero writes of ANY kind below).
    prime_cache!
  end

  def prime_cache!
    prior = User.current
    User.current = @user
    engine = Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: Pulse::Adapters::RedmineMetricsSource.new(
        settings_provider: Pulse::Adapters::RedmineSettingsProvider.new,
        clock: Pulse::Adapters::SystemClock.new
      ),
      store: Pulse::Adapters::ActiveRecordSnapshotStore.new,
      settings_provider: Pulse::Adapters::RedmineSettingsProvider.new,
      clock: Pulse::Adapters::SystemClock.new
    )
    engine.portfolio_projections(@user)
  ensure
    User.current = prior || User.anonymous
  end

  def hook_context
    ctrl = Struct.new(:controller_name, :action_name).new('projects', 'index')
    { controller: ctrl, controller_name: 'projects', action_name: 'index',
      project: nil, request: ActionDispatch::TestRequest.create, hook_caller: ctrl }
  end

  def test_hook_emission_performs_no_redmine_domain_write
    prior = User.current
    User.current = @user
    writes = capture_write_statements do
      RedminePulseHooks.instance.public_send(HEAD_HOOK, hook_context)
    end
    assert_equal [], writes,
                 "INV-READONLY: the badge hook emission MUST write NO Redmine domain table " \
                 "(got: #{writes.inspect})"
  ensure
    User.current = prior || User.anonymous
  end

  def test_hook_emission_does_not_change_redmine_row_counts
    prior = User.current
    User.current = @user
    assert_no_difference ['Issue.count', 'Journal.count', 'Version.count',
                          'Project.count', 'Member.count'] do
      RedminePulseHooks.instance.public_send(HEAD_HOOK, hook_context)
    end
  ensure
    User.current = prior || User.anonymous
  end
end
