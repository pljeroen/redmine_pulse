# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'digest'
require 'pulse/domain/signal_registry'
require 'pulse/adapters/settings_sanitizer'

module Pulse
  module Adapters
    # SettingsProvider implementation: maps the plugin Settings into the pure-domain
    # ScoringConfig (DEC-13 defaults when absent) and exposes the enrichment-mapping
    # state. Validates the configured effort field is numeric-format AT READ TIME
    # (FC-11 / MS-10) so a non-numeric mapping degrades gracefully (effort unmapped)
    # rather than summing garbage. Read-only: never writes Redmine domain tables.
    class RedmineSettingsProvider
      PLUGIN_KEY = 'redmine_pulse'

      # Custom-field formats that yield a summable numeric value (FC-11/FC-13).
      NUMERIC_FORMATS = %w[int float].freeze

      def initialize; end

      # -> Pulse::Domain::ScoringConfig (defaults when a value is absent/blank).
      #
      # A10-C2-001 (b): enable_coverage_gap is AUTHORITATIVE for the enabled signal set.
      # weights_from resolves the persisted weights and then reconciles the coverage_gap key
      # against the flag — coverage_gap present iff enabled — so the ScoringConfig enabled set
      # (== dom(weights)) always tracks the flag, never the (possibly drifted) weight-hash keys.
      def scoring_config
        s = settings
        Pulse::Domain::ScoringConfig.new(
          weights: weights_from(s),
          rag_green_min: int_setting(s, 'rag_green_min', 67),
          rag_amber_min: int_setting(s, 'rag_amber_min', 34),
          h_stale: int_setting(s, 'h_stale', 180),
          h_risk: int_setting(s, 'h_risk', 50),
          h_blocked: int_setting(s, 'h_blocked', 20),
          activity_window_days: int_setting(s, 'activity_window_days', 30),
          momentum_activity_half: float_setting(s, 'momentum_activity_half', 8.0),
          momentum_direction_bias: float_setting(s, 'momentum_direction_bias', 0.15),
          on_track_threshold: float_setting(s, 'on_track_threshold', 0.5)
        )
      end

      # -> String, deterministic over the full settings hash; any change moves it.
      def settings_version_hash
        Digest::SHA256.hexdigest(canonical(settings))
      end

      # -> Boolean: true iff an effort field is configured AND numeric-format.
      def effort_mapped?
        id = effort_custom_field_id
        return false if id.nil?

        field = IssueCustomField.find_by(id: id)
        return false if field.nil?

        NUMERIC_FORMATS.include?(field.field_format)
      end

      # -> Integer | nil (the configured effort custom-field id, blank => nil).
      def effort_custom_field_id
        raw = settings['effort_field']
        return nil if raw.nil? || raw.to_s.strip.empty?

        raw.to_i
      end

      # -> Boolean: true iff at least one risk tracker is mapped.
      def risk_mapped?
        risk_tracker_ids.any?
      end

      # -> Array<Integer> (configured risk-tracker ids; empty when unmapped).
      def risk_tracker_ids
        raw = settings['risk_trackers']
        Array(raw).map { |v| v.to_s.strip }.reject(&:empty?).map(&:to_i)
      end

      # -> Integer (CT-02 snapshot freshness cap in minutes; blank/absent => default 60,
      # 0 = disabled). OPERATIONAL cache knob — deliberately NOT a ScoringConfig field
      # (scoring stays scoring-only); the projection engine reads it directly.
      def snapshot_max_age_minutes
        int_setting(settings, 'snapshot_max_age_minutes', 60)
      end

      # -> Integer | nil (the configured blocked-status id, blank => nil).
      def blocked_status_id
        raw = settings['blocked_status']
        return nil if raw.nil? || raw.to_s.strip.empty?

        raw.to_i
      end

      # A10-C2-001 (b) — the enable_coverage_gap flag is AUTHORITATIVE for the enabled set.
      # -> Boolean: true iff the optional coverage_gap signal is enabled in settings.
      def coverage_gap_enabled?
        SettingsSanitizer.truthy?(settings['enable_coverage_gap'])
      end

      # C4 (FR-C4-02/04) — the admin-defined scoring profiles + role bindings, in the shape
      # RedmineProfileProvider consumes: { 'profiles' => {id => {name, weights, ...}},
      # 'role_bindings' => {role_id => profile_id} }. Absent => an empty pair (the synthetic
      # default needs no entry). Read-only passthrough of the sanitizer-validated sub-hash.
      def pulse_profiles
        raw = settings['pulse_profiles']
        return { 'profiles' => {}, 'role_bindings' => {} } unless raw.is_a?(Hash)

        {
          'profiles' => raw['profiles'] || raw[:profiles] || {},
          'role_bindings' => raw['role_bindings'] || raw[:role_bindings] || {}
        }
      end

      private

      def settings
        s = Setting.send("plugin_#{PLUGIN_KEY}")
        s.is_a?(Hash) ? s : {}
      end

      def int_setting(s, key, default)
        raw = s[key]
        return default if raw.nil? || raw.to_s.strip.empty?

        raw.to_i
      end

      def float_setting(s, key, default)
        raw = s[key]
        return default if raw.nil? || raw.to_s.strip.empty?

        Float(raw)
      rescue ArgumentError, TypeError
        default
      end

      # Honour explicit weight overrides only when they form a complete, valid set;
      # otherwise fall through to the domain ScoringConfig defaults (nil => defaults).
      #
      # A10-C2-001 (b): after resolving the persisted weights, RECONCILE the coverage_gap key
      # against the AUTHORITATIVE enable flag so the enabled set (dom of weights) tracks the
      # flag, not the raw weight-hash keys:
      #   * enabled + coverage_gap already present  => keep the persisted 6-key map as-is.
      #   * enabled + coverage_gap absent           => synthesize it (add the registry default
      #     weight + renormalize all 6 to Σ==1.0) so a persisted flag ALWAYS yields a 6-signal
      #     enabled set, even if the weights hash drifted to 5 keys.
      #   * disabled + coverage_gap present          => strip it + renormalize the 5 to Σ==1.0.
      #   * disabled + coverage_gap absent (default) => byte-unchanged (nil => engine defaults).
      def weights_from(s)
        raw = s['weights']
        base =
          if raw.is_a?(Hash) && raw.any?
            raw.each_with_object({}) do |(k, v), acc|
              acc[k.to_sym] = v.is_a?(String) ? Float(v) : v
            end
          end
        reconcile_coverage_gap(base, coverage_gap_enabled?)
      rescue ArgumentError, TypeError
        nil
      end

      # Reconcile the coverage_gap weight against the authoritative enable flag (see
      # weights_from). `base` is the symbol-keyed persisted weights (or nil => defaults).
      def reconcile_coverage_gap(base, enabled)
        cg = :coverage_gap
        if enabled
          # A persisted enable flag ALWAYS ships a 6-key weights map (SettingsSanitizer), so
          # `base` is normally the 6-key hash. Defensive: when base is nil/empty (weights hash
          # drifted / absent), synthesize from the 5 default weights so the flag still yields a
          # 6-signal enabled set.
          base = Pulse::Domain::SignalRegistry.default_weights.dup if base.nil? || base.empty?
          return base if base.key?(cg)

          default_cg = Pulse::Domain::SignalRegistry.fetch(cg).default_weight
          six = base.merge(cg => default_cg)
          total = six.values.sum
          six.transform_values { |w| w / total }
        else
          return base if base.nil? || !base.key?(cg)

          remaining = base.reject { |k, _| k == cg }
          total = remaining.values.sum
          return base if total <= 0.0

          remaining.transform_values { |w| w / total }
        end
      end

      # Deterministic, order-independent canonical serialization for hashing.
      def canonical(value)
        case value
        when Hash
          inner = value.keys.map(&:to_s).sort.map do |k|
            orig_key = value.key?(k) ? k : value.keys.find { |kk| kk.to_s == k }
            "#{k}=#{canonical(value[orig_key])}"
          end
          "{#{inner.join(',')}}"
        when Array
          "[#{value.map { |e| canonical(e) }.join(',')}]"
        else
          value.to_s
        end
      end
    end
  end
end
