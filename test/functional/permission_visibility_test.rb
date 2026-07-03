# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# The CRITICAL property suite: every aggregate is computed ONLY over the viewer's
# visible issue set; non-visible issues never contribute (INV-PERMISSION-SAFE).
# Postgres-gated (FC-38). RED until A9 builds the adapter.
#
# Canonical access-decision API (A9 implements):
#   ms.access_decision(user, project_id) -> :ok | :forbidden | :not_found
#     :not_found  == HTTP 404 (not in Project.visible / nonexistent / archived)
#     :forbidden  == HTTP 403 (visible but no view_pulse, or pulse module disabled)
#   ms.portfolio_project_ids(user) -> Array<Integer> (visible & pulse-on & view_pulse)
class PermissionVisibilityTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @project = create_project!(name: 'Vis', identifier: 'vis-proj')
  end

  def provider
    cfg = Pulse::Domain::ScoringConfig.new
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:settings_version_hash) { 'v0' }
    end.new
  end

  def ms
    Pulse::Adapters::RedmineMetricsSource.new(settings_provider: provider, clock: @clock)
  end

  def metrics_for(user, project)
    ms.metrics_for(user, project_ids: [project.id]).first
  end

  # --- MS-35 / FC-06: viewer-scoped aggregates differ for differing visibility -

  def test_viewer_scoped_aggregates_differ_all_vs_own
    all_user = create_user!(login: 'allviewer')
    own_user = create_user!(login: 'ownviewer')
    all_role = create_role!(name: 'AllVis', issues_visibility: 'all')
    own_role = create_role!(name: 'OwnVis', issues_visibility: 'own')
    add_member!(project: @project, principal: all_user, role: all_role)
    add_member!(project: @project, principal: own_user, role: own_role)

    # one issue authored by all_user, one by a third party (invisible to own_user)
    third = create_user!(login: 'thirdparty')
    add_member!(project: @project, principal: third, role: all_role)
    create_issue!(project: @project, author: own_user, status: open_status)
    create_issue!(project: @project, author: third, status: open_status)

    m_all = metrics_for(all_user, @project) # sees both
    m_own = metrics_for(own_user, @project) # sees only own-authored
    assert_equal 2, m_all.effort_total
    assert_equal 1, m_own.effort_total, 'own-visibility user counts only their visible issues'
    refute_equal m_all.effort_total, m_own.effort_total
  end

  # --- MS-06 / FC-06: private issue excluded for non-identity user --------------

  def test_private_issue_excluded_for_non_member_identity
    owner_role = create_role!(name: 'OwnerAll', issues_visibility: 'all')
    restricted_role = create_role!(name: 'RestrictedOwn', issues_visibility: 'own')
    owner = create_user!(login: 'priv_owner')
    restricted = create_user!(login: 'priv_restricted')
    add_member!(project: @project, principal: owner, role: owner_role)
    add_member!(project: @project, principal: restricted, role: restricted_role)

    create_issue!(project: @project, author: owner, status: open_status, is_private: true)

    m = metrics_for(restricted, @project)
    assert_equal 0, m.effort_total, 'private issue authored by another excluded from count'
    assert_equal 0, m.event_series.count { |e| e[:type] == :issue_created }
  end

  # --- MS-07 / FC-07: 'own' includes group-assigned issues --------------------

  def test_own_visibility_includes_group_assigned_issues
    own_role = create_role!(name: 'OwnGrp', issues_visibility: 'own')
    user = create_user!(login: 'grpuser')
    group = Group.generate!(name: 'PulseGroup')
    group.users << user
    add_member!(project: @project, principal: user, role: own_role)
    add_member!(project: @project, principal: group, role: own_role)

    author = create_user!(login: 'someauthor')
    add_member!(project: @project, principal: author,
                role: create_role!(name: 'AuthAll', issues_visibility: 'all'))
    # issue authored by another, assigned to the user's GROUP -> visible to own-user
    create_issue!(project: @project, author: author, assigned_to: group, status: open_status)

    m = metrics_for(user, @project)
    assert_equal 1, m.effort_total, 'group-assigned issue is visible to own-visibility group member'
  end

  # --- MS-16 / FC-17: hidden blocker excluded (incl. cross-project) ------------

  def test_hidden_blocker_not_counted_in_blocked_count
    viewer_role = create_role!(name: 'ViewerAll', issues_visibility: 'all')
    viewer = create_user!(login: 'blockviewer')
    add_member!(project: @project, principal: viewer, role: viewer_role)

    blocked = create_issue!(project: @project, author: viewer, status: open_status)

    # blocker lives in a SEPARATE project the viewer cannot see
    secret = create_project!(name: 'Secret', identifier: 'secret-proj')
    secret_author = create_user!(login: 'secretowner')
    add_member!(project: secret, principal: secret_author,
                role: create_role!(name: 'SecretAll', issues_visibility: 'all'))
    blocker = create_issue!(project: secret, author: secret_author, status: open_status)
    add_blocks_relation!(blocker: blocker, blocked: blocked)

    m = metrics_for(viewer, @project)
    assert_equal 0, m.blocked_count, 'cross-project blocker invisible to viewer is not counted'

    # a privileged user who can see the blocker DOES count it
    priv = create_user!(login: 'privblock', admin: true)
    add_member!(project: @project, principal: priv, role: viewer_role)
    m_priv = metrics_for(priv, @project)
    assert_equal 1, m_priv.blocked_count, 'privileged user sees the blocker -> counted'
  end

  # --- MS-21 / FC-21: event_series visible-only ---------------------------------

  def test_event_series_excludes_non_visible_issue_events
    own_role = create_role!(name: 'EvtOwn', issues_visibility: 'own')
    restricted = create_user!(login: 'evtrestricted')
    add_member!(project: @project, principal: restricted, role: own_role)
    other = create_user!(login: 'evtother')
    add_member!(project: @project, principal: other,
                role: create_role!(name: 'EvtAll', issues_visibility: 'all'))

    hidden = create_issue!(project: @project, author: other, status: open_status,
                           is_private: true, created_on: Time.utc(2026, 5, 1, 0))
    add_close_journal!(issue: hidden, user: other, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 5, 3, 0))

    m = metrics_for(restricted, @project)
    assert_equal 0, m.event_series.size, 'no events from a non-visible issue appear'
  end

  # --- MS-03 / MS-05 / FC-03/FC-04: outer set + portfolio subset ---------------

  def test_outer_set_excludes_archived_and_invisible
    member_role = create_role!(name: 'OuterAll', issues_visibility: 'all')
    user = create_user!(login: 'outeruser')
    add_member!(project: @project, principal: user, role: member_role)

    archived = create_project!(name: 'Arch', identifier: 'arch-proj',
                               status: Project::STATUS_ARCHIVED)
    add_member!(project: archived, principal: user, role: member_role)

    ids = ms.portfolio_project_ids(user)
    assert_includes ids, @project.id
    refute_includes ids, archived.id, 'archived project excluded (DEC-16)'
  end

  def test_portfolio_requires_view_pulse_and_module
    user = create_user!(login: 'portuser')
    # role WITHOUT view_pulse
    no_pulse_role = create_role!(name: 'NoPulse', issues_visibility: 'all',
                                 permissions: %i[view_issues])
    add_member!(project: @project, principal: user, role: no_pulse_role)
    ids = ms.portfolio_project_ids(user)
    refute_includes ids, @project.id, 'no view_pulse -> omitted, no error raised'
  end

  # --- MS-04 / FC-05: 404 / 403 access-decision matrix -------------------------

  def test_access_decision_404_for_invisible_and_archived
    outsider = create_user!(login: 'outsider') # no membership anywhere
    private_proj = create_project!(name: 'Priv', identifier: 'priv-proj')
    private_proj.update_column(:is_public, false)
    assert_equal :not_found, ms.access_decision(outsider, private_proj.id),
                 'private+invisible -> 404 (existence not leaked)'

    archived = create_project!(name: 'Arch2', identifier: 'arch2-proj',
                               status: Project::STATUS_ARCHIVED)
    member_role = create_role!(name: 'Arch2Role', issues_visibility: 'all')
    add_member!(project: archived, principal: outsider, role: member_role)
    assert_equal :not_found, ms.access_decision(outsider, archived.id),
                 'archived -> 404'

    assert_equal :not_found, ms.access_decision(outsider, 99_999_999),
                 'nonexistent -> 404'
  end

  def test_access_decision_403_for_visible_but_unpermitted
    user = create_user!(login: 'visnopulse')
    role = create_role!(name: 'VisNoPulse', issues_visibility: 'all',
                        permissions: %i[view_issues]) # visible, but no view_pulse
    add_member!(project: @project, principal: user, role: role)
    assert_equal :forbidden, ms.access_decision(user, @project.id),
                 'visible but missing view_pulse -> 403'
  end

  def test_access_decision_403_for_module_disabled
    user = create_user!(login: 'modoff')
    role = create_role!(name: 'ModOff', issues_visibility: 'all')
    add_member!(project: @project, principal: user, role: role)
    @project.enabled_module_names = %w[issue_tracking] # pulse module OFF
    assert_equal :forbidden, ms.access_decision(user, @project.id),
                 'visible, has view_pulse role, but pulse module disabled -> 403'
  end

  def test_access_decision_ok_for_visible_and_permitted
    user = create_user!(login: 'okuser')
    role = create_role!(name: 'OkRole', issues_visibility: 'all')
    add_member!(project: @project, principal: user, role: role)
    assert_equal :ok, ms.access_decision(user, @project.id)
  end
end
