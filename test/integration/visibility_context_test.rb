# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# VisibilityContext fingerprint correctness (MS-23/24/25, FC-24/25/26). RED until A9.
#
# Canonical API:
#   Pulse::Adapters::VisibilityContext.new(user, project).id -> String (deterministic)
class VisibilityContextTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    @project = create_project!(name: 'Ctx', identifier: 'ctx-proj')
  end

  def ctx_id(user)
    Pulse::Adapters::VisibilityContext.new(user, @project).id
  end

  # --- MS-24 / FC-25: same identity-independent predicate -> same id -----------

  def test_two_all_visibility_users_share_context_id
    role = create_role!(name: 'CtxAll', issues_visibility: 'all')
    u1 = create_user!(login: 'ctxa1')
    u2 = create_user!(login: 'ctxa2')
    add_member!(project: @project, principal: u1, role: role)
    add_member!(project: @project, principal: u2, role: role)
    assert_equal ctx_id(u1), ctx_id(u2),
                 'identity-independent (all) predicate is shareable'
  end

  # --- MS-24 / FC-25: own-visibility collapses to per-user --------------------

  def test_own_visibility_users_get_distinct_per_user_context
    role = create_role!(name: 'CtxOwn', issues_visibility: 'own')
    u1 = create_user!(login: 'ctxo1')
    u2 = create_user!(login: 'ctxo2')
    add_member!(project: @project, principal: u1, role: role)
    add_member!(project: @project, principal: u2, role: role)
    refute_equal ctx_id(u1), ctx_id(u2),
                 'own/default is identity-dependent -> per-user (includes user.id)'
  end

  def test_context_id_is_deterministic_for_same_predicate
    role = create_role!(name: 'CtxDet', issues_visibility: 'all')
    u = create_user!(login: 'ctxdet')
    add_member!(project: @project, principal: u, role: role)
    assert_equal ctx_id(u), ctx_id(u)
    assert_kind_of String, ctx_id(u)
  end

  # --- MS-24 / FC-26: any predicate-affecting change moves the id -------------

  def test_group_membership_change_moves_context_id
    role = create_role!(name: 'CtxGrp', issues_visibility: 'own')
    u = create_user!(login: 'ctxgrp')
    add_member!(project: @project, principal: u, role: role)
    before = ctx_id(u)
    group = Group.generate!(name: 'CtxGroup')
    group.users << u
    add_member!(project: @project, principal: group, role: role)
    u.reload
    refute_equal before, ctx_id(u), 'group membership change moves visibility_context_id'
  end

  def test_admin_flag_change_moves_context_id
    role = create_role!(name: 'CtxAdmin', issues_visibility: 'own')
    u = create_user!(login: 'ctxadmin')
    add_member!(project: @project, principal: u, role: role)
    before = ctx_id(u)
    u.update_column(:admin, true)
    u.reload
    refute_equal before, ctx_id(u), 'admin flag participates'
  end

  def test_pulse_module_state_change_moves_context_id
    role = create_role!(name: 'CtxMod', issues_visibility: 'all')
    u = create_user!(login: 'ctxmod')
    add_member!(project: @project, principal: u, role: role)
    before = ctx_id(u)
    @project.enabled_module_names = %w[issue_tracking] # disable pulse
    @project.reload
    refute_equal before, ctx_id(u), 'pulse module state participates'
  end

  def test_role_permission_change_moves_context_id
    role = create_role!(name: 'CtxPerm', issues_visibility: 'all',
                        permissions: %i[view_issues view_pulse])
    u = create_user!(login: 'ctxperm')
    add_member!(project: @project, principal: u, role: role)
    before = ctx_id(u)
    role.add_permission!(:view_changesets) # changeset visibility dimension changes
    refute_equal before, ctx_id(u), ':view_changesets permission change participates (THAW-001)'
  end

  # --- MS-25 / FC-24: NO view_private_issues dimension ------------------------

  def test_no_view_private_issues_dimension
    role = create_role!(name: 'CtxNPV', issues_visibility: 'all')
    u = create_user!(login: 'ctxnpv')
    add_member!(project: @project, principal: u, role: role)
    vc = Pulse::Adapters::VisibilityContext.new(u, @project)
    # The adapter MUST expose its input dimensions for falsification (canonical API).
    refute vc.respond_to?(:view_private_issues),
           'no view_private_issues accessor (nonexistent in Redmine 6.1)'
    if vc.respond_to?(:dimensions)
      keys = vc.dimensions.keys.map(&:to_s)
      refute keys.any? { |k| k.include?('view_private_issues') },
             'view_private_issues must not be an input dimension'
    end
  end
end
