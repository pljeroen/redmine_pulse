# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Cache-partition / authorization-isolation suite (confidentiality; permission-safe).
#
# These tests PROVE two authorization/cache-isolation leaks are closed. NO production
# code is modified by the suite itself.
#
# THREAT MODEL falsified here:
#
#   (HIGH — private-note cache leak). The momentum activity of event_series
#     gates private-notes journals per-viewer (redmine_metrics_source.rb ~L256-258:
#     `may_view_private = view_private_notes?(user, project); next if
#     journal.private_notes? && !may_view_private`). But NEITHER VisibilityContext
#     (PREDICATE_PERMISSIONS = [:view_issues, :view_changesets]) NOR SnapshotFingerprint
#     tracks :view_private_notes. So a change to a viewer's private-notes ability does
#     NOT move the cache key: a snapshot warmed while the viewer COULD see private
#     notes is served UNCHANGED after the permission is revoked (stale-cache leak). The
#     unit check below proves the id under-partitioning directly; the e2e check proves the
#     exploitable stale-cache bleed through the real projection Engine.
#
#   (MEDIUM — effort custom-field visibility). effort()/sum_custom_field
#     (redmine_metrics_source.rb ~L120-141) sums a configured issue custom field's
#     CustomValue rows with NO field-visibility (visible_by?) check, and
#     VisibilityContext does not partition on custom-field visibility. A viewer
#     WITHOUT the role that makes the effort field visible still receives the summed
#     restricted values, AND shares a cache row with a field-visible viewer.
#
#   (LOW — characterization guard). The set of permissions the metrics branch
#     on MUST be a subset of what the cache partitions on. Pins
#     PREDICATE_PERMISSIONS to include :view_private_notes so a future metric added
#     behind a permission gate without updating the context breaks this test.
#
# Runs on PostgreSQL (the production engine) — the Issue.visible /
# CustomField.visible / allowed_to? SQL composition is verified on the deployed
# engine. Skip (not fail) on non-Postgres adapters so the other CI legs stay green.
class CacheVisibilityIsolationTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @project = create_project!(name: 'CacheIso', identifier: 'cache-iso')
  end

  def ctx_id(user)
    Pulse::Adapters::VisibilityContext.new(user, @project).id
  end

  # A metrics-source over the real settings provider (so effort_mapped? reflects the
  # plugin Setting we write in each test).
  def ms
    Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: real_settings_provider, clock: @clock
    )
  end

  def metrics_for(user, project = @project)
    ms.metrics_for(user, project_ids: [project.id]).first
  end

  # ── characterization guard (LOW): PREDICATE_PERMISSIONS coverage ──────
  # The definitive, deterministic set-membership check. The metrics branch on
  # :view_private_notes (view_private_notes? gate in event_series); the cache MUST
  # partition on it, i.e. PREDICATE_PERMISSIONS must include :view_private_notes
  # alongside :view_issues and :view_changesets.

  def test_rt08_predicate_permissions_includes_view_private_notes
    perms = Pulse::Adapters::VisibilityContext::PREDICATE_PERMISSIONS
    assert_includes perms, :view_private_notes,
                    'CACHE-LEAK: VisibilityContext::PREDICATE_PERMISSIONS omits ' \
                    ':view_private_notes, yet event_series gates private-notes ' \
                    'journals on it — the cache under-partitions and can serve a ' \
                    "private-notes viewer's momentum to a viewer who cannot see it. " \
                    "PREDICATE_PERMISSIONS = #{perms.inspect}"
  end

  def test_rt08_metric_gated_permissions_subset_of_partitioned
    # The permissions the momentum/effort computation branches on today. Kept
    # explicit so a future permission-gated metric that forgets to extend
    # PREDICATE_PERMISSIONS breaks a deterministic assertion.
    metric_gated = %i[view_issues view_changesets view_private_notes].to_set
    partitioned  = Pulse::Adapters::VisibilityContext::PREDICATE_PERMISSIONS.to_set
    assert metric_gated.subset?(partitioned),
           'CACHE-LEAK: metric-gating permissions ' \
           "#{metric_gated.to_a.inspect} are NOT a subset of the cache-partitioned " \
           "#{partitioned.to_a.inspect} — missing: " \
           "#{(metric_gated - partitioned).to_a.inspect}"
  end

  # ── private-note cache leak (HIGH): UNIT id-inequality ─
  # One shared role R (so role.id, issues_visibility and tracker settings are held
  # identical). Toggling ONLY :view_private_notes on R must move the id, exactly as
  # toggling :view_changesets does (see visibility_context_test
  # test_role_permission_change_moves_context_id). The perms descriptor must therefore
  # track :view_private_notes, not only [:view_issues, :view_changesets].

  def test_rt01_view_private_notes_grant_moves_context_id
    role = create_role!(name: 'PNToggle', issues_visibility: 'all',
                        permissions: %i[view_issues view_pulse])
    user = create_user!(login: 'pntoggle')
    add_member!(project: @project, principal: user, role: role)

    without_id = ctx_id(user)                 # role lacks :view_private_notes
    role.add_permission!(:view_private_notes) # grant it (fresh Role load re-reads DB)
    with_id = ctx_id(user)

    refute_equal without_id, with_id,
                 'CACHE-LEAK: granting :view_private_notes did NOT move the ' \
                 'visibility_context_id — a private-notes viewer shares a cache ' \
                 'partition with a non-private-notes viewer whose momentum differs. ' \
                 'PREDICATE_PERMISSIONS must include :view_private_notes.'
  end

  # ── END-TO-END: private-note momentum survives a permission revoke in cache
  # The confound-free e2e leak. Redmine mediates :view_private_notes through a role,
  # and role.id is in the descriptor — so two DISTINCT concurrent users who differ in
  # private-notes ability already differ by role membership (their ctx ids differ).
  # The exploitable bleed is therefore the STALE-CACHE-ACROSS-PERMISSION-CHANGE path:
  # one user on a role that grants :view_private_notes warms a snapshot whose
  # event_series carries a private-note :issue_commented event; the permission is then
  # revoked from that role; on the next read the cache row is NOT invalidated (neither
  # the visibility_context_id nor the SnapshotFingerprint tracks :view_private_notes),
  # so the user is served the private-note momentum they may no longer see. Direct
  # compute correctly drops it; the (unfixed) cache would leak it.
  def test_rt01_e2e_private_note_momentum_survives_permission_revoke_in_cache
    role = create_role!(name: 'PNE2ERole', issues_visibility: 'all',
                        permissions: %i[view_issues view_pulse view_private_notes])
    author = create_user!(login: 'pn_author')
    user = create_user!(login: 'pn_e2e_user')
    add_member!(project: @project, principal: author, role: role)
    add_member!(project: @project, principal: user, role: role)

    issue = create_issue!(project: @project, author: author, status: open_status,
                          created_on: Time.utc(2026, 6, 1, 0),
                          updated_on: Time.utc(2026, 6, 10, 0))
    # An in-window (window = 30d ending 2026-06-20) PRIVATE-notes journal.
    j = Journal.new(journalized: issue, user: author, notes: 'secret note',
                    private_notes: true)
    j.save!
    j.update_column(:created_on, Time.utc(2026, 6, 12, 0))

    store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    engine = Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: ms, store: store,
      settings_provider: real_settings_provider, clock: @clock
    )

    warm = engine.project_projection(user, @project) # warms while user CAN see private notes
    assert warm.metrics.event_series.any? { |e| e[:type] == :issue_commented },
           'fixture precondition: while permitted, the warmed snapshot carries the ' \
           'private-note momentum'

    # Revoke :view_private_notes: the user may no longer see the private note.
    role.remove_permission!(:view_private_notes)
    user.reload
    refute user.allowed_to?(:view_private_notes, @project),
           'fixture precondition: user can no longer view private notes'
    refute metrics_for(user).event_series.any? { |e| e[:type] == :issue_commented },
           'fixture precondition: direct-compute correctly drops the private-note event'

    cached = engine.project_projection(user, @project) # served the stale row
    leaked = cached.metrics.event_series.any? { |e| e[:type] == :issue_commented }
    refute leaked,
           'LEAK (e2e): after :view_private_notes was revoked, the cached ' \
           'snapshot still served the private-note :issue_commented momentum — neither ' \
           'the visibility_context_id nor the SnapshotFingerprint tracks ' \
           ':view_private_notes, so the stale row is never invalidated.'
  end

  # ── effort custom-field visibility (MEDIUM) ────────────────────────────
  # A numeric effort field visible ONLY to a role; a viewer WITHOUT that role but
  # WITH :view_issues+:view_pulse computes effort. sum_custom_field sums the
  # restricted CustomValue with no visible_by? check -> the blind viewer gets the
  # field-derived number instead of the issue-count fallback.

  def restricted_effort_field!(role)
    f = IssueCustomField.new(name: "PulseEffortRestricted#{SecureRandom.hex(3)}",
                             field_format: 'int', is_for_all: true, visible: false)
    f.role_ids = [role.id]
    # A field with no tracker association applies to no issue, so no CustomValue row
    # is ever written. Associate every tracker so the value lands on the issue.
    f.tracker_ids = Tracker.pluck(:id)
    f.save!
    raise 'field must be role-restricted' if f.visible?

    f
  end

  def test_rt02_effort_field_not_summed_for_field_blind_viewer
    field_role = create_role!(name: 'EffortSee', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    blind_role = create_role!(name: 'EffortBlind', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    field = restricted_effort_field!(field_role)
    pulse_settings!('effort_field' => field.id.to_s)

    seer = create_user!(login: 'eff_seer')
    blind = create_user!(login: 'eff_blind')
    add_member!(project: @project, principal: seer, role: field_role)
    add_member!(project: @project, principal: blind, role: blind_role)

    # One visible OPEN issue carrying effort=100 in the restricted field.
    issue = create_issue!(project: @project, author: seer, status: open_status)
    set_custom_value!(issue: issue, field: field, value: '100')

    assert field.visible_by?(@project, seer),
           'fixture precondition: seer can see the effort field'
    refute field.visible_by?(@project, blind),
           'fixture precondition: blind viewer cannot see the effort field'

    m_seer = metrics_for(seer)
    m_blind = metrics_for(blind)

    # The seer (field-visible) gets the summed field value.
    assert_equal 100, m_seer.effort_total,
                 'seer sees the effort field -> summed value 100'
    assert m_seer.effort_mapped, 'seer effort is field-mapped'

    # The blind viewer MUST NOT receive the summed restricted value. Correct
    # behaviour degrades to the issue-count fallback (1), unmapped.
    refute_equal 100, m_blind.effort_total,
                 'LEAK: the field-blind viewer received the summed restricted ' \
                 "effort field value (#{m_blind.effort_total}) — sum_custom_field has " \
                 'no visible_by? check.'
    assert_equal 1, m_blind.effort_total,
                 'field-blind viewer effort must degrade to the visible issue count (1)'
    refute m_blind.effort_mapped,
           'field-blind viewer effort must be unmapped (issue-count based)'
  end

  # ── END-TO-END: field-summed effort survives a field-visibility revoke in cache
  # The residual HIGH-severity gap the direct gate (effort_field_visible?) does NOT close.
  # A numeric effort field is initially VISIBLE to the user's role; a snapshot is warmed
  # through the real Engine, caching effort_total = 100 (field-summed, mapped=true). The
  # field's per-user visibility is then REVOKED (re-bind its role_ids away from the user's
  # role) WITHOUT touching any issue data or plugin Setting. Direct compute correctly
  # degrades to the count-based fallback (the direct-compute gate — assertion (a) passes). But
  # neither the visibility_context_id NOR the SnapshotFingerprint tracks the effort field's
  # per-user visibility, so the cache row is NOT invalidated: the Engine re-serves the stale
  # effort_total = 100 the user may no longer see. Assertion (b) guards that leak.
  def test_rt02_e2e_effort_field_summed_value_survives_visibility_revoke_in_cache
    # A single role held by the user. The effort field is bound to THIS role while
    # visible, then re-bound to `other_role` (which the user does NOT hold) to revoke.
    user_role  = create_role!(name: 'EffSeeE2E', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])
    other_role = create_role!(name: 'EffOtherE2E', issues_visibility: 'all',
                              permissions: %i[view_issues view_pulse])

    # A restricted (visible:false) numeric effort field, initially visible ONLY to
    # user_role (so the user CAN see it at warm time).
    field = IssueCustomField.new(name: "PulseEffortE2E#{SecureRandom.hex(3)}",
                                 field_format: 'int', is_for_all: true, visible: false)
    field.role_ids = [user_role.id]
    field.tracker_ids = Tracker.pluck(:id)
    field.save!
    pulse_settings!('effort_field' => field.id.to_s)

    user = create_user!(login: 'eff_e2e_user')
    add_member!(project: @project, principal: user, role: user_role)

    issue = create_issue!(project: @project, author: user, status: open_status)
    set_custom_value!(issue: issue, field: field, value: '100')

    assert field.visible_by?(@project, user),
           'fixture precondition: user can see the effort field at warm time'

    store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    engine = Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: ms, store: store,
      settings_provider: real_settings_provider, clock: @clock
    )

    # WARM: caches effort_total = 100 (field-summed, mapped=true) while user is field-visible.
    warm = engine.project_projection(user, @project)
    assert_equal 100, warm.metrics.effort_total,
                 'fixture precondition: while field-visible, the warmed snapshot sums the ' \
                 'effort field to 100'
    assert warm.metrics.effort_mapped,
           'fixture precondition: warmed effort is field-mapped'

    # REVOKE the field's visibility from the user: re-bind role_ids to a role the user
    # does NOT hold. No issue data changes, no plugin Setting changes. Reload so
    # visible_by? re-reads the fresh custom_fields_roles binding.
    field.role_ids = [other_role.id]
    field.save!
    field.reload
    refute field.visible_by?(@project, user),
           'fixture precondition: user can no longer see the effort field'

    # (a) DIRECT compute degrades (the direct-compute visibility gate).
    m_direct = metrics_for(user)
    refute m_direct.effort_mapped,
           'direct-compute must degrade to unmapped once the field is field-blind'
    refute_equal 100, m_direct.effort_total,
                 'direct-compute must NOT sum the now-invisible field'
    assert_equal 1, m_direct.effort_total,
                 'direct-compute degrades to the visible issue count (1)'

    # (b) THE CACHED PROJECTION must ALSO degrade, not serve the stale 100.
    cached = engine.project_projection(user, @project)
    refute_equal 100, cached.metrics.effort_total,
                 'LEAK (e2e): after the effort field\'s visibility was revoked, the ' \
                 'cached projection still served the stale field-summed effort_total (100) ' \
                 '— neither the visibility_context_id nor the SnapshotFingerprint tracks the ' \
                 'effort field\'s per-user visibility, so the stale snapshot row is never ' \
                 'invalidated.'
    assert_equal m_direct.effort_total, cached.metrics.effort_total,
                 'LEAK (e2e): cached effort_total must match the degraded direct-compute ' \
                 "value (#{m_direct.effort_total}), not the stale field-summed 100."
  end
end
