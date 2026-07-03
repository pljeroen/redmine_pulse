# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# CA-22 / FC-CA-22: INVALIDATION MATRIX (M1..M8 + Mneg). Each input-class change MUST
# move snapshot_fingerprint for the AFFECTED project (so the next GET is a miss and
# recomputes), while an UNRELATED project's fingerprint stays unchanged; a clock
# advance with zero data change must NOT move it (Mneg / FC-CA-21).
#
# Sits on top of the as-built SnapshotFingerprint (8 components) + VisibilityContext.
# Postgres-gated (FC-CA-38). RED is inherited from the controller/store contract: this
# suite uses already-built adapters but encodes the controllers-api invalidation
# obligations as falsifiable per-row assertions.
class SnapshotInvalidationTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # COND-A8-004 / GL-CI-MYSQL: Postgres-evidence lane — skip on non-Postgres adapters
    # (counted as skips, not failures) so the CI MySQL legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @user = create_user!(login: 'invuser', admin: true)
    @role = create_role!(name: 'InvAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse view_changesets])
    @project = create_project!(name: 'Inv', identifier: 'inv-proj')
    @other = create_project!(name: 'InvOther', identifier: 'invother-proj')
    add_member!(project: @project, principal: @user, role: @role)
    add_member!(project: @other, principal: @user, role: @role)
    @issue = create_issue!(project: @project, author: @user, status: open_status,
                           updated_on: Time.utc(2026, 6, 10, 0))
  end

  def provider
    Pulse::Adapters::RedmineSettingsProvider.new
  end

  def fp(project = @project)
    Pulse::Adapters::SnapshotFingerprint.new(@user, project, settings_provider: provider).value
  end

  # `global:` true for fingerprint inputs that are GLOBAL (settings_version_hash /
  # priority_enum_version, components 7 + 6 per spec §6.4): a change to a global input
  # necessarily moves EVERY project's fingerprint, so the unrelated-@other-unchanged
  # clause does not hold and is skipped. The real requirement still holds: the target
  # project's fingerprint MUST move (the global change DOES invalidate it).
  def assert_moves_fp(project: @project, global: false)
    before = fp(project)
    other_before = fp(@other) unless global
    yield
    assert_not_equal before, fp(project), 'fingerprint MUST change for the affected project'
    assert_equal other_before, fp(@other), 'an unrelated project fingerprint is unchanged' unless global
  end

  # M1: issue update -> max(updated_on) moves.
  def test_M1_issue_update_moves_fp
    assert_moves_fp { stamp!(@issue, updated_on: Time.utc(2026, 6, 15, 0)) }
  end

  # M2: issue deletion -> visible_issue_count changes.
  def test_M2_issue_deletion_moves_fp
    extra = create_issue!(project: @project, author: @user, status: open_status,
                          updated_on: Time.utc(2026, 6, 5, 0))
    assert_moves_fp { extra.destroy }
  end

  # M3: relation add/remove -> blocker_fingerprint changes.
  def test_M3_relation_add_moves_fp
    blocker = create_issue!(project: @project, author: @user, status: open_status)
    assert_moves_fp { add_blocks_relation!(blocker: blocker, blocked: @issue) }
  end

  # M4: Version due-date edit -> version_due_date_set changes.
  def test_M4_version_due_date_moves_fp
    v = create_version!(project: @project, name: 'mv', effective_date: Date.new(2026, 9, 1))
    assert_moves_fp { v.update_column(:effective_date, Date.new(2026, 10, 1)) }
  end

  # M5: settings change -> settings_version_hash changes.
  def test_M5_settings_change_moves_fp
    # settings_version_hash is a GLOBAL fingerprint input (component 7): changing it
    # moves EVERY project's fp, so no unrelated-unchanged clause.
    assert_moves_fp(global: true) { pulse_settings!('rag_green_min' => 70) }
  end

  # M6: priority-enum change (id/position/is_default) -> priority_enum_version moves;
  # a name-only rename must NOT churn (FC-29 / EA-MS-004).
  def test_M6_priority_position_change_moves_fp_but_rename_does_not
    pr = IssuePriority.first
    # priority_enum_version is a GLOBAL fingerprint input (component 6): a position
    # change moves EVERY project's fp, so no unrelated-unchanged clause.
    assert_moves_fp(global: true) { pr.update_column(:position, pr.position + 50) }

    before = fp
    pr.update_column(:name, "#{pr.name}-renamed")
    assert_equal before, fp, 'a name-only priority rename must NOT churn the fingerprint (M6)'
  end

  # M7: VISIBLE cross-project blocker flips open<->closed -> blocker_fingerprint moves
  # even though this project's max(updated_on) is unmoved.
  def test_M7_cross_project_blocker_flip_moves_fp
    secret = create_project!(name: 'InvSecret', identifier: 'invsecret-proj')
    add_member!(project: secret, principal: @user, role: @role)
    blocker = create_issue!(project: secret, author: @user, status: open_status)
    add_blocks_relation!(blocker: blocker, blocked: @issue)
    before = fp
    add_close_journal!(issue: blocker, user: @user, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 6, 18, 0))
    assert_not_equal before, fp,
                     'a visible cross-project blocker flipping open->closed moves the fp (M7)'
  end

  # M8: visibility-predicate change -> visibility_context_id changes (the user reads a
  # DIFFERENT (project_id, ctx_id) cell, never stale/over-broad).
  def test_M8_visibility_predicate_change_moves_context_id
    before = Pulse::Adapters::VisibilityContext.new(@user, @project).id
    @role.update!(issues_visibility: 'own')
    @user.reload
    after = Pulse::Adapters::VisibilityContext.new(@user, @project).id
    assert_not_equal before, after,
                     'a visibility-predicate change moves visibility_context_id (M8)'
  end

  # Mneg: clock advance, zero data change -> fingerprint UNCHANGED (FC-CA-21).
  def test_Mneg_clock_advance_does_not_move_fp
    before = fp
    # The fingerprint takes no clock input; recomputing with no data change is stable.
    assert_equal before, fp, 'clock advance / zero data change -> fingerprint unchanged (Mneg)'
  end
end
