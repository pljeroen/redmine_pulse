# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# snapshot_fingerprint correctness + invalidation (MS-26/27/28, FC-27/28/29). RED.
#
# Canonical API:
#   fp = Pulse::Adapters::SnapshotFingerprint.new(user, project, settings_provider:)
#   fp.value -> String (deterministic hash over 8 ordered components; Clock excluded)
#   fp.priority_enum_version -> String  (component 6, exposed for falsification)
class SnapshotFingerprintTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @user = create_user!(login: 'fpuser')
    @role = create_role!(name: 'FpAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse view_changesets])
    @project = create_project!(name: 'Fp', identifier: 'fp-proj')
    add_member!(project: @project, principal: @user, role: @role)
    @settings_version = 'v0'
  end

  def provider(version: @settings_version)
    cfg = Pulse::Domain::ScoringConfig.new
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:settings_version_hash) { version }
    end.new
  end

  def fp(settings_provider: provider)
    Pulse::Adapters::SnapshotFingerprint.new(@user, @project, settings_provider: settings_provider)
  end

  def value(settings_provider: provider)
    fp(settings_provider: settings_provider).value
  end

  # --- MS-26 / FC-27: determinism ---------------------------------------------

  def test_same_state_yields_same_fingerprint
    create_issue!(project: @project, author: @user)
    assert_equal value, value
    assert_kind_of String, value
  end

  # --- MS-26 / FC-27 component 1/2: issue update + deletion -------------------

  def test_updating_visible_issue_changes_fingerprint
    i = create_issue!(project: @project, author: @user, updated_on: Time.utc(2026, 5, 1, 0))
    before = value
    i.update_column(:updated_on, Time.utc(2026, 6, 1, 0))
    refute_equal before, value, 'max(updated_on) component changes'
  end

  def test_deleting_visible_issue_changes_fingerprint
    i1 = create_issue!(project: @project, author: @user)
    create_issue!(project: @project, author: @user)
    before = value
    i1.destroy
    refute_equal before, value, 'visible_issue_count component catches deletion'
  end

  # --- MS-27 / FC-28: cross-project blocker open<->closed flip ----------------

  def test_cross_project_blocker_flip_changes_blocker_fingerprint
    blocked = create_issue!(project: @project, author: @user, status: open_status)
    other = create_project!(name: 'FpOther', identifier: 'fp-other')
    add_member!(project: other, principal: @user, role: @role)
    blocker = create_issue!(project: other, author: @user, status: open_status,
                            updated_on: Time.utc(2026, 5, 1, 0))
    add_blocks_relation!(blocker: blocker, blocked: blocked)
    before = value
    # flip the blocker closed; its updated_on is on ANOTHER project, outside this
    # project's max(updated_on) -> only blocker_fingerprint should catch it.
    blocker.update_column(:status_id, closed_status.id)
    blocker.update_column(:updated_on, Time.utc(2026, 6, 1, 0))
    refute_equal before, value,
                 'visible cross-project blocker state flip must change blocker_fingerprint'
  end

  # --- MS-28 / FC-29: priority reorder changes; name-only rename does NOT ------

  def test_priority_reorder_changes_priority_enum_version
    priorities = IssuePriority.order(:position).to_a
    skip 'need >=2 priorities' if priorities.size < 2
    before = fp.priority_enum_version
    a, b = priorities[0], priorities[1]
    pa, pb = a.position, b.position
    a.update_column(:position, pb)
    b.update_column(:position, pa)
    refute_equal before, fp.priority_enum_version, 'reorder changes priority_enum_version'
  end

  def test_priority_name_only_rename_does_not_change_fingerprint
    priorities = IssuePriority.order(:position).to_a
    skip 'need >=1 priority' if priorities.empty?
    create_issue!(project: @project, author: @user)
    before_fp = value
    before_pev = fp.priority_enum_version
    p = priorities.first
    p.update_column(:name, "#{p.name} RENAMED")
    assert_equal before_pev, fp.priority_enum_version,
                 'name-only rename leaves priority_enum_version unchanged (no cache churn)'
    assert_equal before_fp, value, 'name-only rename does not change snapshot_fingerprint'
  end

  # --- MS-26 / FC-27 component 7: settings change -----------------------------

  def test_settings_change_changes_fingerprint
    create_issue!(project: @project, author: @user)
    before = value(settings_provider: provider(version: 'v0'))
    after  = value(settings_provider: provider(version: 'v1'))
    refute_equal before, after, 'settings_version_hash component changes the fingerprint'
  end

  # --- MS-26 / FC-27: Clock excluded by design --------------------------------

  def test_clock_advance_does_not_change_fingerprint
    create_issue!(project: @project, author: @user)
    # SnapshotFingerprint takes NO clock; advancing wall time / clock cannot affect it.
    a = value
    b = value
    assert_equal a, b, 'fingerprint excludes Clock.today (DEC-11) -> stable across clock advance'
    # Falsification: the constructor must not accept a clock that perturbs the value.
    refute Pulse::Adapters::SnapshotFingerprint.instance_method(:initialize)
                                               .parameters.flatten.include?(:clock),
           'SnapshotFingerprint#initialize must not take a clock (clock excluded by design)'
  end
end
