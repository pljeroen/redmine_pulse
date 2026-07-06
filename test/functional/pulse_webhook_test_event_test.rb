# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# C7 / FR-C7-09 / FC-C7-08 / AC-C7-07 / IT-C7-08 — the ADMIN-ONLY "send test event" action.
# It builds a SYNTHETIC AlertEvent (+ synthetic Project + HealthResult) OFF the domain path,
# delivers to EXACTLY ONE operator-selected endpoint via the SAME HttpWebhookDispatcher pipeline
# (HTTPS -> SSRF -> serialize -> HMAC -> POST, ~5s timeout), and SURFACES the resulting HTTP
# status (or error class) to the operator. It is the SOLE request-cycle webhook dispatch.
#
# Authorization is PINNED to User.current.admin? (require_admin) — STRICTER than the
# :view_pulse authorize_pulse ladder. A non-admin (incl. a :view_pulse-only user) is FORBIDDEN
# (403/redirect) with NO dispatch.
#
# Net::HTTP is intercepted so the action is hermetic. The test asserts EXACTLY ONE endpoint is
# contacted, and the surfaced status matches the stubbed response. Postgres-gated for parity.
#
# RED until A9 adds the webhook_test action + route + admin gate. If the route does not exist
# yet the request 404s / raises — a legitimate RED signal (the action is absent).
class PulseWebhookTestEventTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  ENDPOINT = { 'url' => 'https://hooks.example/pulse', 'secret' => 'sekret',
               'enabled' => true, 'event_filter' => [], 'ssrf_override' => true }.freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'WhTeRole', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @admin = create_user!(login: 'wh_admin', admin: true)
    @viewer = create_user!(login: 'wh_viewer') # holds :view_pulse but is NOT admin
    @project = create_project!(name: 'WhTeP', identifier: 'wh-te-p')
    add_member!(project: @project, principal: @viewer, role: @role)
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_webhook_endpoints_global' => [ENDPOINT]
    )
  end

  def login_as(user)
    post '/login', params: { username: user.login, password: 'password' }
  rescue StandardError
    User.current = user
  end

  # A recording Net::HTTP double that mirrors the WH-01 instance seam the production
  # transport now uses: Net::HTTP.new(host, port) -> #ipaddr=/#open_timeout=/#read_timeout=/
  # #use_ssl=/#verify_mode= -> INSTANCE #start { |conn| conn.request(req) }. Records each POST
  # and returns the scripted response (or RAISES a genuine timeout from #start when hung).
  class CapturingHttp
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout
    attr_reader :address, :port

    def initialize(address, port, posts:, resp:, hang:)
      @address = address
      @port = port
      @posts = posts
      @resp = resp
      @hang = hang
    end

    def use_ssl?
      @use_ssl == true
    end

    def start
      # A hung endpoint surfaces a GENUINE timeout error class (not a resolution error and
      # not a hang) within the bounded budget — the dispatcher retries and dead-letters.
      raise Net::ReadTimeout if @hang

      yield self
    end

    def request(_req)
      @posts << :post
      @resp
    end
  end

  # Intercept outbound HTTP at the NEW instance seam; record how many POSTs and return the
  # scripted status. Stubs Net::HTTP.new (the class method the transport calls) so the real
  # instance #start/#request never touch the network or DNS — fully hermetic.
  def with_http(status:, hang: false)
    posts = []
    resp = Net::HTTPResponse::CODE_TO_OBJ[status].new('1.1', status, 'X')
    resp.instance_variable_set(:@read, true)
    Net::HTTP.stub(:new, ->(addr, prt) { CapturingHttp.new(addr, prt, posts: posts, resp: resp, hang: hang) }) do
      yield(posts)
    end
  end

  # POST the test-event action. The exact route/param names are A9's to finalize; the test
  # pins the CONTRACT: an admin POST that names one endpoint (index 0) triggers one delivery.
  def post_test_event(endpoint_index: 0)
    post '/pulse/webhook_test', params: { endpoint: endpoint_index }
  end

  # ── (b) NON-admin is FORBIDDEN, no dispatch ─────────────────────────────────
  def test_non_admin_viewer_is_forbidden_no_dispatch
    login_as(@viewer)
    with_http(status: '200') do |posts|
      post_test_event
      assert_includes [403, 302], response.status,
                      'a non-admin (:view_pulse only) must be FORBIDDEN (403 or redirect) — admin gate'
      assert_empty posts, 'no webhook dispatch for a non-admin (require_admin gate)'
    end
  end

  def test_anonymous_is_forbidden_no_dispatch
    with_http(status: '200') do |posts|
      post_test_event
      assert_includes [403, 302, 401], response.status, 'anonymous must not reach the admin action'
      assert_empty posts, 'no dispatch for anonymous'
    end
  end

  # ── (a) admin POST against a 200 stub ⇒ surfaces 200; exactly ONE endpoint ──
  def test_admin_post_surfaces_200_and_contacts_exactly_one_endpoint
    login_as(@admin)
    with_http(status: '200') do |posts|
      post_test_event
      assert_equal 1, posts.size, 'EXACTLY ONE endpoint is contacted (the selected one), not the full list'
      assert_match(/200/, response.body.to_s + flash.to_hash.values.join(' '),
                   'the action SURFACES the resulting HTTP status (200) to the operator')
    end
  end

  def test_admin_post_surfaces_503
    login_as(@admin)
    with_http(status: '503') do |_posts|
      post_test_event
      assert_match(/503/, response.body.to_s + flash.to_hash.values.join(' '),
                   'a 503 upstream is surfaced to the operator')
    end
  end

  # ── hung endpoint ⇒ surfaces a timeout error class within the bounded budget ─
  def test_admin_post_hung_endpoint_surfaces_timeout_error_within_budget
    login_as(@admin)
    with_http(status: '200', hang: true) do |_posts|
      started = Time.now
      post_test_event
      elapsed = Time.now - started
      surfaced = response.body.to_s + flash.to_hash.values.join(' ')
      assert_match(/timeout|ReadTimeout|OpenTimeout/i, surfaced,
                   'a hung endpoint surfaces the timeout error class (not a hang)')
      assert_operator elapsed, :<, 60, 'the request returns within a bounded budget (does not hang)'
    end
  end
end
