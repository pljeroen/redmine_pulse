# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'json'
require 'openssl'
require 'time'

# Pure-adapter unit lane. Run:
#   ruby -Itest -Ilib test/unit/adapters/webhook_redaction_test.rb
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/domain/alert_event'
require 'pulse/adapters/webhook_payload_serializer'

# Per-endpoint redaction OMITS
# (not placeholders) the schema's OPTIONAL fields ONLY — exactly { previous, health.delta }
# — BEFORE serialization so the signature covers the redacted body and the reduced body
# STILL validates against the frozen schema. Required fields are NOT redactable (guarded at
# settings write time — see the sanitizer suite). This suite exercises the serializer's
# redact: seam directly (pure lane; structural schema check reused from the serializer suite).
#
# Requires WebhookPayloadSerializer.
class WebhookRedactionTest < Minitest::Test
  SCHEMA_PATH = File.expand_path(
    '../../../docs/specs/pulse-roadmap/contracts/schemas/webhook-payload.json', __dir__
  )
  OCC = Time.utc(2026, 7, 6, 9, 30, 0)

  Proj = Struct.new(:id, :identifier, :name)
  Health = Struct.new(:project_id, :health_score, :rag, :dominant_signal)

  def schema
    @schema ||= JSON.parse(File.read(SCHEMA_PATH))
  end

  def event
    Pulse::Domain::AlertEvent.new(
      project_id: 42, event_type: :rag_transition, from: 'green', to: 'amber',
      score: 58, previous_score: 72, delta: -14.0, occurred_at: OCC
    )
  end

  def serialize(redact:)
    Pulse::Adapters::WebhookPayloadSerializer.serialize(
      event,
      project: Proj.new(42, 'apollo', 'Apollo Platform'),
      health_result: Health.new(42, 58, :amber, :risk_load),
      redact: redact,
      previous: { rag: 'green', dominant_signal: 'momentum' }
    )
  end

  # Minimal structural validator (subset used by the frozen schema): required + no-extra +
  # types + enum + const, recursively. Mirrors webhook_payload_serializer_test.rb.
  def schema_errors(instance, sch = schema, path = '$')
    errs = []
    types = Array(sch['type'])
    unless types.empty?
      ok = types.any? do |t|
        case t
        when 'object' then instance.is_a?(Hash)
        when 'string' then instance.is_a?(String)
        when 'integer' then instance.is_a?(Integer)
        when 'number' then instance.is_a?(Numeric)
        when 'null' then instance.nil?
        else true
        end
      end
      errs << "#{path}: type mismatch" unless ok
    end
    errs << "#{path}: const" if sch['const'] && instance != sch['const']
    errs << "#{path}: enum" if sch['enum'] && !sch['enum'].include?(instance)
    if instance.is_a?(Hash) && sch['properties']
      Array(sch['required']).each { |k| errs << "#{path}: missing #{k}" unless instance.key?(k) }
      if sch['additionalProperties'] == false
        extra = instance.keys - sch['properties'].keys
        errs << "#{path}: extra #{extra.inspect}" unless extra.empty?
      end
      instance.each { |k, v| errs.concat(schema_errors(v, sch['properties'][k], "#{path}.#{k}")) if sch['properties'][k] }
    end
    errs
  end

  # ── redaction OMITS previous and health.delta (the ONLY redactable/optional fields) ─
  def test_redaction_omits_previous_and_health_delta
    body = JSON.parse(serialize(redact: true))
    assert(!body.key?('previous') || body['previous'].nil?,
           'redaction omits the optional `previous` field')
    refute body['health'].key?('delta'),
           'redaction omits the optional health.delta field'
  end

  # ── the un-redacted body carries both optional fields (baseline) ────────────
  def test_unredacted_body_carries_previous_and_delta
    body = JSON.parse(serialize(redact: false))
    refute_nil body['previous'], 'un-redacted: previous present'
    assert body['health'].key?('delta'), 'un-redacted: health.delta present'
  end

  # ── the redacted body STILL validates against the frozen schema ─
  def test_redacted_body_still_validates
    body = JSON.parse(serialize(redact: true))
    assert_empty schema_errors(body),
                 'the redacted body (only optional fields omitted) must STILL validate against the schema'
  end

  # ── required fields are NEVER omitted by redaction (structural guarantee) ────
  def test_redaction_never_omits_required_fields
    body = JSON.parse(serialize(redact: true))
    %w[version event project health occurred_at signature].each do |k|
      assert body.key?(k), "required top-level key #{k} must survive redaction"
    end
    %w[score rag dominant_signal].each do |k|
      assert body['health'].key?(k), "required health.#{k} must survive redaction"
    end
    %w[id identifier name].each do |k|
      assert body['project'].key?(k), "required project.#{k} must survive redaction"
    end
  end
end
