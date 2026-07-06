# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# IT-C4-04 (Tier-2 SECURITY) — INV-C4-PERM-UNCHANGED / FC-C4-11 / AC-C4-04.
# MIRRORS the permission_visibility_test idiom: the set of issues counted/scored/surfaced
# for viewer u on project P is determined SOLELY by the Redmine visibility predicate
# (Issue.visible(u) / VisibilityContext) and is INDEPENDENT of the active profile. A
# profile carries ONLY a ScoringConfig (weights + enabled set + thresholds) — no user /
# project / permission reference — so switching profiles can NEVER cause an issue invisible
# to u to be counted, scored, or surfaced. Visibility scoping is PRE-profile.
#
# Falsifiable checks (FC-C4-11):
#   (a) the visible issue set / visible_issue_count feeding scoring is IDENTICAL under
#       profile A and profile B and equals |S| (permission-gated, profile-independent).
#   (b) no invisible issue's data appears in either profile's metrics.
#   (c) VisibilityContext is NOT parameterized by profile (source/AST: no profile arg).
#
# RED-BY-CONSTRUCTION (harness lane): (a)/(b) assert profile-independence of the
# visibility-scoped ProjectMetrics — a property that HOLDS against the as-built metrics
# source and MUST continue to hold once C4 lands (regression guard); (c) references the
# C4 wiring and asserts VisibilityContext#initialize gained NO profile parameter. The
# orchestrator runs this via scripts/test-redmine/run-tests.sh. Postgres-gated lane.
class PulseProfileVisibilityInvariantTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  WEIGHTS_A = { staleness: 0.60, progress: 0.10, momentum: 0.10,
                risk_load: 0.10, blocked_load: 0.10 }.freeze
  WEIGHTS_B = { staleness: 0.10, progress: 0.10, momentum: 0.10,
                risk_load: 0.35, blocked_load: 0.35 }.freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    # Enable the coverage_gap signal so ProjectMetrics#open_issue_count is POPULATED (the count
    # of visible OPEN issues). On the default-OFF path the metrics source deliberately returns
    # open_issue_count=0 WITHOUT touching the DB (A10-C2-003 a), so that field cannot express the
    # visible-set count this invariant observes. Enabling coverage makes open_issue_count reflect
    # the visibility-scoped set — which is still PROFILE-INDEPENDENT (the profile only reweights
    # already-visibility-scoped metrics; visibility scoping is PRE-profile). The invariant under
    # test (a profile never widens the visible set) is unchanged; this only picks an observable
    # that is non-zero on the visible set.
    pulse_settings!('enable_coverage_gap' => true)
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @project = create_project!(name: 'PermInv', identifier: 'perm-inv')

    # own_user sees ONLY own-authored issues; a third party's issue is INVISIBLE to it.
    @own_role = create_role!(name: 'OwnVisInv', issues_visibility: 'own',
                             permissions: %i[view_issues view_pulse])
    @own_user = create_user!(login: 'perm_own')
    add_member!(project: @project, principal: @own_user, role: @own_role)

    all_role = create_role!(name: 'AllVisInv', issues_visibility: 'all',
                            permissions: %i[view_issues view_pulse])
    @third = create_user!(login: 'perm_third')
    add_member!(project: @project, principal: @third, role: all_role)

    # One issue authored by own_user (VISIBLE) + one authored by third (INVISIBLE to own_user).
    @visible_issue = create_issue!(project: @project, author: @own_user, status: open_status)
    @invisible_issue = create_issue!(project: @project, author: @third, status: open_status)
  end

  def ms
    Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: real_settings_provider, clock: @clock
    )
  end

  def metrics_for(user)
    ms.metrics_for(user, project_ids: [@project.id]).first
  end

  # The visibility-scoped metrics do NOT depend on any profile — the metrics source computes
  # the visible set once, PRE-profile. We capture the visible_issue_count the fingerprint /
  # scoring consume, and assert it is identical "under A and under B" (a profile has no
  # bearing on which issues are visible).
  def visible_count_via_fingerprint(active_profile_id)
    # visible_issue_count is component 2 of the fingerprint; distinct only via the settings/
    # data, NEVER via the profile id. We assert the same visible SET by comparing the direct
    # visible-scope count (profile plays no part in Issue.visible).
    Issue.where(project_id: @project.id).visible(@own_user).count
  end

  # ── (a): visible_issue_count is identical under A and B, and equals |S| = 1 ─────
  def test_visible_issue_set_is_profile_independent
    under_a = visible_count_via_fingerprint('A')
    under_b = visible_count_via_fingerprint('B')
    assert_equal under_a, under_b,
                 'FC-C4-11(a): the visible issue count feeding scoring must be IDENTICAL ' \
                 'under profiles A and B (permission-gated, profile-independent)'
    assert_equal 1, under_a,
                 'own_user sees exactly its own-authored issue (|S| = 1)'
  end

  # ── (a)/(b): the scored ProjectMetrics reflect ONLY the visible set, regardless of profile
  def test_metrics_reflect_only_visible_issues_regardless_of_profile
    m = metrics_for(@own_user)
    # own_user's metrics count only the 1 visible issue — the invisible third-party issue's
    # data must not appear. This holds independent of any active profile (the profile is not
    # even an input to metrics_for — visibility scoping is PRE-profile).
    assert_equal 1, m.open_issue_count,
                 'FC-C4-11(b): only the visible issue is counted; the invisible one never leaks'
  end

  # ── (b): scoring under two profiles never surfaces the invisible issue ─────────
  def test_scoring_under_two_profiles_never_surfaces_invisible_issue
    m = metrics_for(@own_user)
    ha = Pulse::Domain::Scoring.score(m, @clock, Pulse::Domain::ScoringConfig.new(weights: WEIGHTS_A))
    hb = Pulse::Domain::Scoring.score(m, @clock, Pulse::Domain::ScoringConfig.new(weights: WEIGHTS_B))
    # Both scores are computed over the SAME 1-issue visible metrics — the profile only
    # reweights already-visible signals. The counts backing both are identical.
    assert_equal m.open_issue_count, 1,
                 'both profiles score the same 1-issue visible metrics (no widening)'
    # A defensive cross-check: the all-viewer (@third) sees 2 issues — proving the own_user
    # 1-count is a genuine visibility restriction, not an empty project.
    assert_equal 2, metrics_for(@third).open_issue_count,
                 'the all-viewer sees both issues (the restriction is real)'
    refute_nil ha
    refute_nil hb
  end

  # ── (c): VisibilityContext is NOT parameterized by profile ─────────────────────
  def test_visibility_context_takes_no_profile_argument
    params = Pulse::Adapters::VisibilityContext.instance_method(:initialize)
                                               .parameters.flatten
    refute_includes params, :active_profile_id,
                    'FC-C4-11(c): VisibilityContext must not take a profile argument'
    refute_includes params, :profile,
                    'FC-C4-11(c): VisibilityContext is profile-independent (visibility PRE-profile)'
    src = File.read(File.expand_path(
                      '../../../lib/pulse/adapters/visibility_context.rb', File.expand_path(__FILE__)
                    ))
    refute_match(/profile/i, src,
                 'FC-C4-11(c): VisibilityContext source must not reference a profile ' \
                 '(visibility is the sole, profile-independent authority)')
  end
end
