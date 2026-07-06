# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# C7 / FR-C7-02 / FR-C7-04 / FC-C7-02 / FC-C7-04 (TIER-1 + additive wiring) — the LOAD-BEARING
# off-by-default falsifier PLUS the additive-alongside-email wiring, exercised through the real
# scan_and_alert composition root on the Redmine harness.
#
# IT-C7-01 (off-by-default): with EMPTY webhook endpoint settings (the shipped state), a scan
#   that PRODUCES AlertEvents (green->amber) makes ZERO outbound HTTP — Net::HTTP is intercepted
#   and asserted NEVER invoked. This proves the empty-list STRUCTURAL short-circuit, not merely
#   "no events". advance_state still runs (state advances to amber).
# IT-C7-09 (additive wiring): with a configured+enabled mocked endpoint, the SAME transition scan
#   dispatches a webhook ALONGSIDE the C6 email path; the email path is invoked unchanged and
#   advance_state runs even when the webhook dead-letters.
#
# Net::HTTP is intercepted at the INSTANCE-construction seam (Net::HTTP.new) — the WH-01
# transport path (Net::HTTP.new(host,port) -> #start { |c| c.request(req) }) — so ANY real
# outbound attempt is caught regardless of how the adapter constructs the request; a genuine
# structural falsifier. The OFF arm ALSO guards Net::HTTP.new (raise-on-new) so the
# zero-outbound falsifier bites under the new seam: with the empty (shipped) config no
# endpoint is ever constructed, so the guard never fires and the arm stays GREEN.
#
# Postgres-gated for parity with the sibling alert integration suites. RED until A9 wires the
# dispatcher into ScanAndAlert.run and adds the OFF-by-default settings keys.
class PulseWebhookDefaultOffTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @role = create_role!(name: 'WhViewer', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @project = create_project!(name: 'WhP', identifier: 'wh-p')
    @author = create_user!(login: 'wh_author')
    add_member!(project: @project, principal: @author, role: @role)
    create_issue!(project: @project, author: @author, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def alert_store
    Pulse::Adapters::ActiveRecordAlertStateStore.new
  end

  def seed_green_baseline!
    alert_store.upsert(@project.id, last_rag: 'green', last_dominant: 'staleness',
                       last_no_data: false, last_score: 80.0)
  end

  def add_watcher!(login)
    u = create_user!(login: login)
    add_member!(project: @project, principal: u, role: @role)
    Pulse::Adapters::RedmineSubscriptionStore.new.watch!(u, @project)
    u
  end

  # A recording Net::HTTP double mirroring the WH-01 instance seam the transport now uses:
  # Net::HTTP.new(host,port) -> #ipaddr=/#open_timeout=/#read_timeout=/#use_ssl=/#verify_mode=
  # -> INSTANCE #start { |conn| conn.request(req) }. Records each POST and returns the scripted
  # response, or RAISES a scripted error from #start (e.g. a connection refusal for dead-letter).
  class CapturingHttp
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout
    attr_reader :address, :port

    def initialize(address, port, posts:, resp:, raise_error: nil)
      @address = address
      @port = port
      @posts = posts
      @resp = resp
      @raise_error = raise_error
    end

    def use_ssl?
      @use_ssl == true
    end

    def start
      raise(*@raise_error) if @raise_error

      yield self
    end

    def request(_req)
      @posts << :post
      @resp
    end
  end

  # ── IT-C7-01: OFF BY DEFAULT — events fire, ZERO outbound HTTP ──────────────
  def test_events_fire_but_zero_outbound_http_when_no_endpoints_configured
    add_watcher!('off_w')
    seed_green_baseline!
    # Explicitly assert the shipped default is empty (no endpoints).
    settings = Setting.plugin_redmine_pulse
    assert(settings['pulse_webhook_endpoints_global'].nil? ||
           Array(settings['pulse_webhook_endpoints_global']).empty?,
           'global webhook endpoints default empty (OFF)')

    net_calls = []
    # A minimal interceptor: any Net::HTTP construction (the WH-01 transport seam) is a
    # violation — with the empty (shipped) config no endpoint is constructed, so this never
    # fires. Guard BOTH the new-instance seam and the legacy class-method .start so the
    # zero-outbound falsifier bites regardless of transport shape.
    guard = ->(*_a, **_k, &_b) { net_calls << :outbound; flunk 'no outbound HTTP with empty endpoint config' }
    Net::HTTP.stub(:new, guard) do
      Net::HTTP.stub(:start, guard) do
        events = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
        assert_equal 1, events.size, 'the scan PRODUCED an AlertEvent (green->amber) — load-bearing'
        assert_equal :rag_transition, events.first.event_type
      end
    end
    assert_empty net_calls, 'ZERO outbound HTTP with the empty (shipped) endpoint config (FC-C7-02)'
    # advance_state still ran.
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag]
  end

  # ── IT-C7-09: additive — webhook dispatch alongside email on a transition ───
  def test_webhook_dispatched_alongside_email_on_transition
    add_watcher!('on_w')
    seed_green_baseline!
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_webhook_endpoints_global' => [
        { 'url' => 'https://hooks.example/pulse', 'secret' => 'sekret',
          'enabled' => true, 'event_filter' => [], 'ssrf_override' => true }
      ]
    )

    posts = []
    ok = Net::HTTPResponse::CODE_TO_OBJ['200'].new('1.1', '200', 'OK')
    ok.instance_variable_set(:@read, true)
    Net::HTTP.stub(:new, ->(addr, prt) { CapturingHttp.new(addr, prt, posts: posts, resp: ok) }) do
      events = Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
      assert_equal 1, events.size, 'a transition event was produced'
    end
    refute_empty posts, 'a webhook POST occurred alongside email (additive wiring, FC-C7-04)'
    assert_operator ActionMailer::Base.deliveries.size, :>=, 1,
                    'the C6 email path is still invoked unchanged (email delivered to the watcher)'
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'advance_state runs regardless of webhook outcome (OI-C6-01 / GR-05)'
  end

  # ── advance_state runs even when the webhook dead-letters (delivery does not gate state) ─
  def test_advance_state_runs_even_when_webhook_dead_letters
    add_watcher!('dl_w')
    seed_green_baseline!
    Setting.plugin_redmine_pulse = Setting.plugin_redmine_pulse.merge(
      'pulse_webhook_endpoints_global' => [
        { 'url' => 'https://hooks.example/pulse', 'secret' => 'sekret',
          'enabled' => true, 'event_filter' => [], 'ssrf_override' => true }
      ]
    )

    # Every outbound attempt raises (via the instance #start seam) — the dispatcher must
    # dead-letter (never propagate) and advance_state must still run.
    posts = []
    Net::HTTP.stub(:new, ->(addr, prt) do
      CapturingHttp.new(addr, prt, posts: posts, resp: nil,
                                   raise_error: [Errno::ECONNREFUSED, 'refused'])
    end) do
      assert_nothing_raised do
        Pulse::Tasks::ScanAndAlert.run(project_ids: [@project.id], force_rag: :amber)
      end
    end
    assert_equal 'amber', alert_store.find_by_project(@project.id)[:last_rag],
                 'state advances even when the webhook dead-letters (best-effort, GR-05)'
  end
end
