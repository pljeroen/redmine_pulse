# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'
require 'json-schema'
require 'yaml'
require 'time'

# FULL json-schema-gem validation of the frozen SEED instances AND the live serializer
# OUTPUT against the frozen schema
#   docs/specs/pulse-roadmap/contracts/schemas/webhook-payload.json.
# This is the gem-backed complement to the structural pure-lane check
# (test/unit/adapters/webhook_payload_serializer_test.rb) — same schema, authoritative
# validator. The `json-schema` gem is available in the harness (test_helper loads it +
# init.rb registers a draft-07 validator).
#
# Builds one (AlertEvent, Project, HealthResult[, previous]) triple per EVENT_TYPE (all four)
# and validates the serializer output. Negative guards prove the schema is actually applied.
#
# Requires WebhookPayloadSerializer.
class WebhookSerializerSchemaTest < ActiveSupport::TestCase
  SPEC = File.expand_path('../../../docs/specs/pulse-roadmap/contracts', File.expand_path(__FILE__))
  SCHEMA = File.join(SPEC, 'schemas/webhook-payload.json')
  SEED   = File.join(SPEC, 'seeds/webhook-payload.yaml')
  OCC = Time.utc(2026, 7, 6, 9, 30, 0)

  Proj = Struct.new(:id, :identifier, :name)
  Health = Struct.new(:project_id, :health_score, :rag, :dominant_signal)

  # The frozen webhook schema DELIBERATELY declares "$schema": draft/2020-12 (a subset of it is
  # validated structurally on the pure lane; see webhook_payload_serializer_test.rb). The bundled
  # json-schema 6.2.0 ships validators only up to draft-06 and CANNOT resolve the 2020-12
  # meta-schema URI (init.rb registers a draft-07 alias for the OTHER frozen API schemas, but not
  # 2020-12). The keywords this schema actually uses (type, required, additionalProperties, const,
  # enum, pattern, $ref JSON-pointers into definitions, format, oneOf, minimum/maximum) are all
  # draft-06-compatible, so — mirroring the proven init.rb draft-07 shim — register a 2020-12
  # validator that reuses the draft-06 attribute set under the 2020-12 URI. This keeps the GEM the
  # authoritative validator (not a hand-rolled subset): every positive case and every negative
  # guard below still bites. Registered once per process, guarded against double-registration.
  DRAFT_2020_12_URI = 'https://json-schema.org/draft/2020-12/schema'
  unless JSON::Validator.validators.key?(DRAFT_2020_12_URI) ||
         JSON::Validator.validators.key?("#{DRAFT_2020_12_URI}#")
    draft2020 = Class.new(JSON::Schema::Draft6) do
      def initialize
        super
        @uri = JSON::Util::URI.parse('https://json-schema.org/draft/2020-12/schema')
        @names = ['draft2020-12', 'https://json-schema.org/draft/2020-12/schema']
        @metaschema_name = 'draft-06.json'
      end
    end
    JSON::Validator.register_validator(draft2020.new)
  end

  def assert_schema(payload, msg = nil)
    errs = JSON::Validator.fully_validate(SCHEMA, payload, strict: false)
    assert_empty errs, [msg, errs.join("\n")].compact.join("\n")
  end

  def event(event_type:, delta: -14.0, score: 58, previous_score: 72)
    Pulse::Domain::AlertEvent.new(
      project_id: 42, event_type: event_type, from: 'green', to: 'amber',
      score: score, previous_score: previous_score, delta: delta, occurred_at: OCC
    )
  end

  def serialize(ev, health:, previous:, redact: false)
    Pulse::Adapters::WebhookPayloadSerializer.serialize(
      ev, project: Proj.new(42, 'apollo', 'Apollo Platform'),
      health_result: health, redact: redact, previous: previous
    )
  end

  # ── (a) each frozen seed instance validates ─────────────────────
  def test_seed_instances_validate_against_frozen_schema
    seeds = YAML.load_file(SEED)
    refute_empty seeds
    seeds.each_with_index { |inst, i| assert_schema(inst, "seed ##{i}") }
  end

  # ── (b) serializer output validates for ALL FOUR event types ────
  def test_serializer_output_validates_for_all_four_event_types
    normal_health = Health.new(42, 58, :amber, :risk_load)
    prev = { rag: 'green', dominant_signal: 'momentum' }

    %i[rag_transition dominant_change score_delta].each do |et|
      body = JSON.parse(serialize(event(event_type: et), health: normal_health, previous: prev))
      assert_schema(body, "serializer output for #{et}")
      assert_equal et.to_s, body['event']
    end

    # no_data_appeared: null score/dominant, no previous.
    nd_health = Health.new(42, nil, :no_data, nil)
    nd_body = JSON.parse(serialize(
      event(event_type: :no_data_appeared, delta: nil, score: nil, previous_score: nil),
      health: nd_health, previous: nil
    ))
    assert_schema(nd_body, 'serializer output for no_data_appeared')
    assert_nil nd_body['health']['score']
    assert_equal 'no_data', nd_body['health']['rag']
  end

  # ── redacted output still validates (via the gem) ─────────────────
  def test_redacted_output_still_validates
    body = JSON.parse(serialize(
      event(event_type: :rag_transition),
      health: Health.new(42, 58, :amber, :risk_load),
      previous: { rag: 'green', dominant_signal: 'momentum' }, redact: true
    ))
    assert_schema(body, 'redacted body (optional fields omitted) must still validate')
  end

  # ── negative guards: schema is genuinely enforced ───────────────────────────
  def test_extra_top_level_key_fails_gem_validation
    body = JSON.parse(serialize(event(event_type: :rag_transition),
                                health: Health.new(42, 58, :amber, :risk_load),
                                previous: { rag: 'green', dominant_signal: 'momentum' }))
    body['injected'] = 'x'
    refute_empty JSON::Validator.fully_validate(SCHEMA, body, strict: false),
                 'additionalProperties:false must reject an extra top-level key'
  end

  def test_wrong_version_fails_gem_validation
    body = JSON.parse(serialize(event(event_type: :rag_transition),
                                health: Health.new(42, 58, :amber, :risk_load),
                                previous: { rag: 'green', dominant_signal: 'momentum' }))
    body['version'] = '2'
    refute_empty JSON::Validator.fully_validate(SCHEMA, body, strict: false),
                 'version const "1" must reject "2"'
  end
end
