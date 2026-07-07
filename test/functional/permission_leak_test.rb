# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# Multi-user permission/visibility leak suite (permission-safe). This is a security
# guard that stays in the suite as a permanent cross-user no-leak characterization.
#
# THREAT MODEL it falsifies:
#   * portfolio_project_ids is `visible AND pulse-module-on AND view_pulse` subset
#     scoped to User.current. Two users with different project membership must see
#     disjoint exclusive sets through GET /pulse/portfolio.json and through the
#     inlined project-list-badge blob (lib/redmine_pulse/hooks.rb).
#   * GET /pulse/projects/<other-user's-project>.json must 404 (existence not
#     leaked) for a user with no visibility on it.
#   * Within a SHARED project, an issue visible to A but not B must not let B's
#     per-project projection reflect A-only issues (and vice versa).
#   * The snapshot cache is keyed by a per-viewer visibility_context_id, so a
#     warmed-by-A cache row must NOT serve B B's-mismatched projection.
#
# Each case is independently falsifiable; on a leak the assertion message captures
# expected vs actual and the leaked identifier/value.
#
# Runs on PostgreSQL (the production engine) — the Project.visible /
# Issue.visible / allowed_to? SQL composition is verified on the deployed engine.
# Skip (not fail) on non-Postgres adapters so the other CI legs stay green.
class PermissionLeakTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  BLOB_ID = 'pulse-portfolio-data'
  HEAD_HOOK = :view_layouts_base_html_head

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'LeakAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])

    # P1 exclusive to A ; P2 shared A+B ; P3 exclusive to B ; P4 private to both.
    @p1 = create_project!(name: 'LeakP1', identifier: 'leak-p1')
    @p2 = create_project!(name: 'LeakP2', identifier: 'leak-p2')
    @p3 = create_project!(name: 'LeakP3', identifier: 'leak-p3')
    @p4 = create_project!(name: 'LeakP4', identifier: 'leak-p4')
    @p4.update_column(:is_public, false) # private + nobody is a member -> invisible to both

    @user_a = create_user!(login: 'leak_a')
    @user_b = create_user!(login: 'leak_b')

    add_member!(project: @p1, principal: @user_a, role: @role)
    add_member!(project: @p2, principal: @user_a, role: @role)
    add_member!(project: @p2, principal: @user_b, role: @role)
    add_member!(project: @p3, principal: @user_b, role: @role)

    # Give every membered project visible activity so its portfolio row is non-empty.
    [@p1, @p2, @p3].each do |proj|
      author = proj == @p3 ? @user_b : @user_a
      create_issue!(project: proj, author: author, status: open_status,
                    created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def portfolio_identifiers(user)
    with_settings rest_api_enabled: '1' do
      get '/pulse/portfolio.json', headers: api_key_header(user)
    end
    assert_response :success, "portfolio.json must be 200 for #{user.login}"
    JSON.parse(response.body).fetch('projects').map { |p| p['identifier'] }
  end

  def listener
    RedminePulseHooks.instance
  end

  def hook_context
    ctrl = Struct.new(:controller_name, :action_name).new('projects', 'index')
    { controller: ctrl, action_name: 'index', controller_name: 'projects',
      project: nil, request: ActionDispatch::TestRequest.create, hook_caller: ctrl }
  end

  def badge_identifiers(user)
    prior = User.current
    User.current = user
    html = listener.public_send(HEAD_HOOK, hook_context).to_s
    body = html[%r{<script[^>]*id="#{BLOB_ID}"[^>]*>(.*?)</script>}m, 1]
    return [] if body.nil? # no blob emitted == empty portfolio

    JSON.parse(body).fetch('projects').map { |p| p['identifier'] }
  ensure
    User.current = prior || User.anonymous
  end

  def metrics_for(user, project)
    ms = Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: real_settings_provider,
      clock: PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    )
    ms.metrics_for(user, project_ids: [project.id]).first
  end

  # ── CASE 1a: portfolio.json — exclusive sets are disjoint, P4 invisible ───────

  def test_case1_portfolio_json_disjoint_per_viewer
    ids_a = portfolio_identifiers(@user_a)
    ids_b = portfolio_identifiers(@user_b)

    assert_equal %w[leak-p1 leak-p2], ids_a.sort,
                 "A's portfolio must be exactly {P1,P2}; got #{ids_a.inspect}"
    assert_equal %w[leak-p2 leak-p3], ids_b.sort,
                 "B's portfolio must be exactly {P2,P3}; got #{ids_b.inspect}"

    refute_includes ids_a, 'leak-p3', "LEAK: P3 (B-exclusive) appeared in A's portfolio"
    refute_includes ids_b, 'leak-p1', "LEAK: P1 (A-exclusive) appeared in B's portfolio"
    [ids_a, ids_b].each do |ids|
      refute_includes ids, 'leak-p4', 'LEAK: P4 (private, invisible to both) appeared in a portfolio'
    end
  end

  # ── CASE 1b: inlined badge blob — same disjoint per-viewer property ───────────

  def test_case1_badge_blob_disjoint_per_viewer
    ids_a = badge_identifiers(@user_a)
    ids_b = badge_identifiers(@user_b)

    assert_equal %w[leak-p1 leak-p2], ids_a.sort,
                 "A's badge blob must be exactly {P1,P2}; got #{ids_a.inspect}"
    assert_equal %w[leak-p2 leak-p3], ids_b.sort,
                 "B's badge blob must be exactly {P2,P3}; got #{ids_b.inspect}"

    refute_includes ids_a, 'leak-p3', "LEAK(badge): P3 (B-exclusive) appeared in A's inline blob"
    refute_includes ids_b, 'leak-p1', "LEAK(badge): P1 (A-exclusive) appeared in B's inline blob"
    [ids_a, ids_b].each do |ids|
      refute_includes ids, 'leak-p4', 'LEAK(badge): P4 (invisible) appeared in an inline blob'
    end
  end

  # ── CASE 1c: project.json on the OTHER user's exclusive project ───────────────

  def test_case1_project_json_404_for_non_visible_200_for_owner
    # P3 is B-exclusive: A must get 404 (existence not leaked), B must get 200.
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@p3.identifier}.json", headers: api_key_header(@user_a)
    end
    assert_response :not_found,
                    'LEAK: A reached B-exclusive P3 via project.json (existence must not leak -> 404)'

    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@p3.identifier}.json", headers: api_key_header(@user_b)
    end
    assert_response :success, "B (member of P3) must get 200 on its own project"

    # And symmetrically P1 (A-exclusive): B -> 404, A -> 200.
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@p1.identifier}.json", headers: api_key_header(@user_b)
    end
    assert_response :not_found,
                    'LEAK: B reached A-exclusive P1 via project.json (must 404)'

    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@p1.identifier}.json", headers: api_key_header(@user_a)
    end
    assert_response :success, 'A (member of P1) must get 200 on its own project'
  end

  # ── CASE 2: issue-level visibility inside the SHARED project P2 ───────────────
  # An issue visible to A but NOT B (private, authored by A) must not contribute to
  # B's P2 projection, and vice versa (permission-safe). A's and B's roles use
  # 'own' visibility so a private issue authored by the other is hidden.

  def test_case2_shared_project_issue_visibility_isolated
    own_role = create_role!(name: 'LeakOwn', issues_visibility: 'own')
    a = create_user!(login: 'leak2_a')
    b = create_user!(login: 'leak2_b')
    add_member!(project: @p2, principal: a, role: own_role)
    add_member!(project: @p2, principal: b, role: own_role)

    base_a = metrics_for(a, @p2).effort_total
    base_b = metrics_for(b, @p2).effort_total

    # A private issue authored by A -> visible to A (author), hidden from B (own + not author).
    create_issue!(project: @p2, author: a, status: open_status, is_private: true,
                  created_on: Time.utc(2026, 6, 5, 0), updated_on: Time.utc(2026, 6, 5, 0))

    m_a = metrics_for(a, @p2)
    m_b = metrics_for(b, @p2)

    assert_equal base_a + 1, m_a.effort_total,
                 "A (author) must count A's own private issue in P2"
    assert_equal base_b, m_b.effort_total,
                 "LEAK: B's P2 projection counted A's private issue " \
                 "(expected #{base_b}, got #{m_b.effort_total}) — issue-level visibility breach"
    refute_equal m_a.effort_total, m_b.effort_total,
                 'A and B must see different P2 effort where their visible issue sets differ'
  end

  # ── CASE 3: snapshot cache key is visibility-isolated (no cross-user bleed) ────
  # After A warms P2's snapshot, B reading P2 must get B's own visibility-scoped
  # result, NOT A's cached one. Falsified two ways: (a) the visibility_context_id /
  # snapshot_fingerprint differ by viewer where the visible set differs, and
  # (b) the cached payload B reads back reflects B's effort, not A's.

  def test_case3_cache_key_isolated_no_cross_user_bleed
    own_role = create_role!(name: 'LeakCacheOwn', issues_visibility: 'own')
    a = create_user!(login: 'leak3_a')
    b = create_user!(login: 'leak3_b')
    add_member!(project: @p2, principal: a, role: own_role)
    add_member!(project: @p2, principal: b, role: own_role)

    # An issue visible to A (author) but not B (own + not author) -> the visible sets diverge.
    create_issue!(project: @p2, author: a, status: open_status, is_private: true,
                  created_on: Time.utc(2026, 6, 6, 0), updated_on: Time.utc(2026, 6, 6, 0))

    ctx_a = Pulse::Adapters::VisibilityContext.new(a, @p2).id
    ctx_b = Pulse::Adapters::VisibilityContext.new(b, @p2).id
    refute_equal ctx_a, ctx_b,
                 'LEAK-RISK: A and B share a visibility_context_id despite divergent visible sets — ' \
                 'a shared cache partition could serve A-only data to B'

    fp_a = Pulse::Adapters::SnapshotFingerprint.new(a, @p2, settings_provider: real_settings_provider).value
    fp_b = Pulse::Adapters::SnapshotFingerprint.new(b, @p2, settings_provider: real_settings_provider).value
    refute_equal fp_a, fp_b,
                 'LEAK-RISK: A and B share a snapshot_fingerprint despite divergent visible sets'

    # End-to-end through the cache: warm A first, then read B — B must NOT get A's row.
    store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    engine = Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: Pulse::Adapters::RedmineMetricsSource.new(
        settings_provider: real_settings_provider, clock: clock
      ),
      store: store, settings_provider: real_settings_provider, clock: clock
    )

    proj_a = engine.project_projection(a, @p2) # warms cache under ctx_a/fp_a
    proj_b = engine.project_projection(b, @p2) # must compute/serve under ctx_b/fp_b

    assert_equal 1, proj_a.metrics.effort_total,
                 "A's cached projection must count A's own private issue"
    assert_equal 0, proj_b.metrics.effort_total,
                 "LEAK: B's projection of P2 returned #{proj_b.metrics.effort_total} effort — " \
                 "the cache served A's warmed row to B (cross-user snapshot bleed)"
  end
end
