# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/signal_registry'

module Pulse
  module Adapters
    # SettingsSanitizer — validates an incoming plugin-settings hash to the EXACT
    # ScoringConfig bounds (DG-07 / COND-CA-03 / FC-CA-30) and REJECTS invalid scalar
    # values by keeping the previously-persisted value for that key (the invalid input
    # is never persisted). It is pure Ruby (no Rails/AR) so it is unit-testable and so
    # the admin POST path can sanitize before `Setting.plugin_redmine_pulse=` persists.
    #
    # Bounds enforced (read off the as-built ScoringConfig contract):
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
      # FC-C2-14: the required weight-key set is a RUNTIME value derived from the incoming
      # enable_coverage_gap flag combined with SignalRegistry.default_on_keys — NOT the static
      # SignalRegistry.keys (which now includes the registered-but-default_on:false
      # coverage_gap). The DEFAULT-ON keys are the 5 C1 built-ins; enabling coverage_gap adds
      # its key to the required set. See weight_keys_for.
      DEFAULT_ON_KEYS = Pulse::Domain::SignalRegistry.default_on_keys.map(&:to_s).freeze
      COVERAGE_GAP_KEY = 'coverage_gap'
      # Retained for readers that referenced the C1 constant name; equals the default-on set
      # (the disabled/default required weight-key set).
      WEIGHT_KEYS = DEFAULT_ON_KEYS
      ALWAYS_ACTIVE = Pulse::Domain::SignalRegistry.always_active_keys.map(&:to_s).freeze

      module_function

      # IT-C1-05 / FR-C1-09 — adapter-layer proportional renormalization on a signal
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

        # CT-02 snapshot_max_age_minutes: OPERATIONAL cache freshness cap. Integer >= 0
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

        # RT-07 (security-S3-defense): VALIDATE admin-set enrichment ids at save time —
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

        # FC-C2-14: enable_coverage_gap is AUTHORITATIVE for the weight-key set. When truthy the
        # required set is the 6 keys {5 default_on + coverage_gap}; when falsy it is the 5
        # default_on keys and coverage_gap is NEVER persisted (stripped on every path, incl. the
        # invalid-weight fallback). The flag itself is persisted as a scalar settings key so the
        # settings_version_hash moves on toggle (FC-C2-11); a falsy/blank incoming flag removes it.
        enabled = truthy?(incoming['enable_coverage_gap'])
        if enabled
          result['enable_coverage_gap'] = '1'
        else
          result.delete('enable_coverage_gap')
        end

        weights, weight_err = sanitize_weights(incoming['weights'], previous['weights'], enabled)
        result['weights'] = weights
        errors << 'weights' if weight_err

        [result, errors]
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

      # FC-C2-14: the required weight-key set is DERIVED from the enable flag — the 5
      # default_on keys when disabled, or those 5 + coverage_gap when enabled. It is NEVER the
      # static SignalRegistry.keys.
      def weight_keys_for(enabled)
        enabled ? (DEFAULT_ON_KEYS + [COVERAGE_GAP_KEY]) : DEFAULT_ON_KEYS
      end

      # weights: keep ONLY when the candidate forms a complete valid set for the enabled
      # required key set; else fall back to previous (or {} => engine defaults). Returns
      # [weights, had_error].
      #
      # FC-C2-14 INVARIANT: while DISABLED (enabled == false), coverage_gap MUST NEVER appear
      # in the returned weights — on EVERY path, including the invalid-weight fallback. The
      # enable flag is AUTHORITATIVE: a falsy flag over a previously-ENABLED (6-key) config
      # strips coverage_gap and renormalizes the remaining 5 to Σ==1.0 (case c), regardless of
      # what the incoming or previous weights still carry.
      #
      # A10-C2-001 (enable symmetry): the settings form ships only the 5 weight inputs while
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

      # A10-C2-001 (a) — ENABLE-path weight resolution. Order:
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

      # FC-C2-14 (c): while disabled, drop any coverage_gap weight and renormalize the
      # remaining weights to Σ==1.0 (reusing the C1 proportional-renormalization rule
      # renormalize_on_toggle / FC-C1-16). A no-op when enabled or when no coverage_gap key is
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

      # RT-07: normalize a multi-select tracker-id list. Strip blanks, then KEEP only
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
