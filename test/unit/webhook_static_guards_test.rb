# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# C7 STATIC source guards (path-based; no Redmine env). Covers the mechanical gates that the
# global Python domain-purity hook cannot enforce on .rb (it is INERT on Ruby):
#   FC-C7-01a — lib/pulse/domain/ stays HTTP/DNS/socket-clean (domain purity grep).
#   FC-C7-01b — Net::HTTP ONLY in http_webhook_dispatcher.rb; Resolv ONLY in ssrf_guard.rb;
#               OpenSSL::HMAC adapter-only (layer-placement grep).
#   FC-C7-01c — the WebhookDispatcher PORT names no adapter constant and no Net::HTTP.
#   FC-C7-04a — the request cycle (app/controllers + app/helpers) references the webhook
#               adapters ONLY in the explicit test-event action of pulse_controller.rb.
#   FC-C7-09 (static) — the endpoint secret is not interpolated into any Rails.logger call.
#   FC-C7-12 — every new webhook .rb carries a GPL-2.0 header.
#
# RED until A9 writes the files. Where a target file is ABSENT the test FAILS (flunk) so the
# obligation is LIVE, not silently skipped. Pure lane:
#   ruby -Itest -Ilib test/unit/webhook_static_guards_test.rb
class WebhookStaticGuardsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  PORT = 'lib/pulse/ports/webhook_dispatcher.rb'
  HTTP_ADAPTER = 'lib/pulse/adapters/http_webhook_dispatcher.rb'
  SSRF_ADAPTER = 'lib/pulse/adapters/ssrf_guard.rb'
  SERIALIZER   = 'lib/pulse/adapters/webhook_payload_serializer.rb'
  CONTROLLER   = 'app/controllers/pulse_controller.rb'

  NEW_WEBHOOK_RUBY = [PORT, HTTP_ADAPTER, SSRF_ADAPTER, SERIALIZER].freeze

  # The HTTP/DNS/socket token set the domain must never contain (FC-C7-01 baseline).
  HTTP_TOKENS = /Net::HTTP|open-uri|OpenURI|URI\.open|Faraday|HTTPClient|RestClient|TCPSocket|\bsocket\b/

  def path(rel)
    File.join(ROOT, rel)
  end

  def read_or_flunk(rel)
    p = path(rel)
    flunk "expected file missing (RED until A9): #{rel}" unless File.exist?(p)
    File.read(p)
  end

  # ── FC-C7-01a: the domain layer stays HTTP/DNS/socket-clean ─────────────────
  def test_domain_layer_has_no_outbound_http_or_dns_or_socket
    files = Dir[path('lib/pulse/domain/**/*.rb')]
    refute_empty files, 'domain layer must exist'
    files.each do |f|
      src = File.read(f)
      refute_match(HTTP_TOKENS, src,
                   "#{File.basename(f)}: domain must stay HTTP/DNS/socket-clean (FC-C7-01a)")
      refute_match(/\bResolv\b/, src, "#{File.basename(f)}: no DNS in the domain (FC-C7-01a)")
      refute_match(/OpenSSL::HMAC/, src, "#{File.basename(f)}: no HMAC crypto in the domain (FC-C7-01a)")
    end
  end

  # ── FC-C7-01b: Net::HTTP ONLY in the http dispatcher adapter ────────────────
  def test_net_http_confined_to_the_http_dispatcher_adapter
    read_or_flunk(HTTP_ADAPTER) # must exist
    Dir[path('lib/pulse/**/*.rb')].each do |f|
      next if f == path(HTTP_ADAPTER)

      src = File.read(f)
      refute_match(/Net::HTTP/, src,
                   "#{f.sub(ROOT + '/', '')}: Net::HTTP is confined to http_webhook_dispatcher.rb (FC-C7-01b)")
    end
  end

  # ── FC-C7-01b: Resolv ONLY in the SSRF guard adapter ────────────────────────
  def test_resolv_confined_to_the_ssrf_guard_adapter
    read_or_flunk(SSRF_ADAPTER)
    Dir[path('lib/pulse/**/*.rb')].each do |f|
      next if f == path(SSRF_ADAPTER)

      src = File.read(f)
      refute_match(/\bResolv\b/, src,
                   "#{f.sub(ROOT + '/', '')}: Resolv is confined to ssrf_guard.rb (FC-C7-01b)")
    end
  end

  # ── FC-C7-01c: the PORT names no adapter constant and no Net::HTTP ──────────
  def test_port_is_pure_no_adapter_no_http
    src = read_or_flunk(PORT)
    refute_match(HTTP_TOKENS, src, 'the WebhookDispatcher port must contain no outbound HTTP (FC-C7-01c)')
    refute_match(/HttpWebhookDispatcher|SsrfGuard|WebhookPayloadSerializer/, src,
                 'the port must not name any adapter constant (FC-C7-01c)')
    refute_match(/ActiveRecord|ApplicationRecord|\bSetting\b/, src,
                 'the port is stdlib + Pulse::Domain only')
  end

  # ── FC-C7-04a: request cycle refs the webhook adapters ONLY in the test-event action ─
  def test_request_cycle_references_webhook_adapters_only_in_pulse_controller
    webhook_consts = /HttpWebhookDispatcher|SsrfGuard|WebhookPayloadSerializer|WebhookDispatcher/
    request_cycle = Dir[path('app/controllers/**/*.rb')] + Dir[path('app/helpers/**/*.rb')]
    request_cycle.each do |f|
      next if f == path(CONTROLLER) # the test-event action is the SOLE permitted reference site

      src = File.read(f)
      refute_match(webhook_consts, src,
                   "#{f.sub(ROOT + '/', '')}: no webhook adapter may be referenced on the request " \
                   "cycle outside the pulse_controller test-event action (FC-C7-04a / INV-C7-NO-BLOCK)")
    end
  end

  # ── FC-C7-09 (static): the endpoint secret is not interpolated into a log call ──
  def test_secret_not_interpolated_into_any_logger_call
    src = read_or_flunk(HTTP_ADAPTER)
    # No Rails.logger.<level>(...) line may interpolate a `secret` reference. Scan each logger
    # call span and refute a `secret` token inside it.
    src.scan(/Rails\.logger\.\w+\([^\n]*\)/).each do |line|
      refute_match(/secret/i, line,
                   "the endpoint secret must NEVER be interpolated into a log line (FC-C7-09): #{line}")
    end
    # Also: no bare `#{...secret...}` interpolation anywhere in a string that is logged.
    refute_match(/logger\.\w+\([^)]*#\{[^}]*secret/i, src,
                 'no secret interpolation into any logger call (FC-C7-09)')
  end

  # ── FC-C7-12: GPL-2.0 header on every new webhook .rb ───────────────────────
  def test_new_webhook_files_carry_gpl_header
    present = NEW_WEBHOOK_RUBY.select { |r| File.exist?(path(r)) }
    flunk 'no new webhook .rb files yet (RED until A9)' if present.empty?
    present.each do |rel|
      head = File.read(path(rel))[0, 600]
      assert_match(/GPL|GNU General Public License/i, head,
                   "#{rel}: every new webhook .rb must carry a GPL-2.0 header (FC-C7-12)")
    end
  end

  # ── FC-C7-02 / FC-C7-10: init.rb declares BOTH webhook keys, defaulting OFF ──
  def test_init_declares_both_webhook_keys_default_off
    src = read_or_flunk('init.rb')
    # Both keys must appear in the settings default hash.
    assert_match(/pulse_webhook_endpoints_global/, src,
                 'init.rb must declare pulse_webhook_endpoints_global (FC-C7-02)')
    assert_match(/pulse_webhook_endpoints_per_project/, src,
                 'init.rb must declare pulse_webhook_endpoints_per_project (FC-C7-02)')
    # Each must default to nil OR an empty collection ([] / {}) — the OFF (shipped) state.
    assert_match(/['"]pulse_webhook_endpoints_global['"]\s*=>\s*(nil|\[\s*\]|\{\s*\})/, src,
                 'pulse_webhook_endpoints_global must default nil/empty (OFF by default)')
    assert_match(/['"]pulse_webhook_endpoints_per_project['"]\s*=>\s*(nil|\[\s*\]|\{\s*\})/, src,
                 'pulse_webhook_endpoints_per_project must default nil/empty (OFF by default)')
  end

  # ── FC-C7-12: no new DB migration / no new rake task introduced by C7 ───────
  def test_c7_adds_no_new_migration_or_rake_task
    # C7 is settings-only + additive rake wiring; endpoints live in plugin Settings.
    # (This is a coarse guard: A9 must not add a webhook migration or a webhook rake task.)
    migrations = Dir[path('db/migrate/*webhook*')]
    assert_empty migrations, 'C7 introduces NO webhook DB migration (endpoints live in Settings, FC-C7-12)'
    rake = File.exist?(path('lib/tasks/pulse.rake')) ? File.read(path('lib/tasks/pulse.rake')) : ''
    refute_match(/webhook/i, rake, 'C7 adds NO new webhook rake task — it wires into scan_and_alert (FC-C7-12)')
  end
end
