# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'json'
require 'time'

# Note: pure-adapter unit lane — add lib/ to $LOAD_PATH before requiring the
# adapter so its internal `require 'pulse/...'` lines resolve. Run:
#   ruby -Itest -Ilib test/unit/adapters/webhook_payload_serializer_test.rb
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/domain/alert_event'
require 'pulse/adapters/webhook_payload_serializer'

# WebhookPayloadSerializer emits versioned JSON
# that VALIDATES against the FROZEN schema at
#   docs/specs/pulse-roadmap/contracts/schemas/webhook-payload.json
# for ALL FOUR AlertEvent::EVENT_TYPES, sourcing each field per the field→source map:
#   version   const "1"
#   event     AlertEvent.event_type.to_s
#   project.* from a duck-typed Project (id/identifier/name) — id == AlertEvent.project_id
#   health.*  from a duck-typed HealthResult (score Integer|nil, rag Symbol->String,
#             dominant_signal Symbol|nil -> String|null); delta from AlertEvent.delta
#   previous  from the PRIOR ALERT-STATE ROW {rag,dominant_signal} or null on first obs
#   occurred_at  AlertEvent.occurred_at -> UTC ISO8601
#
# The `json-schema` gem is NOT on the pure lane (harness-only), so this suite validates
# STRUCTURALLY against the frozen schema file: required keys present, no extra keys
# (additionalProperties:false), types, enums, and const applied. The full-gem validation
# lives in the harness lane (webhook_serializer_schema_test.rb).
class WebhookPayloadSerializerTest < Minitest::Test
  SCHEMA_PATH = File.expand_path(
    '../../../docs/specs/pulse-roadmap/contracts/schemas/webhook-payload.json', __dir__
  )
  OCC = Time.utc(2026, 7, 6, 9, 30, 0)

  # ── duck-typed composition-root inputs (Project + HealthResult) ─────────────
  Proj = Struct.new(:id, :identifier, :name)
  Health = Struct.new(:project_id, :health_score, :rag, :dominant_signal)

  def schema
    @schema ||= JSON.parse(File.read(SCHEMA_PATH))
  end

  def project(id: 42, identifier: 'apollo', name: 'Apollo Platform')
    Proj.new(id, identifier, name)
  end

  def health(rag: :amber, score: 58, dominant_signal: :risk_load, project_id: 42)
    Health.new(project_id, score, rag, dominant_signal)
  end

  def alert_event(event_type: :rag_transition, project_id: 42,
                  from: 'green', to: 'amber', score: 58, previous_score: 72, delta: -14.0)
    Pulse::Domain::AlertEvent.new(
      project_id: project_id, event_type: event_type, from: from, to: to,
      score: score, previous_score: previous_score, delta: delta, occurred_at: OCC
    )
  end

  def serialize(event, **overrides)
    args = { project: project, health_result: health, redact: false, previous: nil }.merge(overrides)
    Pulse::Adapters::WebhookPayloadSerializer.serialize(event, **args)
  end

  def parsed(*args, **kwargs)
    JSON.parse(serialize(*args, **kwargs))
  end

  # ── STRUCTURAL schema validation helpers (pure lane; no json-schema gem) ────

  # Validate `instance` against the (subset of draft-2020-12) `sch` that this frozen
  # schema uses: type (incl. ["integer","null"]), required, additionalProperties:false,
  # const, enum, minimum/maximum, minLength, object/array recursion.
  def schema_errors(instance, sch = schema, path = '$')
    errs = []
    types = Array(sch['type'])
    errs.concat(type_errors(instance, types, path)) unless types.empty?
    if sch['const'] && instance != sch['const']
      errs << "#{path}: const mismatch (want #{sch['const'].inspect}, got #{instance.inspect})"
    end
    if sch['enum'] && !sch['enum'].include?(instance)
      errs << "#{path}: #{instance.inspect} not in enum #{sch['enum'].inspect}"
    end
    if instance.is_a?(Numeric)
      errs << "#{path}: below minimum" if sch['minimum'] && instance < sch['minimum']
      errs << "#{path}: above maximum" if sch['maximum'] && instance > sch['maximum']
    end
    if instance.is_a?(String) && sch['minLength'] && instance.length < sch['minLength']
      errs << "#{path}: shorter than minLength #{sch['minLength']}"
    end
    if instance.is_a?(Hash) && sch['properties']
      Array(sch['required']).each do |k|
        errs << "#{path}: missing required key #{k.inspect}" unless instance.key?(k)
      end
      if sch['additionalProperties'] == false
        extra = instance.keys - sch['properties'].keys
        errs << "#{path}: additional properties #{extra.inspect}" unless extra.empty?
      end
      instance.each do |k, v|
        next unless sch['properties'][k]

        errs.concat(schema_errors(v, sch['properties'][k], "#{path}.#{k}"))
      end
    end
    errs
  end

  def type_errors(instance, types, path)
    ok = types.any? do |t|
      case t
      when 'object'  then instance.is_a?(Hash)
      when 'array'   then instance.is_a?(Array)
      when 'string'  then instance.is_a?(String)
      when 'integer' then instance.is_a?(Integer)
      when 'number'  then instance.is_a?(Numeric)
      when 'boolean' then [true, false].include?(instance)
      when 'null'    then instance.nil?
      else true
      end
    end
    ok ? [] : ["#{path}: type mismatch (want #{types.inspect}, got #{instance.class})"]
  end

  def assert_valid(instance, msg = nil)
    errs = schema_errors(instance)
    assert_empty errs, [msg, errs.join("\n")].compact.join("\n")
  end

  # ── (a) each frozen SEED instance validates structurally ────────
  def test_seed_instances_validate_structurally
    seeds = YAML_LOAD_SEEDS
    refute_empty seeds, 'frozen seed file must carry validating instances'
    seeds.each_with_index do |inst, i|
      assert_valid(inst, "seed instance ##{i} must validate against the frozen schema")
    end
  end

  # Load the seed via a tiny hand parser is overkill; use the stdlib YAML (Psych) which is
  # available on the pure lane.
  def self.load_seeds
    require 'yaml'
    YAML.load_file(File.expand_path(
      '../../../docs/specs/pulse-roadmap/contracts/seeds/webhook-payload.yaml', __dir__
    ))
  end
  YAML_LOAD_SEEDS = load_seeds

  # ── (b) serializer OUTPUT validates for ALL FOUR event types ────
  def test_output_validates_for_all_four_event_types
    %i[rag_transition dominant_change no_data_appeared score_delta].each do |et|
      if et == :no_data_appeared
        h = health(rag: :no_data, score: nil, dominant_signal: nil)
        e = alert_event(event_type: et, score: nil, previous_score: nil, delta: nil)
        body = parsed(e, health_result: h, previous: nil)
      else
        e = alert_event(event_type: et)
        body = parsed(e, previous: { rag: 'green', dominant_signal: 'momentum' })
      end
      assert_valid(body, "serializer output for #{et} must validate against the frozen schema")
      assert_equal et.to_s, body['event'], "event field must be #{et}"
    end
  end

  # ── field→source map ────────────────────────────────────────────
  def test_version_is_the_literal_string_one
    assert_equal '1', parsed(alert_event)['version'], 'version is the const "1" (a String)'
  end

  def test_project_block_sourced_from_project_not_the_event
    body = parsed(alert_event(project_id: 42), project: project(id: 42, identifier: 'apollo', name: 'Apollo Platform'))
    assert_equal 42, body['project']['id'], 'project.id == AlertEvent.project_id == Project#id'
    assert_equal 'apollo', body['project']['identifier'], 'project.identifier from the Project'
    assert_equal 'Apollo Platform', body['project']['name'], 'project.name from the Project'
  end

  def test_health_block_sourced_from_health_result_symbols_to_strings
    body = parsed(alert_event, health_result: health(rag: :amber, score: 58, dominant_signal: :risk_load))
    assert_equal 58, body['health']['score'], 'health.score is the Integer from HealthResult'
    assert_equal 'amber', body['health']['rag'], 'health.rag is HealthResult#rag.to_s'
    assert_equal 'risk_load', body['health']['dominant_signal'], 'dominant_signal Symbol -> String'
  end

  def test_no_data_health_block_is_nulls
    h = health(rag: :no_data, score: nil, dominant_signal: nil)
    e = alert_event(event_type: :no_data_appeared, score: nil, previous_score: nil, delta: nil)
    body = parsed(e, health_result: h, previous: nil)
    assert_nil body['health']['score'], 'no_data: health.score is null'
    assert_equal 'no_data', body['health']['rag']
    assert_nil body['health']['dominant_signal'], 'no_data: dominant_signal is null'
  end

  def test_previous_sourced_from_prior_alert_state_row
    body = parsed(alert_event, previous: { rag: 'green', dominant_signal: 'momentum' })
    assert_equal 'green', body['previous']['rag'], 'previous.rag from prior alert-state last_rag'
    assert_equal 'momentum', body['previous']['dominant_signal'], 'previous.dominant_signal from last_dominant'
  end

  def test_previous_is_null_on_first_observation
    body = parsed(alert_event, previous: nil)
    # schema allows previous absent OR null; either is valid. If emitted it must be null.
    assert(!body.key?('previous') || body['previous'].nil?,
           'previous is omitted or null on first observation / no prior row')
  end

  def test_occurred_at_is_utc_iso8601
    at = parsed(alert_event)['occurred_at']
    assert_equal '2026-07-06T09:30:00Z', at, 'occurred_at is UTC RFC3339/ISO8601'
  end

  def test_signature_field_present_and_nonempty
    sig = parsed(alert_event)['signature']
    assert_kind_of String, sig
    refute_empty sig, 'schema requires signature minLength 1 (HMAC hexdigest)'
  end

  # ── NEGATIVE guards: the schema is actually applied ─────────────────────────
  def test_negative_extra_top_level_key_fails_structural_validation
    bad = parsed(alert_event).merge('injected' => 'x')
    refute_empty schema_errors(bad), 'additionalProperties:false must reject an extra top-level key'
  end

  def test_negative_wrong_version_const_fails
    bad = parsed(alert_event).merge('version' => '2')
    refute_empty schema_errors(bad), 'version const "1" must reject "2"'
  end

  def test_negative_bad_rag_enum_fails
    bad = parsed(alert_event)
    bad['health']['rag'] = 'purple'
    refute_empty schema_errors(bad), 'health.rag enum must reject an out-of-enum value'
  end
end
