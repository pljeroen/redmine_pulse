# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'resolv'
require 'ipaddr'
require 'uri'

module Pulse
  module Adapters
    # SsrfGuard — RESOLVE-THEN-CHECK SSRF defense for outbound webhook delivery.
    # It resolves the target
    # hostname to its IP(s) ONCE (via Resolv — the ONLY DNS call in the plugin) and BLOCKS
    # (typed BlockedTargetError) by default when ANY resolved address is in a blocked
    # category, across BOTH address families. Resolving first defeats crafted-hostname /
    # DNS-rebind bypass: a public-looking hostname that resolves to a blocked IP is blocked.
    #
    # The vetted resolved IP is RETURNED so the dispatcher can PIN the connection to it
    # (connect to the resolved+approved address, Host header/SNI = the hostname) — closing
    # the TOCTOU hole where the HTTP client would otherwise independently re-resolve at connect.
    #
    # Per-endpoint ssrf_override:true PERMITS a non-public target for THAT endpoint only
    # (operator-sovereign safe-default override) — the guard still resolves and
    # returns the address, it just does not raise.
    #
    # Adapter layer: Resolv/IPAddr are stdlib; the domain NEVER references this class.
    module SsrfGuard
      # Typed error so the dispatcher can rescue a blocked target precisely.
      class BlockedTargetError < StandardError; end

      # Blocked IPv4 CIDRs: loopback, RFC1918 private, link-local (subsumes 169.254.169.254
      # cloud metadata), "this host" 0.0.0.0/8.
      BLOCKED_V4 = %w[
        127.0.0.0/8
        10.0.0.0/8
        172.16.0.0/12
        192.168.0.0/16
        169.254.0.0/16
        0.0.0.0/8
      ].map { |c| IPAddr.new(c) }.freeze

      # Blocked IPv6 CIDRs: loopback ::1, unspecified ::, ULA fc00::/7 (covers fd00:ec2::254
      # v6-metadata), link-local fe80::/10. IPv4-mapped ::ffff:0:0/96 is DELIBERATELY NOT a
      # blanket block: a mapped address is un-mapped and its EMBEDDED IPv4 is classified
      # against BLOCKED_V4 in #blocked? — so ::ffff:127.0.0.1 (loopback) / ::ffff:10.0.0.1
      # (private) still BLOCK, while ::ffff:8.8.8.8 (public) is correctly ALLOWED. A blanket
      # /96 block would over-block every public mapped address (fail-closed, but wrong).
      BLOCKED_V6 = %w[
        ::1/128
        ::/128
        fc00::/7
        fe80::/10
      ].map { |c| IPAddr.new(c) }.freeze

      module_function

      # check(url, ssrf_override:) -> IPAddr | nil (the vetted resolved IP for pinning, or nil
      # when no pin target is available). Raises BlockedTargetError when ANY resolved address is
      # blocked and ssrf_override is false. Returns the FIRST resolved address (the pin target)
      # on a clean check or an override with a usable resolution.
      #
      # ssrf_override:true is an operator-sovereign per-endpoint opt-out: the guard does
      # NOT block, and a resolution failure is NOT fatal either — it returns nil so the dispatcher
      # POSTs to the hostname directly (the operator has explicitly accepted this target). WITHOUT
      # the override, an unresolvable host is treated as a blocked target (fail-closed).
      def check(url, ssrf_override: false)
        host = host_for(url)
        addresses = resolve(host)
        ips = addresses.map { |a| to_ipaddr(a) }.compact

        if ips.empty?
          return nil if ssrf_override # operator-permitted target; POST to the hostname (no pin)

          raise BlockedTargetError, "unresolvable host: #{host}"
        end

        unless ssrf_override
          blocked = ips.find { |ip| blocked?(ip) }
          raise BlockedTargetError, "blocked target #{blocked} for host #{host}" if blocked
        end

        ips.first
      end

      # Extract the host from a URL. A bare hostname (no scheme) is treated as the host.
      def host_for(url)
        uri = URI.parse(url)
        uri.host || uri.path
      rescue URI::InvalidURIError
        url
      end

      # Resolve `host` to its address strings via Resolv (the single DNS seam). getaddresses
      # returns every A/AAAA record; a literal IP resolves to itself. Stubbed in tests.
      def resolve(host)
        Array(Resolv.getaddresses(host))
      rescue Resolv::ResolvError
        []
      end

      # A resolved address may be an IPv4-mapped IPv6 (::ffff:127.0.0.1). Building the IPAddr
      # keeps that shape; blocked? additionally checks the embedded v4 so a mapped private
      # address cannot slip past the v4 blocklist.
      def to_ipaddr(address)
        IPAddr.new(address.to_s)
      rescue IPAddr::InvalidAddressError, ArgumentError
        nil
      end

      # True iff `ip` falls in any blocked range (either family), INCLUDING the embedded IPv4
      # of an IPv4-mapped IPv6 address.
      def blocked?(ip)
        ranges = ip.ipv4? ? BLOCKED_V4 : BLOCKED_V6
        return true if ranges.any? { |cidr| cidr.include?(ip) }

        # IPv4-mapped IPv6 (::ffff:a.b.c.d): also test the embedded v4 against the v4 blocklist.
        if ip.ipv6? && ipv4_mapped?(ip)
          v4 = ip.native
          return true if v4.ipv4? && BLOCKED_V4.any? { |cidr| cidr.include?(v4) }
        end
        false
      end

      # ::ffff:0:0/96 detection (IPv4-mapped IPv6).
      def ipv4_mapped?(ip)
        IPAddr.new('::ffff:0:0/96').include?(ip)
      rescue StandardError
        false
      end
    end
  end
end
