# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'minitest/mock' # Resolv.stub / Object#stub — not auto-loaded standalone (WH-05).
require 'resolv'
require 'ipaddr'

# Pure-adapter unit lane. Run:
#   ruby -Itest -Ilib test/unit/adapters/webhook_ssrf_guard_test.rb
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/adapters/ssrf_guard'

# C7 / FR-C7-06(c) / FC-C7-06c / INV-C7-SSRF-DEFAULT / AC-C7-04 (TIER-1 SECURITY) —
# SsrfGuard RESOLVE-THEN-CHECK: it resolves the target hostname to its IP(s) ONCE and
# BLOCKS (typed error) by default when ANY resolved address is in a blocked category,
# across BOTH families:
#   IPv4: loopback 127.0.0.0/8; RFC1918 10/8, 172.16/12, 192.168/16;
#         link-local 169.254.0.0/16 (incl. 169.254.169.254 cloud metadata).
#   IPv6: loopback ::1; ULA fc00::/7; link-local fe80::/10; IPv4-mapped ::ffff:0:0/96
#         (so ::ffff:127.0.0.1 CANNOT bypass the v4 loopback block); v6-metadata fd00:ec2::254.
# A public IP is ALLOWED. Per-endpoint ssrf_override permits a blocked target. Resolution is
# stubbed (hermetic, no real DNS). A hostname that RESOLVES to a blocked IP is ALSO blocked
# (proves it is not a string-only check). The connection is PINNED to the vetted IP (TOCTOU
# closure) — the guard returns the resolved+approved address for the dispatcher to connect to.
#
# RED NOW: Pulse::Adapters::SsrfGuard does not exist (LoadError / NameError).
class WebhookSsrfGuardTest < Minitest::Test
  # Every required blocked address, per family (FC-C7-06c falsifier set).
  BLOCKED_V4 = {
    'loopback 127.0.0.1'       => '127.0.0.1',
    'loopback 127.5.5.5 (/8)'  => '127.5.5.5',
    'RFC1918 10.0.0.5'         => '10.0.0.5',
    'RFC1918 172.16.0.9'       => '172.16.0.9',
    'RFC1918 192.168.1.1'      => '192.168.1.1',
    'link-local 169.254.1.1'   => '169.254.1.1',
    'cloud-metadata 169.254.169.254' => '169.254.169.254'
  }.freeze

  BLOCKED_V6 = {
    'loopback ::1'              => '::1',
    'ULA fc00::1 (/7)'         => 'fc00::1',
    'link-local fe80::1 (/10)' => 'fe80::1',
    'IPv4-mapped ::ffff:127.0.0.1' => '::ffff:127.0.0.1',
    'v6-metadata fd00:ec2::254' => 'fd00:ec2::254'
  }.freeze

  PUBLIC_V4 = '93.184.216.34'   # example.com — a public address
  PUBLIC_V6 = '2606:2800:220:1:248:1893:25c8:1946'

  def guard
    Pulse::Adapters::SsrfGuard
  end

  # Stub SsrfGuard's DNS resolution so `hostname` resolves to `ips`, then run `check`.
  # The guard MUST expose a seam that resolves via Resolv; we stub Resolv itself so the
  # implementation is free to use getaddresses / Resolv.new — either lands here. Any
  # unresolvable host in a test must be explicitly listed.
  def with_resolution(map)
    Resolv.stub(:getaddresses, ->(host) { map.fetch(host) { raise Resolv::ResolvError, host } }) do
      yield
    end
  end

  def check(url, ssrf_override: false)
    guard.check(url, ssrf_override: ssrf_override)
  end

  # A guard block must raise a TYPED error (not a bare StandardError string match) so the
  # dispatcher can rescue it precisely. We assert it is a distinct class the adapter defines.
  def blocked_error_class
    guard::BlockedTargetError
  end

  # ── typed error constant exists (so the dispatcher can rescue precisely) ─────
  def test_defines_a_typed_blocked_error
    assert(defined?(guard::BlockedTargetError),
           'SsrfGuard must define a typed BlockedTargetError for the dispatcher to rescue')
  end

  # ── each blocked IPv4 address is rejected by default (direct-literal host) ───
  def test_blocks_every_required_ipv4_by_default
    BLOCKED_V4.each do |label, ip|
      with_resolution('blocked.example' => [ip]) do
        assert_raises(blocked_error_class, "must BLOCK #{label} (#{ip}) by default") do
          check('https://blocked.example/hook')
        end
      end
    end
  end

  # ── each blocked IPv6 address is rejected by default (incl. the mapped bypass) ─
  def test_blocks_every_required_ipv6_by_default
    BLOCKED_V6.each do |label, ip|
      with_resolution('blocked6.example' => [ip]) do
        assert_raises(blocked_error_class, "must BLOCK #{label} (#{ip}) by default") do
          check('https://blocked6.example/hook')
        end
      end
    end
  end

  # ── ANY resolved address in a blocked range rejects (multi-A resolve-then-check) ─
  def test_blocks_when_any_resolved_address_is_blocked
    with_resolution('mixed.example' => [PUBLIC_V4, '127.0.0.1']) do
      assert_raises(blocked_error_class,
                    'a host resolving to BOTH a public and a loopback IP must be BLOCKED (any-blocked)') do
        check('https://mixed.example/hook')
      end
    end
  end

  # ── a hostname that RESOLVES to a blocked IP is blocked (NOT a string-only check) ─
  def test_rebind_hostname_resolving_to_loopback_is_blocked
    with_resolution('sneaky.attacker.example' => ['127.0.0.1']) do
      assert_raises(blocked_error_class,
                    'resolve-then-check: a public-looking hostname resolving to loopback must be BLOCKED') do
        check('https://sneaky.attacker.example/hook')
      end
    end
  end

  # ── WH-04: IPv4-mapped IPv6 is classified by its EMBEDDED v4, not blanket-blocked ─
  # A mapped PRIVATE/LOOPBACK/metadata address still BLOCKS (its embedded v4 is blocked);
  # a mapped PUBLIC address is ALLOWED (::ffff:0:0/96 is no longer a blanket block).
  MAPPED_BLOCKED = {
    'mapped loopback ::ffff:127.0.0.1'  => '::ffff:127.0.0.1',
    'mapped private ::ffff:10.0.0.1'    => '::ffff:10.0.0.1',
    'mapped metadata ::ffff:169.254.169.254' => '::ffff:169.254.169.254'
  }.freeze
  MAPPED_PUBLIC = {
    'mapped public ::ffff:8.8.8.8'      => '::ffff:8.8.8.8',
    'mapped public ::ffff:93.184.216.34' => '::ffff:93.184.216.34'
  }.freeze

  def test_mapped_ipv4_private_or_loopback_is_blocked
    MAPPED_BLOCKED.each do |label, ip|
      with_resolution('mapped-blocked.example' => [ip]) do
        assert_raises(blocked_error_class, "must BLOCK #{label} (embedded v4 is blocked)") do
          check('https://mapped-blocked.example/hook')
        end
      end
    end
  end

  def test_mapped_ipv4_public_is_allowed
    MAPPED_PUBLIC.each do |label, ip|
      with_resolution('mapped-public.example' => [ip]) do
        vetted = assert_nothing_raised_wrapper_value { check('https://mapped-public.example/hook') }
        refute_nil vetted, "#{label}: a PUBLIC mapped v4 must be ALLOWED (embedded v4 is public)"
      end
    end
  end

  # ── a public IP is ALLOWED (guard is not block-everything) ──────────────────
  def test_allows_public_ipv4
    with_resolution('public.example' => [PUBLIC_V4]) do
      # No raise; returns (the vetted IP for pinning — see below).
      assert_nil assert_nothing_raised_wrapper { check('https://public.example/hook') },
                 'checking a public target must not raise'
    end
  end

  def test_allows_public_ipv6
    with_resolution('public6.example' => [PUBLIC_V6]) do
      assert_nil assert_nothing_raised_wrapper { check('https://public6.example/hook') },
                 'checking a public IPv6 target must not raise'
    end
  end

  # ── per-endpoint ssrf_override permits EACH blocked target ──────────────────
  def test_override_permits_blocked_targets_across_both_families
    (BLOCKED_V4.merge(BLOCKED_V6)).each do |label, ip|
      with_resolution('overridden.example' => [ip]) do
        assert_nil assert_nothing_raised_wrapper { check('https://overridden.example/hook', ssrf_override: true) },
                   "ssrf_override:true must PERMIT #{label} (#{ip})"
      end
    end
  end

  # ── TOCTOU closure: the guard yields the VETTED resolved IP for pinning ──────
  # The dispatcher pins the connection to the resolved+approved address (Host header =
  # hostname). So the guard must SURFACE which IP was vetted — not merely return true —
  # otherwise the dispatcher would re-resolve at connect time (the TOCTOU hole).
  def test_check_returns_the_vetted_resolved_ip_for_pinning
    with_resolution('public.example' => [PUBLIC_V4]) do
      vetted = check('https://public.example/hook')
      refute_nil vetted, 'check must surface the vetted resolved IP so the dispatcher can PIN it (TOCTOU)'
      assert_equal PUBLIC_V4, vetted.to_s, 'the vetted IP must be the resolved+approved address'
    end
  end

  private

  # minitest 6.0.6 has no assert_nothing_raised; wrap + return the block value (nil-ish).
  def assert_nothing_raised_wrapper
    yield
    nil
  rescue StandardError => e
    flunk "expected no raise, got #{e.class}: #{e.message}"
  end

  # Same, but SURFACES the block's return value (for asserting the vetted IP on an allow).
  def assert_nothing_raised_wrapper_value
    yield
  rescue StandardError => e
    flunk "expected no raise, got #{e.class}: #{e.message}"
  end
end
