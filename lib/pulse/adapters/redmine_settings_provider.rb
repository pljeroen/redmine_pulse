# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'digest'

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
      def weights_from(s)
        raw = s['weights']
        return nil unless raw.is_a?(Hash) && raw.any?

        symbolized = raw.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v.is_a?(String) ? Float(v) : v
        end
        symbolized
      rescue ArgumentError, TypeError
        nil
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
