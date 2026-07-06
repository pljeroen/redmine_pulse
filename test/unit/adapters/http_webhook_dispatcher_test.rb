# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'minitest/mock' # Object#stub / Class#stub — not auto-loaded standalone (WH-05).
require 'json'
require 'openssl'
require 'net/http'
require 'time'

# Pure-adapter unit lane. Run:
#   ruby -Itest -Ilib test/unit/adapters/http_webhook_dispatcher_test.rb
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/domain/alert_event'
require 'pulse/adapters/ssrf_guard'
require 'pulse/adapters/webhook_payload_serializer'
require 'pulse/adapters/http_webhook_dispatcher'

# C7 / FR-C7-05/06/07/08 + FC-C7-05/06(a,b,d)/07/09/11 — HttpWebhookDispatcher delivery
# pipeline: event_filter -> HTTPS-only -> SSRF guard -> serialize -> HMAC-sign -> POST
# with ~5s open+read timeout -> bounded ≤3 retry+backoff -> dead-letter (best-effort log,
# NO secret). This suite drives the SINGLE-endpoint primitive #deliver and the fan-out
# #dispatch, capturing the POST seam so it is hermetic (no real network). The SSRF guard is
# stubbed to a pass-through resolved IP for the non-SSRF cases (SSRF is covered in its own
# suite). Backoff sleeps are stubbed to 0 so the retry test is fast + deterministic.
#
# RED NOW: Pulse::Adapters::HttpWebhookDispatcher (and its collaborators) do not exist.
class HttpWebhookDispatcherTest < Minitest::Test
  OCC = Time.utc(2026, 7, 6, 9, 30, 0)
  SECRET = 'sentinel-secret-DO-NOT-LOG-1234567890'
  PUBLIC_IP = '93.184.216.34'

  Proj = Struct.new(:id, :identifier, :name)
  Health = Struct.new(:project_id, :health_score, :rag, :dominant_signal)

  # A recording POST double: captures (uri, body, headers, open_timeout, read_timeout)
  # and returns a scripted response (or raises a scripted error) per attempt.
  class FakePost
    attr_reader :calls, :timeouts_open, :timeouts_read

    def initialize(script:)
      @script = script # Array of ->(attempt) responses/errors, or a single value repeated
      @calls = []
      @timeouts_open = []
      @timeouts_read = []
    end

    # The dispatcher is expected to call a single injectable POST seam of the shape
    # post(uri:, body:, headers:, open_timeout:, read_timeout:) -> response (or raise).
    def call(uri:, body:, headers:, open_timeout:, read_timeout:)
      @calls << { uri: uri, body: body, headers: headers }
      @timeouts_open << open_timeout
      @timeouts_read << read_timeout
      outcome = @script.is_a?(Array) ? @script[@calls.size - 1] : @script
      outcome = outcome.call(@calls.size) if outcome.respond_to?(:call)
      raise outcome if outcome.is_a?(Exception) || (outcome.is_a?(Class) && outcome <= Exception)

      outcome # a Struct/OpenStruct-like response with #code
    end
  end

  Resp = Struct.new(:code)

  def event(event_type: :rag_transition, project_id: 42, delta: -14.0)
    Pulse::Domain::AlertEvent.new(
      project_id: project_id, event_type: event_type, from: 'green', to: 'amber',
      score: 58, previous_score: 72, delta: delta, occurred_at: OCC
    )
  end

  def project
    Proj.new(42, 'apollo', 'Apollo Platform')
  end

  def health
    Health.new(42, 58, :amber, :risk_load)
  end

  # An endpoint config in the settings shape (Hash). Defaults mirror the OFF/safe defaults.
  def endpoint(url: 'https://hooks.example/pulse', secret: SECRET, enabled: true,
               event_filter: [], ssrf_override: false, redaction: false, allow_http: false)
    { url: url, secret: secret, enabled: enabled, event_filter: event_filter,
      ssrf_override: ssrf_override, redaction: redaction, allow_http: allow_http }
  end

  # Build a dispatcher with the POST seam injected and SSRF resolving to a public IP.
  # A9's constructor MUST accept a `post:` (or equivalent) injection seam so this suite is
  # hermetic. If A9 names the seam differently the adapter is expected to still honor a
  # keyword the test passes; the test pins the contract post: ->(**) at construction.
  def build(post_seam, resolved: PUBLIC_IP, logger: nil)
    Pulse::Adapters::HttpWebhookDispatcher.new(post: post_seam, logger: logger)
      .tap { stub_ssrf_pass(resolved) }
  end

  # SSRF guard passes (returns a vetted public IP) unless a test overrides it.
  def stub_ssrf_pass(ip)
    @ssrf_stub_ip = ip
  end

  def run_deliver(dispatcher, ev, ep, **overrides)
    args = { project: project, health_result: health, previous: nil }.merge(overrides)
    Pulse::Adapters::SsrfGuard.stub(:check, ->(*_a, **_k) { @ssrf_stub_ip }) do
      dispatcher.deliver(ev, ep, **args)
    end
  end

  def no_sleep
    ->(_secs) {}
  end

  # ── HMAC over the EXACT sent bytes; single-byte mutation ⇒ digest differs (FC-C7-07) ─
  def test_hmac_signature_covers_exact_posted_body
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event, endpoint)

    call = fp.calls.first
    refute_nil call, 'a POST must have occurred'
    body = call[:body]
    sig_header = call[:headers]['X-Pulse-Signature'] || call[:headers][:'X-Pulse-Signature']
    refute_nil sig_header, 'X-Pulse-Signature header must be present'
    expected = OpenSSL::HMAC.hexdigest('SHA256', SECRET, body)
    assert_equal expected, sig_header, 'signature must be HMAC-SHA256 over the EXACT posted body'

    mutated = body.dup
    mutated[0] = (mutated[0] == 'a' ? 'b' : 'a')
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', SECRET, mutated), sig_header,
                 'mutating a single body byte must change the recomputed digest (falsifier)'
  end

  # ── in-body signature is a GENUINE receiver-recomputable HMAC over the ─────────────
  #    signature-EXCLUDED body (FC-C7-07 secondary mirror). NOT the self-referential
  #    "in-body == header" form (a keyed-hash fixed point — impossible; see T-HTTP-01
  #    for the primary control: header == HMAC over the EXACT posted bytes).
  def test_signed_body_equals_posted_body_bytes
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event, endpoint)
    body = fp.calls.first[:body]
    parsed = JSON.parse(body)
    in_body_sig = parsed['signature']
    refute_nil in_body_sig, 'the schema requires an in-body signature field'

    # Reconstruct the body a RECEIVER would sign: parse the posted JSON, DROP the
    # signature key, re-serialize in the SAME canonical form the payload is built with
    # (JSON.generate over the insertion-ordered hash — signature was appended last, so
    # dropping it reproduces the exact pre-sign bytes). Deterministic: JSON.parse
    # preserves key order, JSON.generate is canonical for a given hash.
    signature_excluded_body = JSON.generate(parsed.reject { |k, _| k == 'signature' })
    expected = OpenSSL::HMAC.hexdigest('SHA256', SECRET, signature_excluded_body)
    assert_equal expected, in_body_sig,
                 'in-body signature must be HMAC-SHA256(secret, body-without-signature) — ' \
                 'a value a receiver can independently recompute'

    # Falsifier (fail-closed): a wrong secret, or hashing the WRONG bytes (the full body
    # that CONTAINS the signature, or a tampered/empty/static value) must NOT match.
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', 'wrong-secret', signature_excluded_body),
                 in_body_sig, 'a wrong secret must not reproduce the in-body signature'
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', SECRET, body), in_body_sig,
                 'signing the FULL body (with the signature field) must not match (no fixed point)'
    tampered = signature_excluded_body.dup
    tampered[-2] = (tampered[-2] == 'a' ? 'b' : 'a')
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', SECRET, tampered), in_body_sig,
                 'mutating a body byte must change the recomputed digest (non-tautological falsifier)'
  end

  # ── ~5s open AND read timeout on every attempt (FC-C7-06b) ──────────────────
  def test_open_and_read_timeout_are_both_about_five_seconds
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event, endpoint)
    assert_in_delta 5, fp.timeouts_open.first, 1.0, 'open_timeout must be ~5s'
    assert_in_delta 5, fp.timeouts_read.first, 1.0, 'read_timeout must be ~5s'
  end

  def test_timeout_error_counts_as_an_attempt_and_does_not_hang
    fp = FakePost.new(script: ->(_n) { Net::OpenTimeout.new('slow') })
    d = build(fp)
    d.stub(:sleep, no_sleep) do
      # Must return (not hang / not raise) after the bounded retries.
      run_deliver(d, event, endpoint)
    end
    assert_equal 3, fp.calls.size, 'a hung endpoint is retried up to the ≤3 cap, then dead-lettered'
  end

  # ── HTTPS-only default + allow_http override (FC-C7-06a) ────────────────────
  def test_http_endpoint_rejected_by_default_no_post
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event, endpoint(url: 'http://plain.example/hook'))
    assert_equal 0, fp.calls.size, 'an http:// endpoint is rejected (dead-lettered) by default — NO POST'
  end

  def test_http_endpoint_permitted_with_allow_http
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event, endpoint(url: 'http://plain.example/hook', allow_http: true))
    assert_equal 1, fp.calls.size, 'allow_http:true permits the http:// POST for THAT endpoint'
  end

  # ── SSRF block is dead-lettered (not raised) by the dispatcher (FC-C7-06c wiring) ─
  def test_ssrf_block_is_dead_lettered_no_post_no_raise
    fp = FakePost.new(script: Resp.new('200'))
    d = Pulse::Adapters::HttpWebhookDispatcher.new(post: fp, logger: nil)
    Pulse::Adapters::SsrfGuard.stub(:check, ->(*_a, **_k) { raise Pulse::Adapters::SsrfGuard::BlockedTargetError, 'loopback' }) do
      # Must NOT raise out (best-effort) and must NOT POST.
      d.deliver(event, endpoint, project: project, health_result: health, previous: nil)
    end
    assert_equal 0, fp.calls.size, 'an SSRF block short-circuits before any POST'
  end

  # ── bounded ≤3 retry then dead-letter; success stops early (FC-C7-05) ───────
  def test_always_failing_endpoint_makes_exactly_three_attempts
    fp = FakePost.new(script: ->(_n) { Resp.new('503') })
    d = build(fp)
    d.stub(:sleep, no_sleep) do
      run_deliver(d, event, endpoint)
    end
    assert_equal 3, fp.calls.size, 'a permanently-5xx endpoint gets EXACTLY 3 attempts (not 4+, not unbounded)'
  end

  def test_success_on_second_attempt_stops_further_attempts
    fp = FakePost.new(script: [->(_n) { Resp.new('500') }, ->(_n) { Resp.new('200') }, ->(_n) { flunk 'attempt 3 must not run' }])
    d = build(fp)
    d.stub(:sleep, no_sleep) do
      run_deliver(d, event, endpoint)
    end
    assert_equal 2, fp.calls.size, 'a success on attempt 2 stops — no attempt 3 (stop-on-success)'
  end

  def test_deliver_never_raises_out_on_terminal_failure
    fp = FakePost.new(script: ->(_n) { RuntimeError.new('connection refused') })
    d = build(fp)
    # No assert_raises — the contract is that deliver returns normally (best-effort, GR-05).
    d.stub(:sleep, no_sleep) do
      run_deliver(d, event, endpoint)
    end
    assert_equal 3, fp.calls.size, 'a connection error is retried to the cap and then swallowed (no raise out)'
  end

  # ── event_filter: only matching event types delivered; empty = all (FC-C7-11) ─
  def test_event_filter_skips_non_matching_type
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event(event_type: :score_delta), endpoint(event_filter: [:rag_transition]))
    assert_equal 0, fp.calls.size, 'a score_delta event is NOT delivered to an endpoint filtered to :rag_transition'
  end

  def test_event_filter_delivers_matching_type
    fp = FakePost.new(script: Resp.new('200'))
    d = build(fp)
    run_deliver(d, event(event_type: :rag_transition), endpoint(event_filter: [:rag_transition]))
    assert_equal 1, fp.calls.size, 'a matching type IS delivered'
  end

  def test_empty_event_filter_delivers_all_types
    %i[rag_transition dominant_change no_data_appeared score_delta].each do |et|
      fp = FakePost.new(script: Resp.new('200'))
      d = build(fp)
      run_deliver(d, event(event_type: et), endpoint(event_filter: []))
      assert_equal 1, fp.calls.size, "empty event_filter delivers #{et}"
    end
  end

  # ── logging carries identifying fields but NEVER the secret (FC-C7-09 / RISK-C7-03) ─
  def test_failure_log_never_contains_the_secret
    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |m| logged << m.to_s }
    %i[info warn debug].each { |m| fake_logger.define_singleton_method(m) { |*| } }

    fp = FakePost.new(script: ->(_n) { Resp.new('503') })
    d = Pulse::Adapters::HttpWebhookDispatcher.new(post: fp, logger: fake_logger)
    @ssrf_stub_ip = PUBLIC_IP
    d.stub(:sleep, no_sleep) do
      run_deliver(d, event, endpoint)
    end
    joined = logged.join("\n")
    refute_empty logged, 'a terminal dead-letter must be logged (observability, FC-C7-09)'
    refute_includes joined, SECRET, 'the endpoint secret must NEVER appear in any log line (RISK-C7-03)'
    assert_match(/hooks\.example/, joined, 'the log carries the url')
    assert_match(/rag_transition/, joined, 'the log carries the event_type')
    assert_match(/\b42\b/, joined, 'the log carries the project_id')
  end

  # ── OFF-BY-DEFAULT structural short-circuit: empty endpoint list ⇒ zero POST (FC-C7-02) ─
  # (Complements the harness scan_and_alert arm; here the dispatcher-level short-circuit.)
  def test_dispatch_with_empty_endpoint_list_makes_zero_posts
    fp = FakePost.new(script: ->(_n) { flunk 'no POST may occur with an empty endpoint list' })
    d = Pulse::Adapters::HttpWebhookDispatcher.new(post: fp, logger: nil, endpoints: [])
    # dispatch fans out over the (empty) configured endpoint list — the loop body never runs.
    d.dispatch(event, project: project, health_result: health, previous: nil)
    assert_equal 0, fp.calls.size, 'empty endpoint list ⇒ ZERO Net::HTTP POSTs (structural short-circuit)'
  end

  def test_disabled_endpoint_is_skipped_entirely
    fp = FakePost.new(script: ->(_n) { flunk 'a disabled endpoint must never POST' })
    d = Pulse::Adapters::HttpWebhookDispatcher.new(post: fp, logger: nil, endpoints: [endpoint(enabled: false)])
    Pulse::Adapters::SsrfGuard.stub(:check, ->(*_a, **_k) { PUBLIC_IP }) do
      d.dispatch(event, project: project, health_result: health, previous: nil)
    end
    assert_equal 0, fp.calls.size, 'a disabled (enabled:false) endpoint is skipped entirely (FC-C7-11)'
  end

  # ── WH-01: the REAL transport (net_http_post) pins the socket to the vetted SSRF IP while ─
  #    keeping @address = the HOSTNAME, so TLS SNI + cert-hostname verification target the
  #    hostname (a real HTTPS cert, issued for the hostname, passes VERIFY_PEER) yet the
  #    connection opens to the pinned IP (no re-resolution — TOCTOU closure). This exercises
  #    the DEFAULT seam (NOT the injected post:), which every other test bypasses.
  #
  #    FALSIFIER: the pre-fix code did Net::HTTP.start(pin_ip, ...) => @address == the IP =>
  #    SNI/verify against the IP => real certs fail. This test captures the constructed
  #    Net::HTTP and asserts address == hostname AND ipaddr == the vetted IP; it FAILS against
  #    the IP-as-address form and PASSES after the ipaddr= fix. Hermetic — Net::HTTP.new is
  #    stubbed, #start yields a fake connection, no socket/DNS is touched.
  class CapturingHttp
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout
    attr_reader :address, :port, :requests

    def initialize(address, port)
      @address = address
      @port = port
      @requests = []
    end

    def use_ssl?
      @use_ssl == true
    end

    def start
      yield self
    end

    def request(req)
      @requests << req
      Resp.new('200')
    end
  end

  def test_net_http_post_pins_vetted_ip_while_address_stays_the_hostname
    captured = nil
    d = Pulse::Adapters::HttpWebhookDispatcher.new

    Net::HTTP.stub(:new, ->(addr, prt) { captured = CapturingHttp.new(addr, prt) }) do
      # Drive the DEFAULT transport seam directly (the path production uses; not the post: seam).
      d.send(:net_http_post, uri: 'https://hooks.example/pulse', body: '{}',
                             headers: { 'Content-Type' => 'application/json' },
                             open_timeout: 5, read_timeout: 5, pin_ip: PUBLIC_IP)
    end

    refute_nil captured, 'the default seam must construct a Net::HTTP instance'
    assert_equal 'hooks.example', captured.address,
                 'the connect @address MUST be the HOSTNAME so TLS SNI + cert-hostname ' \
                 'verification target the hostname (WH-01: NOT the pinned IP)'
    assert_equal PUBLIC_IP, captured.ipaddr,
                 'the socket MUST be pinned to the vetted SSRF IP via ipaddr= (TOCTOU closure)'
    assert_equal true, captured.use_ssl, 'https target => TLS enabled'
    assert_equal OpenSSL::SSL::VERIFY_PEER, captured.verify_mode,
                 'certificate verification MUST stay VERIFY_PEER'
  end

  # A nil pin (ssrf_override with an unresolvable host) leaves ipaddr unset so Net::HTTP
  # resolves the hostname itself — address is still the hostname, no pin applied.
  def test_net_http_post_without_pin_leaves_ipaddr_unset
    captured = nil
    d = Pulse::Adapters::HttpWebhookDispatcher.new
    Net::HTTP.stub(:new, ->(addr, prt) { captured = CapturingHttp.new(addr, prt) }) do
      d.send(:net_http_post, uri: 'https://hooks.example/pulse', body: '{}',
                             headers: {}, open_timeout: 5, read_timeout: 5, pin_ip: nil)
    end
    assert_equal 'hooks.example', captured.address, 'address is the hostname'
    assert_nil captured.ipaddr, 'no pin_ip => ipaddr stays unset (Net::HTTP resolves the hostname)'
  end
end
