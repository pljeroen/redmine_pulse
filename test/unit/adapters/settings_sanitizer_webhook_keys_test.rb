# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# Pure-adapter unit lane. Run:
#   ruby -Itest -Ilib test/unit/adapters/settings_sanitizer_webhook_keys_test.rb
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/adapters/settings_sanitizer'

# C7 / FR-C7-02 / FC-C7-10 / FC-C7-11 — two ADDITIVE webhook settings keys, OFF by default:
#   pulse_webhook_endpoints_global      : Array<EndpointConfig>
#   pulse_webhook_endpoints_per_project : Hash<project_id, Array<EndpointConfig>>
# Each EndpointConfig is sanitized at write time: url well-formed String; secret non-empty if
# provided; enabled defaults false; event_filter defaults [] (=all) ⊆ AlertEvent::EVENT_TYPES;
# ssrf_override / allow_http / redaction default false; a redaction request naming a REQUIRED
# schema field is rejected (redactable ⊆ {previous, health.delta}). A MALFORMED entry is
# REJECTED and the prior value kept (never partially persisted). Absent keys are NOT
# synthesized (additivity — pre-existing keys sanitize byte-identically).
#
# The sanitizer surface: SettingsSanitizer.sanitize(incoming, previous) -> [sanitized, errors].
# RED NOW: sanitize does not yet validate the two webhook keys.
class SettingsSanitizerWebhookKeysTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  GLOBAL = 'pulse_webhook_endpoints_global'
  PER_PROJECT = 'pulse_webhook_endpoints_per_project'

  def san(incoming, previous = {})
    S.sanitize(incoming, previous)
  end

  def endpoint(overrides = {})
    { 'url' => 'https://hooks.example/pulse', 'secret' => 's3cr3t',
      'enabled' => true, 'event_filter' => [], 'ssrf_override' => false,
      'redaction' => false, 'allow_http' => false }.merge(overrides)
  end

  # ── additivity: absent webhook keys are not synthesized, no error ───────────
  def test_absent_webhook_keys_are_not_synthesized
    sanitized, errors = san({ 'rag_green_min' => 67 })
    refute errors.include?(GLOBAL)
    refute errors.include?(PER_PROJECT)
    refute sanitized.key?(GLOBAL), 'no global-endpoints key synthesized when absent'
    refute sanitized.key?(PER_PROJECT)
  end

  # ── a well-formed global endpoint round-trips with normalized defaults ──────
  def test_valid_global_endpoint_accepted
    sanitized, errors = san({ GLOBAL => [endpoint] })
    refute_includes errors, GLOBAL
    eps = sanitized[GLOBAL]
    assert_kind_of Array, eps
    assert_equal 1, eps.size
    ep = eps.first
    assert_equal 'https://hooks.example/pulse', ep['url']
    assert_equal 's3cr3t', ep['secret']
  end

  # ── a malformed endpoint (blank url) is REJECTED, the prior value kept ──────
  def test_blank_url_endpoint_rejected_keeps_prior
    prior = { GLOBAL => [endpoint('url' => 'https://old.example/hook')] }
    sanitized, errors = san({ GLOBAL => [endpoint('url' => '')] }, prior)
    assert_includes errors, GLOBAL, 'a blank-url endpoint is reported'
    assert_equal 'https://old.example/hook', sanitized[GLOBAL].first['url'],
                 'the prior valid endpoint list is kept on reject (never partially persisted)'
  end

  # ── WH-03: a non-http(s) URL scheme is REJECTED at write time, prior kept ───
  def test_non_http_scheme_url_rejected_keeps_prior
    prior = { GLOBAL => [endpoint('url' => 'https://old.example/hook')] }
    %w[file:///etc/passwd ftp://x/y javascript:alert(1) not-a-url].each do |bad|
      sanitized, errors = san({ GLOBAL => [endpoint('url' => bad)] }, prior)
      assert_includes errors, GLOBAL, "a non-http(s) url (#{bad}) is rejected (WH-03)"
      assert_equal 'https://old.example/hook', sanitized[GLOBAL].first['url'],
                   "the prior valid endpoint is kept on a bad-scheme reject (#{bad})"
    end
  end

  def test_http_and_https_scheme_urls_accepted
    %w[https://hooks.example/pulse http://plain.example/hook].each do |good|
      _sanitized, errors = san({ GLOBAL => [endpoint('url' => good)] })
      refute_includes errors, GLOBAL, "an http(s) url (#{good}) is accepted (WH-03)"
    end
  end

  # ── an event_filter entry outside AlertEvent::EVENT_TYPES is rejected ───────
  def test_event_filter_outside_event_types_rejected
    _sanitized, errors = san({ GLOBAL => [endpoint('event_filter' => %w[rag_transition bogus_type])] })
    assert_includes errors, GLOBAL, 'a non-EVENT_TYPES event_filter entry is rejected'
  end

  def test_valid_event_filter_subset_accepted
    sanitized, errors = san({ GLOBAL => [endpoint('event_filter' => %w[rag_transition score_delta])] })
    refute_includes errors, GLOBAL
    assert_equal %w[rag_transition score_delta].sort,
                 Array(sanitized[GLOBAL].first['event_filter']).map(&:to_s).sort
  end

  # ── FC-C7-10: a config redacting a REQUIRED field is rejected at write time ─
  # redactable ⊆ {previous, health.delta}; anything else (e.g. a required field) is invalid.
  def test_redaction_of_a_required_field_rejected
    _sanitized, errors = san({ GLOBAL => [endpoint('redaction' => %w[health.rag])] })
    assert_includes errors, GLOBAL,
                    'requesting redaction of a REQUIRED schema field (health.rag) is rejected (FC-C7-10)'
  end

  def test_redaction_of_optional_fields_accepted
    sanitized, errors = san({ GLOBAL => [endpoint('redaction' => %w[previous health.delta])] })
    refute_includes errors, GLOBAL,
                    'redacting the OPTIONAL fields {previous, health.delta} is accepted (FC-C7-06e)'
    assert sanitized.key?(GLOBAL)
  end

  # ── defaults: enabled/ssrf_override/allow_http/redaction default false ──────
  def test_endpoint_boolean_defaults_are_false_when_absent
    minimal = { 'url' => 'https://hooks.example/pulse', 'secret' => 's3cr3t' }
    sanitized, errors = san({ GLOBAL => [minimal] })
    refute_includes errors, GLOBAL
    ep = sanitized[GLOBAL].first
    assert_equal false, ep['enabled'], 'enabled defaults false (OFF)'
    assert_equal false, ep['ssrf_override'], 'ssrf_override defaults false (guard ON)'
    assert_equal false, ep['allow_http'], 'allow_http defaults false (HTTPS-only)'
    # redaction defaults to false / empty (no fields suppressed)
    assert(ep['redaction'] == false || Array(ep['redaction']).empty?,
           'redaction defaults false / empty')
  end

  # ── per-project endpoints validate the same way (keyed by project id) ───────
  def test_per_project_endpoints_validate
    sanitized, errors = san({ PER_PROJECT => { '42' => [endpoint] } })
    refute_includes errors, PER_PROJECT
    assert sanitized[PER_PROJECT].key?('42')
    assert_equal 'https://hooks.example/pulse', sanitized[PER_PROJECT]['42'].first['url']
  end

  # ── existing keys are unaffected by adding the webhook keys (additivity) ────
  def test_existing_keys_unchanged_when_webhook_keys_added
    incoming = { 'rag_green_min' => 67, 'rag_amber_min' => 34, GLOBAL => [endpoint] }
    sanitized, _errors = san(incoming)
    assert_equal 67, sanitized['rag_green_min']
    assert_equal 34, sanitized['rag_amber_min']
  end

  # ── WH-02: MULTIPLE global endpoints all round-trip (none silently dropped) ──
  def test_multiple_global_endpoints_all_preserved
    eps = [endpoint('url' => 'https://a.example/hook'),
           endpoint('url' => 'https://b.example/hook'),
           endpoint('url' => 'https://c.example/hook')]
    sanitized, errors = san({ GLOBAL => eps })
    refute_includes errors, GLOBAL
    assert_equal %w[https://a.example/hook https://b.example/hook https://c.example/hook],
                 sanitized[GLOBAL].map { |e| e['url'] },
                 'ALL global endpoints must survive a save (WH-02: no silent truncation)'
  end

  # ── WH-02: the no-JS indexed-Hash form shape coerces to an ordered list ─────
  def test_indexed_hash_form_shape_coerces_to_ordered_list
    form = { GLOBAL => {
      '0' => endpoint('url' => 'https://first.example/hook'),
      '1' => endpoint('url' => 'https://second.example/hook'),
      '__new__' => { 'url' => '', 'add_row' => '1' } # blank add row => silently skipped
    } }
    sanitized, errors = san(form)
    refute_includes errors, GLOBAL, 'a blank add-row must NOT be an error'
    assert_equal %w[https://first.example/hook https://second.example/hook],
                 sanitized[GLOBAL].map { |e| e['url'] },
                 'indexed rows keep numeric order; blank __new__ add-row dropped'
  end

  # ── WH-02: a row flagged remove is dropped; the rest are preserved ──────────
  def test_remove_flag_drops_that_endpoint_only
    form = { GLOBAL => {
      '0' => endpoint('url' => 'https://keep.example/hook'),
      '1' => endpoint('url' => 'https://drop.example/hook').merge('remove' => '1')
    } }
    sanitized, errors = san(form)
    refute_includes errors, GLOBAL
    assert_equal %w[https://keep.example/hook], sanitized[GLOBAL].map { |e| e['url'] },
                 'the remove-flagged endpoint is dropped, the other preserved'
  end

  # ── WH-06: a BLANK submitted secret KEEPS the prior secret (keep-on-blank) ──
  def test_blank_secret_keeps_prior_secret_via_prior_index
    prior = { GLOBAL => [endpoint('url' => 'https://x.example/hook', 'secret' => 'keep-me-123')] }
    # The no-JS form re-posts the row with a blank secret + prior_index pointing at row 0.
    form = { GLOBAL => { '0' => { 'url' => 'https://x.example/hook', 'secret' => '',
                                  'enabled' => '1', 'prior_index' => '0' } } }
    sanitized, errors = san(form, prior)
    refute_includes errors, GLOBAL
    assert_equal 'keep-me-123', sanitized[GLOBAL].first['secret'],
                 'a blank submitted secret must KEEP the prior secret (WH-06 keep-on-blank)'
  end

  # ── WH-06: a NON-blank submitted secret REPLACES the prior one ──────────────
  def test_non_blank_secret_replaces_prior
    prior = { GLOBAL => [endpoint('url' => 'https://x.example/hook', 'secret' => 'old-secret')] }
    form = { GLOBAL => { '0' => { 'url' => 'https://x.example/hook', 'secret' => 'new-secret',
                                  'prior_index' => '0' } } }
    sanitized, _errors = san(form, prior)
    assert_equal 'new-secret', sanitized[GLOBAL].first['secret'], 'a new secret replaces the prior'
  end

  # ── WH-06: a blank secret with NO prior secret stays nil (unsigned, valid) ──
  def test_blank_secret_no_prior_stays_nil
    form = { GLOBAL => { '__new0__' => { 'url' => 'https://new.example/hook', 'secret' => '' } } }
    sanitized, errors = san(form)
    refute_includes errors, GLOBAL
    assert_nil sanitized[GLOBAL].first['secret'], 'no prior secret + blank field => nil (unsigned)'
  end
end
