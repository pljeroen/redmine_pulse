# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Project-list badge — SERVER-SIDE (Ruby-testable) coverage
# of the server-inline mechanism. The browser-side DOM decoration is verified
# separately; THIS suite covers the Ruby half:
#
#   GATE          — the ViewListener emits the stylesheet tag,
#                   the project_list_badge JS tag, AND the inlined
#                   <script id="pulse-portfolio-data"> data blob IFF
#                   (projects#index) AND global view_pulse; emits '' otherwise.
#   INLINE-BLOB   — server side: the blob is
#                   valid JSON, viewer-scoped, carries identifier/rag/main_concern.
#   INLINE-XSS    — a project named '</script>...' is escaped
#                   (ERB::Util.json_escape) so it cannot break out of the <script>;
#                   the blob still JSON.parses to the correct (un-escaped) value.
#   FAILSILENT    — when the engine raises inside the hook, the
#                   hook returns '' (no blob, no tag) and /projects still renders.
#
# The hook is RedminePulseHooks (a Redmine::Hook::ViewListener) responding to
# view_layouts_base_html_head(context). The context carries :controller/:request/:project
# (grounded from Redmine 6.1.2 lib/redmine/hook.rb Helper#call_hook default_context).
#
# Requires lib/redmine_pulse/hooks.rb. Runs on PostgreSQL (the
# blob-content + viewer-scoping cases need the real engine + a snapshot store on Postgres).
class ProjectListBadgeHookTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  BLOB_ID = 'pulse-portfolio-data'
  HEAD_HOOK = :view_layouts_base_html_head

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # Postgres-only evidence lane (mirrors api_schema_test / pulse_controller_test): the
    # blob-content + write-capture cases need the real snapshot store on Postgres. On a
    # non-Postgres adapter these are skips, not failures, so the other CI legs stay green.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'BadgeAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'badgeuser')
    @project = create_project!(name: 'Badged', identifier: 'badge-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # The hook listener instance (RedminePulseHooks is a Singleton ViewListener).
  def listener
    RedminePulseHooks.instance
  end

  # A stub controller exposing the controller_name/action_name the gate reads, plus a
  # render-capable surface (the ViewListener may render through context[:hook_caller]).
  def stub_controller(controller_name:, action_name:)
    Struct.new(:controller_name, :action_name).new(controller_name, action_name)
  end

  # Build the hook context the way Redmine 6.1.2's call_hook does for a view hook
  # (default_context = {:controller, :project, :request, :hook_caller}).
  def hook_context(controller_name:, action_name:, project: nil)
    ctrl = stub_controller(controller_name: controller_name, action_name: action_name)
    { controller: ctrl, action_name: action_name, controller_name: controller_name,
      project: project, request: ActionDispatch::TestRequest.create, hook_caller: ctrl }
  end

  # Run the hook with User.current temporarily set to `user`, restoring after.
  def emit_as(user, ctx)
    prior = User.current
    User.current = user
    listener.public_send(HEAD_HOOK, ctx).to_s
  ensure
    User.current = prior || User.anonymous
  end

  def blob_json(html)
    m = html[%r{<script[^>]*id="#{BLOB_ID}"[^>]*>(.*?)</script>}m]
    refute_nil m, "emitted head must contain a <script id=\"#{BLOB_ID}\"> blob:\n#{html}"
    body = Regexp.last_match(1)
    JSON.parse(body)
  end

  # ── GATE : the hook is a registered ViewListener on the head hook ──

  def test_hook_is_registered_view_listener_on_base_html_head
    assert defined?(RedminePulseHooks),
           'RedminePulseHooks must be defined (lib/redmine_pulse/hooks.rb)'
    assert_operator RedminePulseHooks.ancestors.map(&:to_s).join(','), :include?,
                    'Redmine::Hook::ViewListener',
                    'RedminePulseHooks MUST be a Redmine::Hook::ViewListener'
    assert listener.respond_to?(HEAD_HOOK),
           "the listener MUST respond to #{HEAD_HOOK} (the head hook the badge emits on)"
    registered = Redmine::Hook.hook_listeners(HEAD_HOOK)
    assert(registered.any? { |l| l.is_a?(RedminePulseHooks) },
           "RedminePulseHooks MUST be registered as a #{HEAD_HOOK} listener (inherit ViewListener)")
  end

  # POSITIVE: projects#index + permitted user -> all THREE emissions present.
  def test_emits_three_things_on_projects_index_for_permitted_user
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    html = emit_as(@user, ctx)

    assert_match(%r{<script[^>]*src="[^"]*project_list_badge[^"]*"}, html,
                 'gate.positive: the project_list_badge JS <script> tag MUST be emitted')
    assert_match(%r{<link[^>]*href="[^"]*redmine_pulse[^"]*\.css}, html,
                 'gate.positive: the redmine_pulse stylesheet <link> tag MUST be emitted')
    assert_match(%r{<script[^>]*id="#{BLOB_ID}"[^>]*type="application/json"}m, html,
                 'gate.positive: the inlined <script id="pulse-portfolio-data"> blob MUST be emitted')
  end

  # The blob is valid JSON carrying the viewer's visible projects with the badge shape.
  def test_blob_is_valid_json_with_identifier_rag_and_main_concern
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    data = blob_json(emit_as(@user, ctx))

    projects = data.is_a?(Hash) ? data['projects'] : data
    refute_nil projects, "the blob MUST expose a projects collection (got keys #{data.is_a?(Hash) ? data.keys.inspect : data.class})"
    row = projects.find { |p| p['identifier'] == 'badge-proj' }
    refute_nil row, 'the permitted viewer\'s visible project MUST appear in the inline blob'
    %w[identifier rag main_concern].each do |field|
      assert row.key?(field), "each blob entry MUST carry #{field.inspect}"
    end
    assert_equal 'badge-proj', row['identifier']
    assert_includes %w[green amber red no_data], row['rag'], 'rag is the verbatim RAG state'
  end

  # CONTRAPOSITIVE (permission): unpermitted viewer -> NOTHING (no leak).
  def test_emits_nothing_for_unpermitted_user_on_projects_index
    outsider = create_user!(login: 'badgeoutsider') # holds no view_pulse anywhere
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    html = emit_as(outsider, ctx)

    assert_equal '', html.strip,
                 'gate.contra_perm: an unpermitted viewer MUST get NO tags and NO blob ' \
                 "(no portfolio computed -> no leak). got: #{html.inspect}"
  end

  def test_emits_nothing_for_anonymous_on_projects_index
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    html = emit_as(User.anonymous, ctx)
    assert_equal '', html.strip,
                 'gate.contra_perm: anonymous (no view_pulse) MUST get nothing'
  end

  # CONTRAPOSITIVE (route): projects#show -> NOTHING even for a permitted user.
  def test_emits_nothing_on_projects_show_even_for_permitted_user
    ctx = hook_context(controller_name: 'projects', action_name: 'show', project: @project)
    html = emit_as(@user, ctx)
    assert_equal '', html.strip,
                 'gate.contra_route: projects#show is NOT projects#index -> emit nothing'
  end

  # CONTRAPOSITIVE (route): a non-projects controller -> NOTHING even for a permitted user.
  def test_emits_nothing_on_other_controller_even_for_permitted_user
    ctx = hook_context(controller_name: 'issues', action_name: 'index')
    html = emit_as(@user, ctx)
    assert_equal '', html.strip,
                 'gate.contra_route: a non-(projects#index) page -> emit nothing'
  end

  # ── INLINE-XSS : the blob cannot break out of its <script> ─────────

  def test_inline_blob_escapes_script_close_and_still_parses
    evil = '</script><img src=x onerror=alert(1)>'
    proj = create_project!(name: evil, identifier: 'badge-xss')
    add_member!(project: proj, principal: @user, role: @role)
    create_issue!(project: proj, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))

    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    html = emit_as(@user, ctx)

    # The raw <script id="pulse-portfolio-data"> body must NOT contain a literal,
    # UN-escaped '</script' (ERB::Util.json_escape turns '<' into '<'). If it did,
    # the browser would terminate the script element early and the injected <img> would
    # become live markup. Isolate the blob element body and scan it.
    body = html[%r{<script[^>]*id="#{BLOB_ID}"[^>]*>(.*?)</script>}m, 1]
    refute_nil body, 'the blob element must be present'
    refute_match(%r{</script}i, body,
                 'inline-xss: the inlined JSON MUST be ERB::Util.json_escape\'d so no ' \
                 'literal </script breaks out of the <script id="pulse-portfolio-data"> element')
    # No injected live <img> markup anywhere in the emitted head.
    refute_match(/<img[^>]*onerror/i, html,
                 'inline-xss: a malicious project name MUST NOT inject live <img> markup')

    # And the escaped blob still decodes to the EXACT original name (correctness preserved).
    data = blob_json(html)
    projects = data.is_a?(Hash) ? data['projects'] : data
    row = projects.find { |p| p['identifier'] == 'badge-xss' }
    refute_nil row, 'the xss-named project must still be present in the parsed blob'
    assert_equal evil, row['name'], 'JSON.parse of the escaped blob recovers the exact name' if row.key?('name')
  end

  # ── FAILSILENT (server layer) : engine raise -> '' ────────────────────

  def test_hook_returns_empty_string_when_engine_raises
    ctx = hook_context(controller_name: 'projects', action_name: 'index')

    # Inject a failing collaborator: make the engine's portfolio_projections raise for the
    # duration of this hook call. The hook MUST wrap its computation in begin/rescue and
    # return '' (fail-silent, server layer) — never propagate.
    engine_klass = Pulse::Adapters::PulseProjection::Engine
    engine_klass.class_eval do
      alias_method :__orig_portfolio_projections, :portfolio_projections
      def portfolio_projections(_user)
        raise 'injected engine failure (fail-silent server test)'
      end
    end

    html = nil
    assert_nothing_raised('the hook MUST NOT propagate an engine error') do
      html = emit_as(@user, ctx)
    end
    assert_equal '', html.to_s.strip,
                 'fail-silent: on ANY engine error the hook MUST return \'\' (no blob, no tag)'
  ensure
    engine_klass.class_eval do
      remove_method :portfolio_projections
      alias_method :portfolio_projections, :__orig_portfolio_projections
      remove_method :__orig_portfolio_projections
    end
  end

  # Integration confirmation: a real GET /projects as the permitted user still renders the
  # three emissions in <head> (the hook is wired into Redmine's base layout).
  def test_live_projects_index_head_carries_badge_assets_and_blob
    post '/login', params: { username: @user.login, password: 'password' }
    get '/projects'
    assert_response :success
    assert_select "script##{BLOB_ID}", { count: 1 },
                  'live /projects head MUST inline exactly one pulse-portfolio-data blob'
    assert_match(%r{project_list_badge}, response.body,
                 'live /projects head MUST include the project_list_badge JS asset')
  end
end
