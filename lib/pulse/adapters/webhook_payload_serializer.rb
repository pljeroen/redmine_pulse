# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'json'
require 'openssl'
require 'time'

module Pulse
  module Adapters
    # WebhookPayloadSerializer — maps a domain AlertEvent + duck-typed Project +
    # HealthResult (+ the prior alert-state row) into the FROZEN, versioned JSON webhook
    # body. Adapter layer: it does NO I/O and reaches no
    # Redmine constant — it reads plain readers off the composition-root-supplied inputs
    # (identifier/name; health_score/rag/dominant_signal) so it is unit-testable off the
    # domain path and against Structs.
    #
    # Field -> source map:
    #   version           const "1"
    #   event             AlertEvent#event_type.to_s
    #   project.id        AlertEvent#project_id (== Project#id)
    #   project.identifier/name  Project readers (NOT on the VO)
    #   health.score      HealthResult#health_score (Integer 0..100 | nil)
    #   health.rag        HealthResult#rag.to_s
    #   health.dominant_signal   HealthResult#dominant_signal&.to_s (String | null)
    #   health.delta      AlertEvent#delta (Numeric | nil) — OPTIONAL, redactable
    #   previous          prior alert-state row {rag, dominant_signal} | null — OPTIONAL,
    #                     redactable (sourced from the prior state row, not HealthResult)
    #   occurred_at       AlertEvent#occurred_at.utc.iso8601 (RFC3339)
    #   signature         HMAC-SHA256 hexdigest over the exact emitted body
    #
    # REDACTION: the redactable set is PINNED to the schema's OPTIONAL fields
    # ONLY — { previous, health.delta }. Redaction OMITS (never placeholders) them BEFORE
    # signing so the signature covers the redacted body and the reduced body still validates.
    module WebhookPayloadSerializer
      VERSION = '1'

      # The two OPTIONAL (redactable) schema fields, addressed by dotted path.
      REDACTABLE_FIELDS = %w[previous health.delta].freeze

      module_function

      # serialize(alert_event, project:, health_result:, redact:, previous:) -> String
      #   The single JSON body String. `redact` is either a truthy flag (redact the whole
      #   redactable set) or an Array of dotted field paths to omit (a subset of
      #   REDACTABLE_FIELDS). `previous` is the prior alert-state row {rag, dominant_signal}
      #   or nil (first observation / no prior row). `secret` (optional) is the endpoint
      #   HMAC secret; when present the in-body signature is the real HMAC hexdigest,
      #   otherwise a deterministic non-empty placeholder digest (the header carries the
      #   authoritative digest at delivery time — the dispatcher re-signs the exact bytes).
      def serialize(alert_event, project:, health_result:, redact:, previous:, secret: nil)
        redacted = redacted_fields(redact)

        health = {
          'score' => health_result.health_score,
          'rag' => health_result.rag.to_s,
          'dominant_signal' => health_result.dominant_signal&.to_s
        }
        health['delta'] = alert_event.delta unless redacted.include?('health.delta')

        body = {
          'version' => VERSION,
          'event' => alert_event.event_type.to_s,
          'project' => {
            'id' => alert_event.project_id,
            'identifier' => project.identifier,
            'name' => project.name
          },
          'health' => health,
          'occurred_at' => iso8601(alert_event.occurred_at)
        }

        unless redacted.include?('previous')
          body['previous'] = previous.nil? ? nil : previous_block(previous)
        end

        # The in-body signature mirrors the delivered digest. It is computed over the body
        # WITHOUT the signature field itself, so a receiver reconstructing the pre-sign body
        # can recompute it. When no secret is supplied (pure serializer lane) a stable
        # non-empty digest keeps the schema's minLength:1 satisfied; the dispatcher overwrites
        # it with the real HMAC over the exact posted bytes at delivery time.
        body['signature'] = signature_for(body, secret)

        JSON.generate(body)
      end

      # Resolve the redaction request into the concrete set of dotted paths to omit. A truthy
      # boolean redacts the WHOLE redactable set; an Array is intersected with the redactable
      # set (a request naming a non-redactable field is ignored here — the sanitizer already
      # rejects it at settings write time). Falsy => nothing redacted.
      def redacted_fields(redact)
        return [] if redact.nil? || redact == false
        return REDACTABLE_FIELDS.dup if redact == true

        Array(redact).map(&:to_s) & REDACTABLE_FIELDS
      end

      # previous -> {rag, dominant_signal} using indifferent (symbol/string) access, so the
      # composition root may pass either shape (the prior row is symbol-keyed; tests pass
      # symbol-keyed literals).
      def previous_block(previous)
        {
          'rag' => fetch_indifferent(previous, :rag).to_s,
          'dominant_signal' => nilable_string(fetch_indifferent(previous, :dominant_signal))
        }
      end

      def fetch_indifferent(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def nilable_string(value)
        value.nil? ? nil : value.to_s
      end

      # UTC RFC3339/ISO8601. Accepts a Time; a String is passed through when already
      # ISO8601-shaped (defensive — the domain injects a Time).
      def iso8601(occurred_at)
        return occurred_at if occurred_at.is_a?(String)

        occurred_at.utc.iso8601
      end

      # HMAC-SHA256 hexdigest over the exact JSON body (signature field excluded). With no
      # secret, a deterministic SHA256 hexdigest of the body keeps the field non-empty for the
      # pure schema check without leaking anything (it is not a valid HMAC — the delivered
      # header is authoritative).
      def signature_for(body, secret)
        bytes = JSON.generate(body)
        return OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, bytes) unless secret.nil?

        OpenSSL::Digest::SHA256.hexdigest(bytes)
      end
    end
  end
end
