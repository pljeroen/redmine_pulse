# frozen_string_literal: true

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# CA-10/11/12/20/21/22/24/26 + FC-CA-10b/11b/12b/26/24det/CA-RAG-A11Y +
# COND-A8-002/003/004: PulseController HTML surfaces — portfolio overview, panel,
# refresh POST. Drives real HTTP through the Redmine harness and asserts OBSERVABLE
# POST-STATE (rendered markup + snapshot rows + write-set), not just status codes.
#
# COND-A8-004: PostgreSQL 16 gate. Postgres-gated (FC-CA-38). RED until A9.
class PulseControllerTest < ActionDispatch::IntegrationTest
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
    @clock_date = Date.new(2026, 6, 20)
    @role = create_role!(name: 'CtlAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'ctluser')
    @project = create_project!(name: 'Ctl', identifier: 'ctl-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  def snapshot_count(project)
    ActiveRecord::Base.connection
                      .select_value("SELECT COUNT(*) FROM pulse_snapshots WHERE project_id = #{project.id.to_i}")
                      .to_i
  end

  # RT-06: count rows for one (project, visibility_context_id) cell.
  def ctx_rows(project, ctx)
    ActiveRecord::Base.connection
                      .select_value(
                        "SELECT COUNT(*) FROM pulse_snapshots " \
                        "WHERE project_id = #{project.id.to_i} " \
                        "AND visibility_context_id = #{ActiveRecord::Base.connection.quote(ctx)}"
                      ).to_i
  end

  # RT-06: a minimal JSON-safe payload for a directly-seeded foreign-context row.
  def foreign_payload(project)
    { 'project_id' => project.id, 'reference_date' => '2026-06-10',
      'effort_open' => 0, 'effort_total' => 0, 'risk_raw' => 0,
      'blocked_count' => 0, 'risk_mapped' => false, 'effort_mapped' => false,
      'event_series' => [], 'version_due_dates' => [], 'last_activity_at' => nil }
  end

  # ─────────────────────────── INDEX (FC-CA-10b) ────────────────────────────

  def test_index_renders_visible_project_row
    login_as(@user)
    get '/pulse'
    assert_response :success
    assert_select 'body', text: /#{Regexp.escape(@project.name)}/
  end

  def test_index_omits_unpermitted_project
    other = create_project!(name: 'Hidden', identifier: 'hidden-proj')
    # @user is NOT a member of `other` -> must not appear.
    login_as(@user)
    get '/pulse'
    assert_response :success
    assert_no_match(/#{Regexp.escape(other.name)}/, response.body,
                    'a project the viewer cannot see is silently omitted')
  end

  def test_index_empty_portfolio_renders_empty_state_200
    outsider = create_user!(login: 'noproj')
    login_as(outsider)
    get '/pulse'
    assert_response :success, 'empty portfolio -> 200, never 404'
    refute_empty response.body
  end

  def test_index_displays_computed_at_ago
    login_as(@user)
    get '/pulse'
    assert_response :success
    # computed_at rendered as a "computed N <unit> ago" string (provenance computed).
    assert_match(/computed/i, response.body,
                 'computed_at must be displayed as a "computed N ... ago" string')
  end

  def test_index_lens_selector_offers_exactly_five_lenses
    login_as(@user)
    get '/pulse'
    assert_response :success
    %w[health at_risk stale done blocked].each do |lens|
      assert_match(/#{lens}/, response.body, "lens selector must offer the #{lens} lens")
    end
  end

  def test_index_lens_param_reranks_not_rescores
    p2 = create_project!(name: 'Ctl2', identifier: 'ctl2-proj')
    add_member!(project: p2, principal: @user, role: @role)
    create_issue!(project: p2, author: @user, status: open_status,
                  updated_on: Time.utc(2026, 1, 1, 0))
    login_as(@user)
    get '/pulse', params: { lens: 'health' }
    assert_response :success
    health_body = response.body
    get '/pulse', params: { lens: 'stale' }
    assert_response :success
    # Re-rank changes ordering but NOT the per-project health_score (no re-score):
    # both projects still appear under either lens.
    [@project.name, p2.name].each do |n|
      assert_match(/#{Regexp.escape(n)}/, health_body)
      assert_match(/#{Regexp.escape(n)}/, response.body)
    end
  end

  def test_index_shows_permission_visibility_banner
    login_as(@user)
    get '/pulse'
    assert_response :success
    # HTML banner localized via I18n.t(:label_pulse_visibility_note) (D-CA-OQ01 HTML side).
    assert_match(/visible to you/i, response.body,
                 'visibility banner (HTML, localized) must be present')
  end

  # ─────────────────────────── SHOW (FC-CA-11b) ─────────────────────────────

  def test_show_renders_all_five_signals
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    %w[staleness progress momentum risk_load blocked_load].each do |sig|
      assert_match(/#{sig}/, response.body, "signal #{sig} must be rendered in the panel")
    end
  end

  def test_show_inactive_signal_present_with_enable_hint
    # No risk tracker mapped -> risk_load inactive. It MUST still appear (active:false)
    # with an enable-hint (CA-26 / FC-CA-26), never omitted.
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_match(/risk_load/, response.body, 'inactive risk_load row must be present')
    assert_match(/enable|map a risk tracker|inactive/i, response.body,
                 'inactive signal must carry an enable-hint')
  end

  def test_show_displays_computed_at_and_completeness
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_match(/computed/i, response.body, 'computed_at shown on the panel')
  end

  def test_show_renders_forward_milestone_when_version_due
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_match(/v1\.0/, response.body, 'forward milestone rendered from a Version due date')
  end

  def test_show_renders_gantt_deep_link_when_viewer_allowed
    # A viewer with :view_gantt on a project whose :gantt module is enabled gets a
    # deep-link to Redmine's built-in project Gantt.
    role = create_role!(name: 'GanttRole', permissions: %i[view_issues view_pulse view_gantt])
    user = create_user!(login: 'ganttuser')
    project = create_project!(name: 'GanttProj', identifier: 'gantt-proj',
                              modules: %w[issue_tracking pulse gantt repository])
    add_member!(project: project, principal: user, role: role)
    create_issue!(project: project, author: user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    login_as(user)
    get "/projects/#{project.identifier}/pulse"
    assert_response :success
    assert_select 'a.pulse-gantt[href=?]', "/projects/#{project.identifier}/issues/gantt"
  end

  def test_show_omits_gantt_link_when_viewer_not_allowed
    # The default @role lacks :view_gantt and @project lacks the :gantt module, so
    # allowed_to?(:view_gantt) is false — no link is offered (it would 403 on click).
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_select 'a.pulse-gantt', false,
                  'no Gantt link when the viewer lacks :view_gantt / the :gantt module'
  end

  def test_show_no_invented_forward_milestone_without_versions
    # @project has NO versions -> forward axis MUST be empty (no invented date).
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    refute_match(/projected|estimated/i, response.body,
                 'no projected/estimated date class may appear (INV-NO-INVENTED-DATES)')
  end

  # ─────────────────── RAG ACCESSIBILITY (CA-RAG-A11Y / D-CA-OQ04) ───────────

  def test_show_rag_chip_carries_non_color_cue_and_aria_label
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    # The RAG state must be perceivable WITHOUT color (WCAG 1.4.1): a visible
    # localized health word/letter AND an accessible label.
    rag_words = [I18n.t(:label_pulse_rag_red), I18n.t(:label_pulse_rag_amber),
                 I18n.t(:label_pulse_rag_green)]
    assert rag_words.any? { |w| response.body.include?(w) },
           'RAG chip must carry a non-color localized health-word cue'
    assert_match(/aria-label|title=/, response.body,
                 'RAG chip must carry an accessible label, not color alone')
  end

  def test_index_rag_chip_carries_non_color_cue
    login_as(@user)
    get '/pulse'
    assert_response :success
    assert_match(/aria-label|title=/, response.body,
                 'portfolio-row RAG chip must carry an accessible label (D-CA-OQ04)')
  end

  # ─────────────────────────── REFRESH (FC-CA-12b) ──────────────────────────

  def test_refresh_invalidates_only_target_project_snapshots
    other = create_project!(name: 'CtlB', identifier: 'ctlb-proj')
    add_member!(project: other, principal: @user, role: @role)
    create_issue!(project: other, author: @user, status: open_status)
    login_as(@user)
    # Warm both snapshots via a GET.
    get "/projects/#{@project.identifier}/pulse"
    get "/projects/#{other.identifier}/pulse"
    assert_operator snapshot_count(@project), :>=, 1, 'target had a warm snapshot'
    before_other = snapshot_count(other)

    post '/pulse/refresh', params: { project_id: @project.identifier }
    assert_equal 0, snapshot_count(@project), 'refresh deletes the target project snapshots'
    assert_equal before_other, snapshot_count(other),
                 'refresh MUST NOT touch a different project (per-project scope, CD-CA-04)'
  end

  # ── RT-06 (security-S2-dos): caller-SCOPED refresh (cross-context blast radius) ──
  # POST /pulse/refresh currently calls store.invalidate_project(project.id), which deletes
  # EVERY pulse_snapshots row for the project across ALL visibility contexts — so any single
  # authorized viewer can evict every other viewer's warmed snapshot for that project (a
  # cross-tenant cache-stampede / amplification lever). The intended fix scopes the delete to
  # the ACTING user's own visibility_context_id, leaving other contexts' rows intact. RED now:
  # both the caller's ctx row AND a foreign ctx row are deleted.
  def test_refresh_deletes_only_the_callers_visibility_context
    login_as(@user)
    # (1) Warm the caller's OWN snapshot cell via a GET (creates a row under the acting
    # user's resolved visibility_context_id).
    get "/projects/#{@project.identifier}/pulse"
    caller_ctx = Pulse::Adapters::VisibilityContext.new(@user, @project).id
    assert_equal 1, ctx_rows(@project, caller_ctx), 'precondition: caller ctx has a warm row'

    # (2) Seed a DIFFERENT visibility context's row for the SAME project directly via the
    # store (a foreign viewer's cell). Its ctx id must differ from the caller's.
    foreign_ctx = "#{caller_ctx}-FOREIGN"
    refute_equal caller_ctx, foreign_ctx
    store = Pulse::Adapters::ActiveRecordSnapshotStore.new
    store.store(@project.id, foreign_ctx, 'fpForeign', foreign_payload(@project))
    assert_equal 1, ctx_rows(@project, foreign_ctx), 'precondition: foreign ctx has a row'

    # (3) POST /pulse/refresh as the caller. Only the caller's ctx row(s) may be evicted.
    post '/pulse/refresh', params: { project_id: @project.identifier }

    assert_equal 0, ctx_rows(@project, caller_ctx),
                 'refresh must evict the acting caller\'s own visibility-context row(s)'
    assert_equal 1, ctx_rows(@project, foreign_ctx),
                 'refresh MUST NOT delete a DIFFERENT visibility context\'s row for the same ' \
                 'project — the blast radius is the caller\'s context only (RT-06)'
  end

  def test_refresh_redirects_with_flash_notice
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    post '/pulse/refresh', params: { project_id: @project.identifier }
    assert_response :redirect
    assert_not_nil flash[:notice], 'refresh surfaces an I18n flash notice (consequence stated)'
  end

  def test_refresh_403_without_view_pulse
    role = create_role!(name: 'RefNoPulse', issues_visibility: 'all',
                        permissions: %i[view_issues])
    u = create_user!(login: 'refnopulse')
    add_member!(project: @project, principal: u, role: role)
    login_as(u)
    post '/pulse/refresh', params: { project_id: @project.identifier }
    assert_response :forbidden, 'refresh without view_pulse -> 403'
  end

  def test_refresh_writes_no_redmine_domain_table
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse" # warm
    writes = capture_write_statements do
      post '/pulse/refresh', params: { project_id: @project.identifier }
    end
    assert_equal [], writes,
                 "refresh writes only pulse_snapshots, zero Redmine-domain writes (got: #{writes.inspect})"
  end

  def test_refresh_is_idempotent_on_empty_project
    login_as(@user)
    # No warm snapshot -> deleting zero rows must not error.
    post '/pulse/refresh', params: { project_id: @project.identifier }
    assert_includes [302, 303], response.status, 'idempotent refresh on empty -> redirect, no error'
  end

  def test_refresh_csrf_tokenless_post_rejected
    # A raw POST with CSRF protection enabled (no valid token) must be rejected by Rails.
    login_as(@user)
    ActionController::Base.allow_forgery_protection = true
    post '/pulse/refresh', params: { project_id: @project.identifier },
                           headers: { 'X-CSRF-Token' => 'bogus' }
    assert_includes [403, 422], response.status, 'CSRF-tokenless POST rejected'
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  # ─────────────── READ-ONLY runtime write-set guard (FC-CA-11) ──────────────

  def test_get_index_writes_no_redmine_domain_table
    login_as(@user)
    writes = capture_write_statements do
      get '/pulse'
    end
    assert_equal [], writes,
                 "GET /pulse writes no Redmine domain table (got: #{writes.inspect})"
  end

  def test_get_show_writes_no_redmine_domain_table
    login_as(@user)
    writes = capture_write_statements do
      get "/projects/#{@project.identifier}/pulse"
    end
    assert_equal [], writes,
                 "GET show writes no Redmine domain table (got: #{writes.inspect})"
  end

  # ─────────── CACHE read-miss flow: cold GET stores, warm GET no insert ──────

  def test_cold_get_stores_one_snapshot_warm_get_inserts_zero
    login_as(@user)
    assert_equal 0, snapshot_count(@project), 'cold: no snapshot yet'
    get "/projects/#{@project.identifier}/pulse"
    assert_equal 1, snapshot_count(@project), 'cold GET stores exactly one snapshot row (FC-CA-12)'
    get "/projects/#{@project.identifier}/pulse"
    assert_equal 1, snapshot_count(@project), 'warm GET (same fingerprint) inserts zero rows (FC-CA-20)'
  end

  # ─────── COND-A8-002: identity-dependent VisibilityContext cache split ───────

  def test_own_visibility_users_do_not_share_a_snapshot_cell
    # Two users under an 'own' (identity-dependent) role MUST NOT share a snapshot
    # cell — their visibility_context_id differs, so the (project_id, ctx_id) cells
    # are distinct (no cross-user leak / collapse-to-per-user).
    own_role = create_role!(name: 'OwnCtl', issues_visibility: 'own',
                            permissions: %i[view_issues view_pulse])
    u1 = create_user!(login: 'ownctl1')
    u2 = create_user!(login: 'ownctl2')
    add_member!(project: @project, principal: u1, role: own_role)
    add_member!(project: @project, principal: u2, role: own_role)
    ctx1 = Pulse::Adapters::VisibilityContext.new(u1, @project).id
    ctx2 = Pulse::Adapters::VisibilityContext.new(u2, @project).id
    refute_equal ctx1, ctx2,
                 'identity-dependent (own) roles MUST yield distinct visibility contexts (no shared cell)'

    login_as(u1)
    get "/projects/#{@project.identifier}/pulse"
    login_as(u2)
    get "/projects/#{@project.identifier}/pulse"
    # Two distinct cells (one per user) for the same project.
    distinct = ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(DISTINCT visibility_context_id) FROM pulse_snapshots WHERE project_id = #{@project.id.to_i}"
    ).to_i
    assert_operator distinct, :>=, 2,
                    'two own-visibility users must occupy two distinct snapshot cells'
  end

  def test_all_visibility_users_may_share_a_snapshot_cell
    # Two users under an identity-INDEPENDENT role (issues_visibility=all) MAY share
    # a snapshot cell — their visibility_context_id is identical.
    all_role = create_role!(name: 'AllCtlShare', issues_visibility: 'all',
                            permissions: %i[view_issues view_pulse])
    u1 = create_user!(login: 'allctl1')
    u2 = create_user!(login: 'allctl2')
    add_member!(project: @project, principal: u1, role: all_role)
    add_member!(project: @project, principal: u2, role: all_role)
    ctx1 = Pulse::Adapters::VisibilityContext.new(u1, @project).id
    ctx2 = Pulse::Adapters::VisibilityContext.new(u2, @project).id
    assert_equal ctx1, ctx2,
                 'identity-independent (all) role: users share one visibility context'
  end

  # ════════════════════════════════════════════════════════════════════════════
  # R-B UI COMPLETION (THAW-RB-001) — the aieyes-found PRESENTATION defects + the
  # R-A domain downstream (severity-first "Main concern" + no-data state). Each
  # assertion FAILS on the current views (which lack the wiring / crash on no-data)
  # for the right reason; cited current-view lines are in the RUN_LEDGER.
  # ════════════════════════════════════════════════════════════════════════════

  # ──────────── finding 2: RAG carries a COLOR class + stylesheet is linked ────

  def test_index_rag_chip_carries_color_state_class
    login_as(@user)
    get '/pulse'
    assert_response :success
    # A RAG element must carry a state-bearing COLOR class pulse-rag-{red,amber,green,
    # no_data} so CSS can color it (today "Amber"/"Green" render as plain words).
    assert_match(/pulse-rag-(?:red|amber|green|no_data)\b/, response.body,
                 'portfolio RAG element must carry a pulse-rag-{state} color class (finding 2)')
  end

  def test_show_rag_chip_carries_color_state_class
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    assert_match(/pulse-rag-(?:red|amber|green|no_data)\b/, response.body,
                 'panel RAG element must carry a pulse-rag-{state} color class (finding 2)')
  end

  def test_index_includes_plugin_stylesheet
    login_as(@user)
    get '/pulse'
    assert_response :success
    # The cockpit stylesheet must be linked so the RAG color/sparkline styling loads
    # (assets/stylesheets/ is empty today -> no <link> to a pulse stylesheet).
    assert_match(%r{<link[^>]+href="[^"]*redmine_pulse[^"]*\.css|stylesheets/redmine_pulse},
                 response.body,
                 'the portfolio page must link the plugin stylesheet (finding 2)')
  end

  # ──────────── finding 3: no raw unrounded floats in value/contribution cells ─

  def test_show_panel_has_no_long_float_in_value_cells
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    # The panel must not leak raw unrounded floats like 24.305555555555554 or
    # 0.3846153846153846 — value/weight/contribution cells must be rounded for display.
    refute_match(/\d+\.\d{6,}/, response.body,
                 'rendered panel must not contain a >=6-digit-fraction float ' \
                 '(round value/weight/contribution cells for display — finding 3)')
  end

  # ──────────── finding 4: lens selector is a WORKING control (form/submit) ────

  def test_index_lens_selector_is_a_working_form_control
    login_as(@user)
    get '/pulse'
    assert_response :success
    body = response.body
    # The lens <select id="pulse-lens"> must be a WORKING control: inside a
    # <form method="get"> (or carry an onchange that re-requests with ?lens=), so that
    # picking a lens actually re-requests. Today the <select> has no form/submit/onchange
    # -> picking a lens does nothing.
    select_in_get_form =
      body =~ %r{<form[^>]*method=["']get["'][^>]*>.*?<select[^>]*id=["']pulse-lens["'].*?</form>}m ||
      body =~ %r{<form[^>]*>.*?<select[^>]*id=["']pulse-lens["'].*?</form>}m && body =~ /method=["']get["']/i
    onchange_resubmit = body =~ /<select[^>]*id=["']pulse-lens["'][^>]*onchange=/m
    assert(select_in_get_form || onchange_resubmit,
           'the lens <select id="pulse-lens"> must be wired to re-request (inside a ' \
           '<form method="get"> or via onchange) so choosing a lens re-ranks (finding 4)')
  end

  # ──────────── finding 5: a refresh control posts to /pulse/refresh ───────────

  def test_show_renders_refresh_control
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    body = response.body
    # A refresh button/form (button_to / form) targeting POST /pulse/refresh must be
    # present — POST /pulse/refresh works but no view exposes a control for it today.
    refresh_form = body =~ %r{<form[^>]*action=["'][^"']*/pulse/refresh["'][^>]*>.*?</form>}m
    assert(refresh_form,
           'a refresh control (form/button_to to POST /pulse/refresh) must be present ' \
           'on the panel so the operator can recompute (finding 5)')
    assert_match(/#{Regexp.escape(I18n.t(:label_pulse_refresh))}/i, body,
                 'the refresh control must carry the localized Refresh label (finding 5)')
  end

  # ──────────── finding 6: sparkline is a VISUAL, not a bare numeric run ───────

  def test_show_sparkline_is_a_visual_not_bare_numbers
    login_as(@user)
    get "/projects/#{@project.identifier}/pulse"
    assert_response :success
    body = response.body
    # The sparkline must render as an inline <svg> (or a styled-bar element with a height/
    # width style), NOT a bare run of numbers like "8 26 4 0 0".
    sparkline_block = body[%r{<div[^>]*class=["'][^"']*pulse-sparkline[^"']*["'][^>]*>.*?</div>}m] || body
    has_svg = sparkline_block =~ /<svg\b/
    has_styled_bar = sparkline_block =~ /<(?:span|div|rect|i)[^>]*(?:style=["'][^"']*(?:height|width)|class=["'][^"']*spark-bar)/
    assert(has_svg || has_styled_bar,
           'the sparkline must be a visual (inline <svg> or styled bars), not a bare ' \
           'numeric run like "8 26 4 0 0" (finding 6)')
  end

  # ──────────── R-A downstream: "Main concern" relabel + lens vocabulary ───────

  def test_index_header_uses_main_concern_label_not_dominant_signal
    login_as(@user)
    get '/pulse'
    assert_response :success
    body = response.body
    # R-A relabel: the "why" column header must read the Main-concern i18n label, NOT the
    # old "Dominant signal" wording. (label_pulse_main_concern is a NEW i18n key A9 adds.)
    main_concern = I18n.t(:label_pulse_main_concern, default: 'Main concern')
    assert_match(/#{Regexp.escape(main_concern)}/, body,
                 'the portfolio "why" column header must read the Main-concern label (R-A relabel)')
    refute_match(/Dominant signal/i, body,
                 'the old "Dominant signal" wording must be replaced by "Main concern" (R-A relabel)')
  end

  def test_index_main_concern_cell_uses_lens_vocabulary
    login_as(@user)
    get '/pulse'
    assert_response :success
    body = response.body
    # The main-concern cell must render a LENS-VOCAB label (Stale / Blocked / At risk /
    # ...), not the raw domain signal key (staleness/progress/momentum/risk_load/
    # blocked_load). At least one human lens-vocab term must appear in the rendered rows.
    lens_vocab = [I18n.t(:label_pulse_lens_stale), I18n.t(:label_pulse_lens_blocked),
                  I18n.t(:label_pulse_lens_at_risk),
                  I18n.t(:label_pulse_concern_progress, default: 'Progress'),
                  I18n.t(:label_pulse_concern_momentum, default: 'Momentum')]
    assert(lens_vocab.any? { |w| body.include?(w) },
           "the main-concern cell must use lens vocabulary (Stale/Blocked/At risk/...), " \
           "not the raw domain signal key (R-A severity-first 'Main concern')")
  end

  # ──────────── momentum-broaden D2: an "On track" project renders "On track" ──

  def test_index_on_track_project_renders_on_track_label
    # A fresh, actively-net-closing project (worst active signal n >= 0.5) is the on_track
    # state: dominant_signal :on_track, main_concern "On track" (D2). The cockpit "why" cell
    # must show the localized "On track" label (single source: MainConcernLabels), NOT a
    # named signal.
    #
    # The HTML path uses the real SystemClock (Time.zone.today), so the activity window is
    # [today-30, today). Seed RELATIVE to Time.now so the scenario stays in-window over time.
    # 4 issues CREATED before the window (issue_created filtered out => opened 0) and CLOSED
    # via a REAL journaled status transition inside the window; each in-window close journal
    # contributes BOTH :issue_closed (closed +1) AND :issue_commented (comments +1) =>
    # activity 8 (base 0.5), direction +1 => momentum n 0.65 (>= 0.5). progress + risk_load
    # inactive (no effort_field / risk_trackers), blocked_load n 1.0, staleness fresh =>
    # worst active signal >= 0.5 => dominant_signal :on_track.
    ontrack = create_project!(name: 'CtlOnTrack', identifier: 'ctl-ontrack')
    add_member!(project: ontrack, principal: @user, role: @role)
    created_at = (Time.now.utc - 40 * 86_400)   # before the 30-day window => opened 0
    closed_at  = (Time.now.utc - 10 * 86_400)   # inside the window => closed + commented
    4.times do |k|
      i = create_issue!(project: ontrack, author: @user, status: open_status,
                        created_on: created_at, updated_on: created_at)
      add_close_journal!(issue: i, user: @user, from_status: open_status,
                         to_status: closed_status, at: closed_at + k * 3600)
      stamp!(i, updated_on: closed_at + k * 3600) # fresh staleness
    end
    login_as(@user)
    get '/pulse'
    assert_response :success
    on_track_label = I18n.t(:label_pulse_on_track, default: 'On track')
    assert_includes response.body, on_track_label,
                    'an on_track project must render the localized "On track" main-concern label (D2)'
  end

  # ──────────── R-A downstream: a NO-DATA project renders a "No data" state ────

  def test_index_no_data_project_renders_no_data_indicator
    # A project with ZERO issues (no effort, no events, no blockers, no risk mapping) is
    # the R-A no-data state: rag :no_data, health_score nil. It must render a distinct
    # "No data" indicator — NOT a green score and NOT a nil-crash.
    nodata = create_project!(name: 'NoDataProj', identifier: 'nodata-proj')
    add_member!(project: nodata, principal: @user, role: @role)
    login_as(@user)
    get '/pulse'
    assert_response :success, 'a no-data project must not crash the portfolio (R-A no-data)'
    body = response.body
    no_data_text = I18n.t(:label_pulse_no_data, default: 'No data')
    # The no-data row must carry the no-data indicator (text and/or pulse-rag-no_data class).
    assert(body.include?(no_data_text) || body =~ /pulse-rag-no_data\b/,
           'a no-data (0-issue) project must render a distinct "No data" indicator ' \
           '(text or pulse-rag-no_data chip), not a numeric score (R-A no-data state)')
  end

  def test_show_no_data_project_renders_no_data_state_not_nil_crash
    nodata = create_project!(name: 'NoDataShow', identifier: 'nodata-show')
    add_member!(project: nodata, principal: @user, role: @role)
    login_as(@user)
    get "/projects/#{nodata.identifier}/pulse"
    # Current panel (show.html.erb) renders `<%= @view.health_score %>` assuming non-nil
    # -> a no-data project must NOT 500 and must show the No-data state, not a score.
    assert_response :success,
                    'the per-project panel must render the no-data state, not crash on a nil ' \
                    'health_score (R-A no-data — current show.html.erb line 13 assumes a score)'
    no_data_text = I18n.t(:label_pulse_no_data, default: 'No data')
    assert(response.body.include?(no_data_text) || response.body =~ /pulse-rag-no_data\b/,
           'the no-data panel must show a distinct "No data" state (R-A no-data)')
  end
end
