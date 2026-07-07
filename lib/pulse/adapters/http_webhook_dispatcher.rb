# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'net/http'
require 'openssl'
require 'uri'
require 'pulse/adapters/ssrf_guard'
require 'pulse/adapters/webhook_payload_serializer'

module Pulse
  module Adapters
    # HttpWebhookDispatcher — the WebhookDispatcher port implementation (C7 / FR-C7-05/06/07/08).
    # It is the ONLY place in the plugin that performs outbound HTTP (Net::HTTP) and HMAC signing.
    #
    # Delivery pipeline per endpoint (#deliver):
    #   event_filter -> HTTPS-only (unless allow_http) -> SSRF guard (resolve-then-check, pin
    #   the vetted IP) -> serialize (redaction applied) -> HMAC-SHA256 over the EXACT posted
    #   body -> POST with ~5s open+read timeout -> bounded ≤3 retry + backoff -> dead-letter.
    #
    # BEST-EFFORT (GR-05): every failure mode — an HTTPS/SSRF reject, a timeout, a 5xx, a
    # connection error — is RESCUED + LOGGED (no secret) and NEVER propagates out. State
    # advancement in the composition root is therefore never gated on delivery outcome.
    #
    # Fan-out (#dispatch) iterates the settings-configured endpoint list; an EMPTY list makes
    # ZERO POSTs (the OFF-by-default structural short-circuit, FC-C7-02). A disabled endpoint
    # (enabled:false) is skipped entirely.
    #
    # Injection seams (A8 hermeticity contract): the ctor accepts `post:` (a callable of shape
    # ->(uri:, body:, headers:, open_timeout:, read_timeout:) -> response|raise; defaults to the
    # real Net::HTTP path), `logger:`, and `endpoints:`. #sleep is a plain method so the backoff
    # can be stubbed to 0 in tests.
    class HttpWebhookDispatcher
      MAX_ATTEMPTS = 3
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 5
      BACKOFF_BASE = 0.5 # seconds; grows per attempt (0.5, 1.0, ...). Stubbable via #sleep.
      SIGNATURE_HEADER = 'X-Pulse-Signature'

      def initialize(post: nil, logger: nil, endpoints: nil)
        @injected_post = post # nil => use the real pinned Net::HTTP seam
        @logger = logger
        @endpoints = Array(endpoints)
      end

      # dispatch(alert_event, project:, health_result:, previous:) -> void. Fan out over the
      # configured endpoint list. Empty list => zero POSTs (structural short-circuit). Never
      # raises out (best-effort). Skips disabled / event-filter-non-matching endpoints.
      def dispatch(alert_event, project:, health_result:, previous:)
        @endpoints.each do |endpoint|
          ep = symbolize(endpoint)
          next unless ep[:enabled]

          deliver(alert_event, ep, project: project, health_result: health_result, previous: previous)
        end
        nil
      end

      # deliver(alert_event, endpoint, project:, health_result:, previous:) -> the final
      # response (or nil on a dead-letter). The single-endpoint primitive shared by #dispatch
      # and the admin test-event action. Never raises out (best-effort).
      def deliver(alert_event, endpoint, project:, health_result:, previous:)
        ep = symbolize(endpoint)

        return nil unless event_matches?(alert_event, ep)

        url = ep[:url].to_s
        unless https?(url) || ep[:allow_http]
          dead_letter(ep, alert_event, "non-https URL rejected (allow_http off)")
          return nil
        end

        vetted_ip = ssrf_check(url, ep)
        return nil if vetted_ip == :blocked

        # Never POST an unsigned/empty-key-signed payload: an endpoint without a signing secret
        # is dead-lettered, not delivered (defense in depth — the sanitizer already refuses to
        # enable a secretless endpoint, this guarantees no delivery path can emit an empty-key HMAC).
        if blank_secret?(ep)
          dead_letter(ep, alert_event, "no signing secret configured")
          return nil
        end

        body = serialize_body(alert_event, ep, project: project, health_result: health_result,
                                              previous: previous)
        signature = OpenSSL::HMAC.hexdigest('SHA256', ep[:secret].to_s, body)
        headers = { SIGNATURE_HEADER => signature, 'Content-Type' => 'application/json' }

        attempt_delivery(url, body, headers, vetted_ip, ep, alert_event)
      end

      # deliver_test(alert_event, endpoint, project:, health_result:, previous:) -> a diagnostic
      # result Hash { ok:, status:, error: } for the admin test-event action (FR-C7-09). Same
      # pipeline as #deliver (event_filter is ignored — the operator explicitly targets this
      # endpoint — but HTTPS/SSRF/serialize/HMAC and the ~5s timeout still apply), but a SINGLE
      # attempt whose OUTCOME is REPORTED (not swallowed): this action is a diagnostic surface.
      #   ok:false + error: "<reason>" on an HTTPS/SSRF reject or a raised transport error;
      #   ok:(2xx?) + status:"<code>" on a completed POST.
      def deliver_test(alert_event, endpoint, project:, health_result:, previous:)
        ep = symbolize(endpoint)
        url = ep[:url].to_s

        unless https?(url) || ep[:allow_http]
          return { ok: false, status: nil, error: 'non-https URL rejected (allow_http off)' }
        end

        begin
          vetted_ip = Pulse::Adapters::SsrfGuard.check(url, ssrf_override: ep[:ssrf_override])
        rescue Pulse::Adapters::SsrfGuard::BlockedTargetError => e
          return { ok: false, status: nil, error: "SSRF blocked: #{e.message}" }
        end

        if blank_secret?(ep)
          return { ok: false, status: nil, error: 'no signing secret configured' }
        end

        body = serialize_body(alert_event, ep, project: project, health_result: health_result,
                                              previous: previous)
        signature = OpenSSL::HMAC.hexdigest('SHA256', ep[:secret].to_s, body)
        headers = { SIGNATURE_HEADER => signature, 'Content-Type' => 'application/json' }
        post = @injected_post ? @injected_post : pinned_post(vetted_ip)

        response = post.call(uri: url, body: body, headers: headers,
                             open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
        code = code_of(response).to_s
        { ok: success?(response), status: code, error: nil }
      rescue StandardError => e
        { ok: false, status: nil, error: "#{e.class}: #{e.message}" }
      end

      private

      # An endpoint with no signing secret (nil / blank / whitespace-only) must never be delivered:
      # signing with an empty key yields an unauthenticated payload. Callers dead-letter or reject.
      def blank_secret?(ep)
        ep[:secret].to_s.strip.empty?
      end

      # Run up to MAX_ATTEMPTS POSTs. A 2xx stops early (success). A non-2xx code or a raised
      # error counts as a failed attempt; between attempts we back off (stubbable sleep). After
      # the cap the delivery is dead-lettered. Returns the last response, or nil on dead-letter.
      def attempt_delivery(url, body, headers, vetted_ip, endpoint, alert_event)
        last_error = nil
        last_response = nil

        # Bind the SSRF-vetted pin IP to the default seam WITHOUT widening the injectable
        # `post:` contract (A8 pins it to exactly ->(uri:,body:,headers:,open_timeout:,
        # read_timeout:)). The default Net::HTTP seam takes pin_ip; an injected seam never sees it.
        post = @injected_post ? @injected_post : pinned_post(vetted_ip)

        (1..MAX_ATTEMPTS).each do |attempt|
          begin
            response = post.call(uri: url, body: body, headers: headers,
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
            last_response = response
            return response if success?(response)

            last_error = "HTTP #{code_of(response)}"
          rescue StandardError => e
            last_error = "#{e.class}: #{e.message}"
          end

          sleep(BACKOFF_BASE * attempt) if attempt < MAX_ATTEMPTS
        end

        dead_letter(endpoint, alert_event, last_error || 'delivery failed')
        last_response
      end

      # Whether the endpoint's event_filter admits this event. An empty filter admits ALL.
      def event_matches?(alert_event, endpoint)
        filter = Array(endpoint[:event_filter]).map(&:to_s)
        return true if filter.empty?

        filter.include?(alert_event.event_type.to_s)
      end

      # SSRF guard: returns the vetted IP on pass/override, or :blocked (dead-lettered) on a
      # BlockedTargetError. Never raises out.
      def ssrf_check(url, endpoint)
        Pulse::Adapters::SsrfGuard.check(url, ssrf_override: endpoint[:ssrf_override])
      rescue Pulse::Adapters::SsrfGuard::BlockedTargetError => e
        dead_letter(endpoint, nil, "SSRF blocked: #{e.message}")
        :blocked
      rescue StandardError => e
        # Any other guard failure (e.g. unresolvable host) is also a best-effort dead-letter.
        dead_letter(endpoint, nil, "SSRF check error: #{e.class}")
        :blocked
      end

      def serialize_body(alert_event, endpoint, project:, health_result:, previous:)
        Pulse::Adapters::WebhookPayloadSerializer.serialize(
          alert_event, project: project, health_result: health_result,
                       redact: endpoint[:redaction], previous: previous, secret: endpoint[:secret]
        )
      end

      # A 2xx response is success. `code` is a String ('200') or Integer.
      def success?(response)
        code = code_of(response).to_i
        code >= 200 && code < 300
      end

      def code_of(response)
        response.respond_to?(:code) ? response.code : response
      end

      def https?(url)
        url.to_s.downcase.start_with?('https://')
      end

      # The default seam, pinned to the SSRF-vetted IP, as a 5-kwarg callable matching the
      # injectable `post:` contract (pin_ip is captured, never a keyword).
      def pinned_post(vetted_ip)
        lambda do |uri:, body:, headers:, open_timeout:, read_timeout:|
          net_http_post(uri: uri, body: body, headers: headers,
                        open_timeout: open_timeout, read_timeout: read_timeout, pin_ip: vetted_ip)
        end
      end

      # Real outbound POST (default seam). Pins the connection to the SSRF-vetted IP via the
      # Net::HTTP INSTANCE (Net::HTTP.new(host, port) keeps @address = the HOSTNAME, then
      # #ipaddr= directs the socket to the vetted IP): the TLS SNI and the cert-hostname
      # verification therefore target the HOSTNAME (a real cert issued for the hostname passes
      # VERIFY_PEER), while the connection opens to the pinned IP WITHOUT any independent
      # re-resolution at connect time (TOCTOU closure, SF-C7-04 / FC-C7-06c). The earlier
      # Net::HTTP.start(ip, ...) form set @address = the IP, which broke SNI/verify for every
      # real HTTPS endpoint (WH-01). A nil pin_ip (ssrf_override with an unresolvable host)
      # leaves @ipaddr unset so Net::HTTP resolves the hostname itself.
      def net_http_post(uri:, body:, headers:, open_timeout:, read_timeout:, pin_ip: nil)
        parsed = URI.parse(uri)
        host = parsed.host
        port = parsed.port || (parsed.scheme == 'https' ? 443 : 80)
        use_ssl = (parsed.scheme == 'https')

        http = build_http(host, port, use_ssl, open_timeout, read_timeout, pin_ip)

        request = Net::HTTP::Post.new(parsed.request_uri)
        headers.each { |k, v| request[k] = v }
        request['Host'] = host
        request.body = body

        http.start { |conn| conn.request(request) }
      end

      # Construct the pinned Net::HTTP instance. @address stays the HOSTNAME (correct SNI +
      # cert-hostname verification); #ipaddr= pins the socket to the vetted IP so no DNS
      # re-resolution happens at connect (TOCTOU closure). Split out so the transport
      # construction is unit-testable without a live TLS handshake (WH-01 blind-spot closure).
      def build_http(host, port, use_ssl, open_timeout, read_timeout, pin_ip)
        http = Net::HTTP.new(host, port)
        http.ipaddr = pin_ip.to_s if pin_ip
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        if use_ssl
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
        http
      end

      # Best-effort dead-letter log. Carries url + event_type + project_id + reason; NEVER the
      # endpoint secret (FC-C7-09). A logger that is absent or itself raises must not mask the
      # swallow (the caller keeps going, GR-05).
      def dead_letter(endpoint, alert_event, reason)
        logger = resolve_logger
        return if logger.nil?

        event_type = alert_event&.event_type
        project_id = alert_event&.project_id
        logger.error(
          "[redmine_pulse] webhook delivery failed url=#{endpoint[:url]} " \
          "event_type=#{event_type} project_id=#{project_id}: #{reason}"
        )
      rescue StandardError
        nil
      end

      # The injected logger, else Rails.logger when available. nil when neither is present.
      def resolve_logger
        return @logger unless @logger.nil?
        return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        nil
      end

      # Accept either a symbol- or string-keyed endpoint config (settings persist string keys;
      # tests pass symbol keys) and normalize to symbol access.
      def symbolize(endpoint)
        return endpoint if endpoint.is_a?(Hash) && endpoint.keys.all? { |k| k.is_a?(Symbol) }

        (endpoint || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end
  end
end
