# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'uri'
require 'pulse/domain/signal_registry'
require 'pulse/domain/alert_event'

module Pulse
  module Adapters
    # SettingsSanitizer — validates an incoming plugin-settings hash to the EXACT
    # ScoringConfig bounds and REJECTS invalid scalar values by keeping the
    # previously-persisted value for that key (the invalid input is never persisted). It
    # is pure Ruby (no Rails/AR) so it is unit-testable and so the admin POST path can
    # sanitize before `Setting.plugin_redmine_pulse=` persists.
    #
    # Bounds enforced (read off the as-built ScoringConfig definition):
    #   rag_green_min / rag_amber_min : Integer in [0,100], amber <= green
    #   h_stale / h_risk / h_blocked  : Integer >= 1
    #   activity_window_days          : Integer >= 1
    #   weights                       : exactly the 5 signal keys, each finite
    #                                   Numeric >= 0, summing to 1.0 (else dropped to
    #                                   defaults — never a partial/invalid set)
    #
    # Returns [sanitized_hash, errors] where errors is an Array<String> of human keys
    # that were rejected (empty == fully valid).
    module SettingsSanitizer
      # WEIGHT_KEYS / ALWAYS_ACTIVE are SOURCED from the domain SignalRegistry (single source
      # of truth) — string-keyed here because the settings hash uses string keys.
      #
      # The required weight-key set is a RUNTIME value derived from the incoming
      # enable_coverage_gap flag combined with SignalRegistry.default_on_keys — NOT the static
      # SignalRegistry.keys (which now includes the registered-but-default_on:false
      # coverage_gap). The DEFAULT-ON keys are the 5 built-in signals; enabling coverage_gap adds
      # its key to the required set. See weight_keys_for.
      DEFAULT_ON_KEYS = Pulse::Domain::SignalRegistry.default_on_keys.map(&:to_s).freeze
      COVERAGE_GAP_KEY = 'coverage_gap'
      # Retained for readers that referenced the earlier constant name; equals the default-on set
      # (the disabled/default required weight-key set).
      WEIGHT_KEYS = DEFAULT_ON_KEYS
      ALWAYS_ACTIVE = Pulse::Domain::SignalRegistry.always_active_keys.map(&:to_s).freeze

      module_function

      # Adapter-layer proportional renormalization on a signal
      # toggle. When `disable` is removed from the enabled set, the remaining weights are
      # rescaled proportionally so they sum to 1.0 and every pairwise ratio is preserved:
      #   w_i_new = w_i_old / Σ_{remaining} w_j_old
      # This is a WRITE-PATH (adapter) behavior, distinct from the pure-domain VO strictness
      # — the domain VO never renormalizes; it only validates. Accepts string- or
      # symbol-keyed weights; returns a new hash keyed as the input was, with `disable`
      # dropped. Raises ArgumentError if the remaining weights sum to <= 0 (no proportion
      # to preserve).
      def renormalize_on_toggle(weights, disable)
        disabled = disable.to_s
        remaining = weights.reject { |k, _| k.to_s == disabled }
        total = remaining.values.sum
        raise ArgumentError, 'cannot renormalize: remaining weight-sum <= 0' if total <= 0.0

        remaining.each_with_object({}) do |(k, w), acc|
          acc[k] = w / total
        end
      end

      # incoming: the candidate settings hash (string keys, string-ish values).
      # previous: the currently-persisted settings hash (the fallback for rejects).
      def sanitize(incoming, previous)
        incoming = stringify(incoming)
        previous = stringify(previous)
        result = previous.dup
        errors = []

        %w[rag_green_min rag_amber_min].each do |k|
          v = integer_in_range(incoming[k], 0, 100)
          if v.nil?
            errors << k
          else
            result[k] = v
          end
        end
        # amber must be <= green for coherent bands.
        if result['rag_amber_min'].to_i > result['rag_green_min'].to_i
          errors << 'rag_amber_min'
          result['rag_green_min'] = previous['rag_green_min']
          result['rag_amber_min'] = previous['rag_amber_min']
        end

        %w[h_stale h_risk h_blocked activity_window_days].each do |k|
          v = integer_at_least(incoming[k], 1)
          if v.nil?
            errors << k
          else
            result[k] = v
          end
        end

        # Float-shaped momentum / on-track shape fields (promoted from domain constants).
        # momentum_activity_half: strictly positive; momentum_direction_bias: [0,0.5];
        # on_track_threshold: [0,1]. These are DEFAULTED fields: a BLANK/absent value means
        # "use the shipped default" (mirrors RedmineSettingsProvider#float_setting and the
        # weights sanitizer's blank => keep behaviour), so it is NOT an error — we leave the
        # key unset (delete from result) so the provider's default applies at read time. A
        # PRESENT-but-invalid value is STILL rejected: report + retain the prior value.
        {
          'momentum_activity_half' => ->(raw) { float_strictly_positive(raw) },
          'momentum_direction_bias' => ->(raw) { float_in_range(raw, 0.0, 0.5) },
          'on_track_threshold' => ->(raw) { float_in_range(raw, 0.0, 1.0) }
        }.each do |k, validate|
          raw = incoming[k]
          if blank?(raw)
            result.delete(k) # blank/absent => fall back to the shipped default at read time
            next
          end
          v = validate.call(raw)
          if v.nil?
            errors << k # present but non-numeric / out-of-range => reject, keep prior value
          else
            result[k] = v
          end
        end

        # snapshot_max_age_minutes: OPERATIONAL cache freshness cap. Integer >= 0
        # (0 is VALID = disabled). BLANK/absent => "use the shipped default" (delete the
        # key so the provider default 60 applies at read time — mirrors the momentum/
        # weights blank-tolerance), NOT an error. A PRESENT-but-invalid value (negative /
        # non-numeric) is rejected: report + retain the prior value.
        if blank?(incoming['snapshot_max_age_minutes'])
          result.delete('snapshot_max_age_minutes')
        else
          v = integer_at_least(incoming['snapshot_max_age_minutes'], 0)
          if v.nil?
            errors << 'snapshot_max_age_minutes'
          else
            result['snapshot_max_age_minutes'] = v
          end
        end

        # Defense-in-depth: VALIDATE admin-set enrichment ids at save time —
        # defense-in-depth, not passthrough. effort_field / blocked_status are single
        # positive-integer ids; risk_trackers is a LIST of positive-integer ids. A BLANK/
        # absent value means "unmapped => use the default" (delete the scalar key / empty
        # list — mirrors the momentum/snapshot blank-tolerance), NOT an error. A PRESENT-
        # but-INVALID scalar (non-integer / non-positive) is REJECTED: report + retain the
        # prior value (never persist the garbage verbatim). For the multi-select tracker
        # list we DROP any non-positive-integer element (keep the valid integer subset) so
        # a stray non-integer id never survives.
        %w[effort_field blocked_status].each do |k|
          raw = incoming[k]
          if blank?(raw)
            result.delete(k) # blank/absent => unmapped, fall back to the default at read time
            next
          end
          v = integer_at_least(raw, 1)
          if v.nil?
            errors << k # present but non-integer / non-positive => reject, keep prior value
          else
            result[k] = v
          end
        end
        result['risk_trackers'] = normalize_trackers(incoming.fetch('risk_trackers', previous['risk_trackers']))

        # enable_coverage_gap is AUTHORITATIVE for the weight-key set. When truthy the
        # required set is the 6 keys {5 default_on + coverage_gap}; when falsy it is the 5
        # default_on keys and coverage_gap is NEVER persisted (stripped on every path, incl. the
        # invalid-weight fallback). The flag itself is persisted as a scalar settings key so the
        # settings_version_hash moves on toggle; a falsy/blank incoming flag removes it.
        enabled = truthy?(incoming['enable_coverage_gap'])
        if enabled
          result['enable_coverage_gap'] = '1'
        else
          result.delete('enable_coverage_gap')
        end

        weights, weight_err = sanitize_weights(incoming['weights'], previous['weights'], enabled)
        result['weights'] = weights
        errors << 'weights' if weight_err

        # Two ADDITIVE alert settings keys, alert-OFF defaults:
        #   pulse_alert_auto_subscribe_role_id : Integer >= 1, or nil (nil = disabled DEFAULT).
        #     Present-but-invalid (non-integer / non-positive) => reject, keep prior value.
        #     ABSENT => the key is not synthesized (additivity — a hash without it is untouched).
        #     An EXPLICIT nil is accepted as the disabled state (stored as nil).
        #   pulse_alert_score_delta_threshold  : Numeric >= 0 (0/nil = disabled DEFAULT).
        #     Present-but-invalid (negative / non-numeric) => reject, keep prior value.
        #     ABSENT => not synthesized. An EXPLICIT nil is accepted as disabled (stored nil).
        # These are the ONLY alert settings; both default OFF so no alert fires on install.
        sanitize_alert_role_id(incoming, result, errors)
        sanitize_alert_score_delta_threshold(incoming, result, errors)

        # Additive pulse_profiles validation. Absent in the incoming hash => nothing added
        # (the synthetic default needs no entry; the profiles-free result stays byte-identical
        # to a sanitized value that predates scoring profiles). Present => validate each profile
        # + role-binding and REJECT invalid entries wholesale.
        sanitize_pulse_profiles(incoming['pulse_profiles'], result, errors)

        # Two ADDITIVE webhook settings keys, OFF by default. Absent => not synthesized
        # (additive — pre-existing keys byte-unchanged). Present => validate each EndpointConfig;
        # a MALFORMED entry REJECTS the whole key and keeps the prior value (never partially
        # persisted, mirroring the alert-settings reject-keep-prior).
        sanitize_webhook_endpoints_global(incoming, previous, result, errors)
        sanitize_webhook_endpoints_per_project(incoming, previous, result, errors)

        [result, errors]
      end

      # Webhook constants. EVENT_TYPES is sourced from the domain AlertEvent (single source
      # of truth); the redactable set is PINNED to the schema's OPTIONAL fields ONLY.
      WEBHOOK_EVENT_TYPES = Pulse::Domain::AlertEvent::EVENT_TYPES.map(&:to_s).freeze
      WEBHOOK_REDACTABLE_FIELDS = %w[previous health.delta].freeze
      WEBHOOK_ENDPOINTS_GLOBAL_KEY = 'pulse_webhook_endpoints_global'
      WEBHOOK_ENDPOINTS_PER_PROJECT_KEY = 'pulse_webhook_endpoints_per_project'

      # pulse_webhook_endpoints_global : Array<EndpointConfig>. Additive — only touched when
      # present. On ANY malformed endpoint the whole key is REJECTED (reported) and the prior
      # value retained (never partially persisted).
      def sanitize_webhook_endpoints_global(incoming, previous, result, errors)
        key = WEBHOOK_ENDPOINTS_GLOBAL_KEY
        return unless incoming.key?(key)

        list = coerce_endpoint_list(incoming[key])
        if list.nil?
          errors << key
          result[key] = previous[key]
          return
        end

        prior_list = Array(previous[key])
        clean = []
        list.each do |raw|
          next if removed_or_empty_endpoint_row?(raw) # no-JS remove / empty add row

          ep = sanitize_endpoint_config(raw, prior_secret: prior_secret_for(raw, prior_list))
          if ep.nil?
            errors << key
            result[key] = previous.fetch(key, [])
            return
          end
          clean << ep
        end
        result[key] = clean
      end

      # Coerce the posted endpoint list to an ordered Array. Accepts:
      #   * an Array (canonical / console / API shape) — returned as-is;
      #   * a Hash of indexed rows (the no-JS form posts settings[..][0][..], [1][..], [__new__])
      #     — Rails parses that as a Hash; order numeric keys ascending, the blank __new__ add
      #     row last, so a save round-trips ALL rows (none silently dropped).
      # Returns nil for any other shape (=> the whole key is rejected, prior kept).
      def coerce_endpoint_list(raw)
        return raw if raw.is_a?(Array)
        return nil unless raw.is_a?(Hash)

        numeric, non_numeric = raw.to_a.partition { |k, _| k.to_s.match?(/\A\d+\z/) }
        ordered = numeric.sort_by { |k, _| k.to_s.to_i } + non_numeric
        ordered.map { |_, v| v }
      end

      # No-JS multi-endpoint editor: a row flagged `remove` is DROPPED; the form's
      # blank "add" row (marked `add_row` and left empty) is SILENTLY skipped (not an error) —
      # mirroring the pulse_profiles empty-slot pattern. A row WITHOUT the add_row marker is
      # NOT auto-skipped: a blank-url canonical/console endpoint still validates (and rejects),
      # preserving the reject-keep-prior behavior for a genuinely malformed entry.
      def removed_or_empty_endpoint_row?(raw)
        return false unless raw.is_a?(Hash)

        row = stringify(raw)
        return true if truthy?(row['remove'])

        truthy?(row['add_row']) && blank?(row['url'])
      end

      # pulse_webhook_endpoints_per_project : Hash<project_id, Array<EndpointConfig>>. Same
      # per-endpoint validation as the global key, keyed by project id (string). A malformed
      # endpoint anywhere REJECTS the whole key and keeps the prior value.
      def sanitize_webhook_endpoints_per_project(incoming, previous, result, errors)
        key = WEBHOOK_ENDPOINTS_PER_PROJECT_KEY
        return unless incoming.key?(key)

        map = incoming[key]
        unless map.is_a?(Hash)
          errors << key
          result[key] = previous[key]
          return
        end

        clean = {}
        map.each do |pid, list|
          unless list.is_a?(Array)
            errors << key
            result[key] = previous.fetch(key, {})
            return
          end
          prior_list = Array((previous[key] || {})[pid.to_s])
          endpoints = []
          list.each do |raw|
            next if removed_or_empty_endpoint_row?(raw)

            ep = sanitize_endpoint_config(raw, prior_secret: prior_secret_for(raw, prior_list))
            if ep.nil?
              errors << key
              result[key] = previous.fetch(key, {})
              return
            end
            endpoints << ep
          end
          clean[pid.to_s] = endpoints
        end
        result[key] = clean
      end

      # Validate one EndpointConfig -> a clean string-keyed Hash, or nil if malformed.
      #   url          : non-blank http(s) URL.
      #   secret       : non-blank String when provided. The no-JS "keep existing" secret
      #                  affordance: the settings form renders a BLANK password field for a
      #                  configured secret (never echoes it) plus a `secret_present` marker.
      #                  A BLANK submitted secret means "keep the prior secret" when a prior
      #                  secret exists (preserved via prior_secret) — NOT wipe it on an
      #                  unrelated save. A NON-blank secret replaces. With no prior secret a
      #                  blank field stays nil (unsigned — the operator's choice).
      #   enabled / ssrf_override / allow_http : Boolean, default false.
      #   event_filter : Array<String> ⊆ EVENT_TYPES, default [] (= all). Any out-of-set
      #                  entry rejects the endpoint.
      #   redaction    : false (default) OR an Array of dotted paths ⊆ {previous, health.delta}.
      #                  Requesting a REQUIRED (non-redactable) field rejects the endpoint
      #                  `true` is accepted as "redact the whole redactable set".
      def sanitize_endpoint_config(raw, prior_secret: nil)
        return nil unless raw.is_a?(Hash)

        ep = stringify(raw)

        url = ep['url']
        return nil if blank?(url) || !url.is_a?(String)
        return nil unless http_url?(url) # reject non-http(s) schemes at WRITE time

        event_filter = sanitize_event_filter(ep['event_filter'])
        return nil if event_filter.nil?

        redaction = sanitize_redaction(ep['redaction'])
        return nil if redaction == :invalid

        secret = resolve_secret(ep, prior_secret)
        # Safe default: every DELIVERED webhook must be HMAC-SHA256 signed
        # with the per-endpoint secret. An endpoint whose EFFECTIVE secret (submitted-non-blank
        # OR prior) is empty/nil therefore MUST NOT be enabled — an enabled-but-unsigned endpoint
        # would ship an empty-key HMAC (non-authenticating). We keep the row (URL/config
        # preserved so the operator can add a secret and enable later) but FORCE enabled=false
        # rather than dropping their config. Deliberately-unsigned webhooks are NOT an implicit
        # default; enabling one requires a real secret.
        enabled = truthy?(ep['enabled']) && !blank?(secret)

        {
          'url' => url,
          'secret' => secret,
          'enabled' => enabled,
          'ssrf_override' => truthy?(ep['ssrf_override']),
          'allow_http' => truthy?(ep['allow_http']),
          'event_filter' => event_filter,
          'redaction' => redaction
        }
      end

      # Resolve the persisted secret. A NON-blank submitted secret replaces. A BLANK
      # submitted secret KEEPS the prior secret when one is carried (the "leave blank to keep
      # current" no-JS affordance — the form never echoes the stored secret), else stays nil
      # (unsigned). prior_secret is nil unless the caller matched this row to a prior endpoint.
      def resolve_secret(ep, prior_secret)
        submitted = ep['secret']
        return submitted.to_s unless blank?(submitted)

        blank?(prior_secret) ? nil : prior_secret.to_s
      end

      # Match an incoming endpoint row to its prior secret for the keep-blank affordance.
      # The form emits a hidden `prior_index` for a previously-persisted row; a blank/absent
      # index (a freshly-added row) has no prior secret. Fail-safe: an out-of-range index
      # yields nil (no secret leaked, no crash).
      def prior_secret_for(raw, prior_list)
        return nil unless raw.is_a?(Hash)

        row = stringify(raw)
        idx = strict_integer(row['prior_index'])
        return nil if idx.nil? || idx.negative? || idx >= prior_list.size

        prior = prior_list[idx]
        prior.is_a?(Hash) ? (prior['secret'] || prior[:secret]) : nil
      end

      # An endpoint url must be an http(s) URL at WRITE time (defense-in-depth
      # complementing the delivery-time HTTPS/allow_http guard). A non-http(s) scheme
      # (ftp:/file:/javascript:/…) or an unparseable url rejects the endpoint (reject-keep-
      # prior, consistent with the sanitizer pattern). fail-closed on parse error.
      def http_url?(url)
        scheme = URI.parse(url.to_s).scheme
        !scheme.nil? && scheme.match?(/\Ahttps?\z/i)
      rescue URI::InvalidURIError
        false
      end

      # event_filter -> Array<String> subset of EVENT_TYPES, or nil if any entry is out of set.
      # nil/blank/absent => [] (all events).
      def sanitize_event_filter(raw)
        return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
        return nil unless raw.is_a?(Array)

        filter = raw.map(&:to_s)
        return nil unless filter.all? { |t| WEBHOOK_EVENT_TYPES.include?(t) }

        filter
      end

      # redaction -> false | Array<String> (dotted paths ⊆ redactable set) | :invalid.
      #   nil / false / '0' / blank        => false (nothing redacted).
      #   true / '1' / 'true' (scalar)     => the full redactable set (the no-JS checkbox form).
      #   Array within the redactable set  => that subset.
      #   Array naming a required field    => :invalid (rejected at write time).
      def sanitize_redaction(raw)
        return false if raw.nil? || raw == false || (raw.respond_to?(:empty?) && raw.empty?)
        return WEBHOOK_REDACTABLE_FIELDS.dup if raw == true

        # A scalar (String/Integer) checkbox value: truthy => full set, falsy => nothing.
        unless raw.is_a?(Array)
          return truthy?(raw) ? WEBHOOK_REDACTABLE_FIELDS.dup : false
        end

        fields = raw.map(&:to_s)
        return :invalid unless fields.all? { |f| WEBHOOK_REDACTABLE_FIELDS.include?(f) }

        fields
      end

      # Alert auto-subscribe role id: Integer >= 1, explicit nil = disabled. Additive — the key
      # is only touched when present in `incoming`. Present-but-invalid keeps the prior value
      # and reports the key (existing guard pattern). 0 is NOT a valid role id (rejected).
      def sanitize_alert_role_id(incoming, result, errors)
        key = 'pulse_alert_auto_subscribe_role_id'
        return unless incoming.key?(key)

        raw = incoming[key]
        if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
          result[key] = nil # explicit nil / blank => auto-subscribe disabled (valid)
          return
        end

        v = integer_at_least(raw, 1)
        if v.nil?
          errors << key # non-integer / non-positive => reject, keep prior value
        else
          result[key] = v
        end
      end

      # Alert score_delta threshold N: Numeric >= 0 (0/nil = disabled). Additive — only touched
      # when present. Present-but-invalid (negative / non-numeric) keeps the prior value and
      # reports the key. 0 is VALID (disabled). An explicit nil/blank is accepted as disabled.
      def sanitize_alert_score_delta_threshold(incoming, result, errors)
        key = 'pulse_alert_score_delta_threshold'
        return unless incoming.key?(key)

        raw = incoming[key]
        if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
          result[key] = nil # explicit nil / blank => score_delta disabled (valid)
          return
        end

        v = numeric_at_least(raw, 0)
        if v.nil?
          errors << key # negative / non-numeric => reject, keep prior value
        else
          result[key] = v
        end
      end

      # A numeric (Integer or Float) value >= min, preserving the incoming numeric shape
      # (Integer stays Integer so `15` round-trips as `15`, not `15.0`). nil for
      # non-numeric / out-of-range. Used by the score_delta threshold validation.
      def numeric_at_least(raw, min)
        return nil if raw.nil?

        n = raw.is_a?(Numeric) ? raw : parse_numeric_setting(raw)
        return nil if n.nil?
        return nil unless n.respond_to?(:finite?) ? n.finite? : true
        return nil if n < min

        n
      end

      # Parse a string that may be an Integer ("15") or a Float ("15.5"). Returns an Integer
      # for an integral string and a Float for a fractional one; nil for non-numeric.
      def parse_numeric_setting(raw)
        s = raw.to_s.strip
        return nil if s.empty?
        return s.to_i if s.match?(/\A-?\d+\z/)

        f = Float(s)
        f.finite? ? f : nil
      rescue ArgumentError, TypeError
        nil
      end

      # Validate the additive pulse_profiles sub-hash IN PLACE on `result`.
      # Only touches `result` when the admin actually supplied a pulse_profiles hash (else
      # the profiles-free result is byte-unchanged; no synthetic key is injected). A profile
      # entry: non-empty id (NOT the reserved "default"), non-empty name, per-field-bounded
      # config (reusing the ScoringConfig weight bounds via validate_weight_set). A role
      # binding: positive-integer role_id, profile_id in the defined set OR the reserved
      # "default". ANY invalid entry is DROPPED entirely and 'pulse_profiles' is reported
      # once (the invalid entry is never partially persisted).
      def sanitize_pulse_profiles(raw, result, errors)
        return unless raw.is_a?(Hash)

        raw = stringify(raw)
        had_error = false

        clean_profiles = {}
        (raw['profiles'] || {}).each do |outer_id, entry|
          entry = stringify(entry) if entry.is_a?(Hash)
          # The outer hash key is the profile id in the canonical shape. The no-JS settings
          # form additionally carries an inner [id] field (so a blank "__new__" slot can name
          # a fresh id) — prefer it when present and non-blank. An unfilled blank slot (no id
          # + no name) is SILENTLY skipped (not an error): it is the empty "add" row.
          inner_id = entry.is_a?(Hash) ? entry['id'] : nil
          effective_id = (inner_id.nil? || inner_id.to_s.strip.empty?) ? outer_id.to_s : inner_id.to_s
          next if empty_profile_slot?(effective_id, entry)

          sanitized_profile = sanitize_profile_entry(effective_id, entry)
          if sanitized_profile.nil?
            had_error = true
          else
            clean_profiles[effective_id] = sanitized_profile
          end
        end

        defined_ids = clean_profiles.keys
        clean_bindings = {}
        normalized_binding_pairs(raw).each do |rid, pid|
          # An entirely blank binding row (no role_id + no profile_id) is the empty "add" slot
          # — silently skipped, not an error.
          next if blank?(rid) && blank?(pid)

          if valid_role_binding?(rid, pid, defined_ids)
            clean_bindings[rid.to_s] = pid.to_s
          else
            had_error = true
          end
        end

        result['pulse_profiles'] = { 'profiles' => clean_profiles, 'role_bindings' => clean_bindings }
        errors << 'pulse_profiles' if had_error
      end

      # A single admin profile entry -> a clean {'name', 'weights'} hash, or nil if invalid.
      # id must be non-empty and NOT the reserved "default"; name non-empty; weights a valid
      # complete set over the 5 default-on keys (Σ==1.0, always-active > 0). The config bounds
      # are REUSED (validate_weight_set), never bypassed.
      def sanitize_profile_entry(id, entry)
        return nil if id.nil? || id.strip.empty?
        return nil if id == 'default' # reserved id — never an admin profile
        return nil unless entry.is_a?(Hash)

        entry = stringify(entry)
        name = entry['name']
        return nil if name.nil? || name.to_s.strip.empty?

        weights, weight_err = validate_weight_set(entry['weights'], nil, DEFAULT_ON_KEYS)
        return nil if weight_err

        { 'name' => name.to_s, 'weights' => weights }
      end

      # True iff a profile slot is entirely empty (no id AND no name/weights) — the empty
      # "add" row in the no-JS settings form, which is silently skipped rather than reported.
      def empty_profile_slot?(effective_id, entry)
        id_blank = effective_id.nil? || effective_id.to_s.strip.empty? || effective_id == '__new__'
        return false unless id_blank
        return true unless entry.is_a?(Hash)

        name = entry['name']
        weights = entry['weights']
        (name.nil? || name.to_s.strip.empty?) &&
          (weights.nil? || (weights.respond_to?(:empty?) && weights.empty?) ||
           (weights.is_a?(Hash) && weights.values.all? { |v| blank?(v) }))
      end

      # Normalize role bindings to [ [role_id, profile_id], ... ] from EITHER shape:
      #   * canonical: role_bindings => { role_id => profile_id };
      #   * form:      role_bindings_pairs => { key => { role_id:, profile_id: } } (no-JS form,
      #     so a dynamic new role_id is expressible as a value, not a static hash key).
      def normalized_binding_pairs(raw)
        pairs = (raw['role_bindings'] || {}).map { |rid, pid| [rid, pid] }
        (raw['role_bindings_pairs'] || {}).each_value do |entry|
          entry = stringify(entry) if entry.is_a?(Hash)
          next unless entry.is_a?(Hash)

          pairs << [entry['role_id'], entry['profile_id']]
        end
        pairs
      end

      # A role binding is valid iff role_id is a positive integer AND profile_id names a
      # defined admin profile OR the reserved "default" (a valid binding TARGET).
      def valid_role_binding?(role_id, profile_id, defined_ids)
        rid = integer_at_least(role_id, 1)
        return false if rid.nil?

        pid = profile_id.to_s
        pid == 'default' || defined_ids.include?(pid)
      end

      # Redmine checkbox / scalar truthiness: '1'/'true'/true are ON; nil/''/'0'/'false' OFF.
      def truthy?(raw)
        return true if raw == true
        return false if raw.nil? || raw == false

        %w[1 true yes on].include?(raw.to_s.strip.downcase)
      end

      # Blank == nil or an empty/whitespace-only string. Used to distinguish "field
      # left untouched on an upgraded instance" (use default) from "present invalid value".
      def blank?(raw)
        raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
      end

      def integer_in_range(raw, lo, hi)
        i = strict_integer(raw)
        return nil if i.nil?
        return nil unless i.between?(lo, hi)

        i
      end

      def integer_at_least(raw, min)
        i = strict_integer(raw)
        return nil if i.nil?
        return nil if i < min

        i
      end

      # Float in the inclusive [lo, hi] range; nil for non-numeric/blank/out-of-range.
      def float_in_range(raw, lo, hi)
        f = strict_float(raw)
        return nil if f.nil?
        return nil unless f.between?(lo, hi)

        f
      end

      # Strictly-positive float (> 0); nil for non-numeric/blank/<= 0.
      def float_strictly_positive(raw)
        f = strict_float(raw)
        return nil if f.nil?
        return nil if f <= 0.0

        f
      end

      # Strict: accepts an Integer or a String of digits only (optional leading sign).
      # "0" is a valid integer (the >= checks reject it as out of range), but "abc" /
      # "1.5" / "" / nil are not integers at all.
      def strict_integer(raw)
        return raw if raw.is_a?(Integer)
        return nil if raw.nil?

        s = raw.to_s.strip
        return nil unless s.match?(/\A-?\d+\z/)

        s.to_i
      end

      # The required weight-key set is DERIVED from the enable flag — the 5 default_on keys
      # when disabled, or those 5 + coverage_gap when enabled. It is NEVER the static
      # SignalRegistry.keys.
      def weight_keys_for(enabled)
        enabled ? (DEFAULT_ON_KEYS + [COVERAGE_GAP_KEY]) : DEFAULT_ON_KEYS
      end

      # weights: keep ONLY when the candidate forms a complete valid set for the enabled
      # required key set; else fall back to previous (or {} => engine defaults). Returns
      # [weights, had_error].
      #
      # INVARIANT: while DISABLED (enabled == false), coverage_gap MUST NEVER appear
      # in the returned weights — on EVERY path, including the invalid-weight fallback. The
      # enable flag is AUTHORITATIVE: a falsy flag over a previously-ENABLED (6-key) config
      # strips coverage_gap and renormalizes the remaining 5 to Σ==1.0 (case c), regardless of
      # what the incoming or previous weights still carry.
      #
      # Enable symmetry: the settings form ships only the 5 weight inputs while
      # coverage_gap is off (the 6th input appears only once enabled), so the ENABLE POST
      # normally arrives with a 5-key weights set. A raw 6-key rejection would leave the
      # config at 5 signals (the "toggle ON but never scored" defect). So on ENABLE we SYNTHESIZE
      # the 6-key map: accept a complete valid 6-key POST as-is (case b), else, when the incoming
      # (or previous fallback) weights are the valid 5-key default_on set, add coverage_gap's
      # default weight and RENORMALIZE all 6 to Σ==1.0 (reusing renormalize_on_toggle) — the
      # symmetric inverse of the disable strip+renormalize.
      def sanitize_weights(raw, previous, enabled)
        required = weight_keys_for(enabled)

        candidate, error =
          if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
            [previous || {}, false]
          elsif !raw.is_a?(Hash)
            [previous || {}, true]
          elsif raw.values.all? { |v| blank?(v) }
            # ALL-BLANK => "use the shipped defaults" (mirrors the nil/empty short-circuit).
            [previous || {}, false]
          elsif enabled
            validate_or_synthesize_enabled(raw, previous)
          else
            validate_weight_set(raw, previous, required)
          end

        # AUTHORITATIVE disable: whatever candidate we settled on, if it carries coverage_gap
        # while disabled it MUST be dropped and the remaining weights renormalized to Σ==1.0
        # (case c). This runs AFTER the required-set validation so a stale 6-key incoming set
        # is still reported as an error (case d) while a previously-ENABLED fallback is
        # corrected to the valid 5-key set here.
        candidate = strip_coverage_gap_if_disabled(candidate, enabled)
        [candidate, error]
      end

      # ENABLE-path weight resolution. Order:
      #   1. A complete valid 6-key set (5 default_on + coverage_gap, Σ==1.0) => accept as-is
      #      (case b: the operator edited the 6 weights after the input appeared).
      #   2. Else, when the incoming weights are the valid 5-key default_on set (the ordinary
      #      enable POST — the form still shows 5 inputs at enable time), SYNTHESIZE: add
      #      coverage_gap's registry default weight and renormalize all 6 to Σ==1.0. Not an error.
      #   3. Else fall back to synthesizing from the previous valid 5-key set (defensive: an
      #      invalid incoming weights hash on enable still yields a valid 6-key config rather
      #      than a 5-key config the enable flag would contradict), reporting the error.
      # Returns [weights, had_error].
      def validate_or_synthesize_enabled(raw, previous)
        six = validate_weight_set(raw, previous, DEFAULT_ON_KEYS + [COVERAGE_GAP_KEY])
        return six unless six.last # complete valid 6-key set (case b)

        five, five_err = validate_weight_set(raw, previous, DEFAULT_ON_KEYS)
        return [synthesize_coverage_gap(five), false] unless five_err

        # Invalid incoming weights on enable: recover a valid 6-key config from `previous`
        # rather than a 5-key config the enable flag would contradict. Prefer an already-valid
        # 6-key previous set; else synthesize from a valid 5-key previous set; else engine
        # defaults ({}). The error is reported either way (the incoming weights were rejected).
        prev_six, prev_six_err = validate_weight_set(previous, previous,
                                                     DEFAULT_ON_KEYS + [COVERAGE_GAP_KEY])
        return [prev_six, true] unless prev_six_err

        prev_five, prev_five_err = validate_weight_set(previous, previous, DEFAULT_ON_KEYS)
        return [synthesize_coverage_gap(prev_five), true] unless prev_five_err

        [{}, true]
      end

      # Add coverage_gap at its registry default weight to a valid 5-key default_on set and
      # renormalize all 6 to Σ==1.0. Proportional: the 5 prior weights keep their pairwise
      # ratios and coverage_gap takes its default share (the inverse of the disable strip).
      def synthesize_coverage_gap(five)
        default_cg = Pulse::Domain::SignalRegistry.fetch(COVERAGE_GAP_KEY.to_sym).default_weight
        six = five.merge(COVERAGE_GAP_KEY => default_cg)
        total = six.values.sum
        six.transform_values { |w| w / total }
      end

      # Strictly validate `raw` against the `required` key set (each finite Numeric >= 0,
      # keys EXACTLY the required set, Σ == 1.0, always-active subset > 0). On any failure the
      # previous set is retained and the error flagged.
      def validate_weight_set(raw, previous, required)
        candidate = {}
        required.each do |k|
          f = strict_float(raw[k] || raw[k.to_sym])
          return [previous || {}, true] if f.nil? || f < 0.0

          candidate[k] = f
        end
        return [previous || {}, true] unless raw_keys_exact?(raw, required)
        return [previous || {}, true] if (candidate.values.sum - 1.0).abs >= 1e-9
        return [previous || {}, true] if ALWAYS_ACTIVE.sum { |k| candidate[k] } <= 0.0

        [candidate, false]
      end

      # While disabled, drop any coverage_gap weight and renormalize the remaining weights
      # to Σ==1.0 (reusing the built-in-signal proportional-renormalization rule
      # renormalize_on_toggle). A no-op when enabled or when no coverage_gap key is
      # present (the default-OFF path is byte-unchanged). A degenerate remaining-sum <= 0
      # cannot occur here (the always-active subset guarantees a positive remainder), but is
      # handled defensively by leaving the (coverage_gap-free) weights unrenormalized.
      def strip_coverage_gap_if_disabled(weights, enabled)
        return weights if enabled
        return weights unless weights.keys.map(&:to_s).include?(COVERAGE_GAP_KEY)

        renormalize_on_toggle(weights, COVERAGE_GAP_KEY)
      rescue ArgumentError
        weights.reject { |k, _| k.to_s == COVERAGE_GAP_KEY }
      end

      def raw_keys_exact?(raw, required)
        raw.keys.map(&:to_s).sort == required.sort
      end

      def strict_float(raw)
        f =
          if raw.is_a?(Numeric)
            raw.to_f
          elsif raw.nil?
            return nil
          else
            Float(raw.to_s.strip)
          end
        # A non-finite float (Infinity / -Infinity / NaN) is NEVER a valid setting: an
        # overflow string like "1e309" yields Float::INFINITY WITHOUT Float() raising, and
        # ScoringConfig would raise on read. Reject it here — the shared chokepoint — so
        # float_in_range, float_strictly_positive AND sanitize_weights are all protected.
        return nil unless f.finite?

        f
      rescue ArgumentError, TypeError
        nil
      end

      # Normalize a multi-select tracker-id list. Strip blanks, then KEEP only
      # strict positive-integer ids (drop any non-integer / non-positive element) so a
      # stray non-integer id can never be persisted verbatim. Preserves the incoming
      # string shape for valid ids (a Redmine multi-select posts string ids).
      def normalize_trackers(raw)
        Array(raw)
          .map { |v| v.to_s.strip }
          .reject(&:empty?)
          .select { |s| !integer_at_least(s, 1).nil? }
      end

      def stringify(hash)
        return {} unless hash.respond_to?(:each_pair) || hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      end
    end
  end
end
