# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Domain
    # Immutable scoring configuration value object. Weights, RAG thresholds, signal
    # horizons and the activity window. Fails loud (ArgumentError) on invalid weights.
    class ScoringConfig
      DEFAULT_WEIGHTS = {
        staleness: 0.25,
        progress: 0.25,
        momentum: 0.20,
        risk_load: 0.15,
        blocked_load: 0.15
      }.freeze

      # The always-active subset whose weight-sum must be > 0 (RC-07 / FR-39b):
      # without it a fully-degraded project could have an empty active set.
      ALWAYS_ACTIVE_KEYS = %i[staleness momentum blocked_load].freeze

      # FR-39: weights must contain EXACTLY these five signal keys, each Numeric.
      REQUIRED_WEIGHT_KEYS = %i[staleness progress momentum risk_load blocked_load].freeze

      # momentum-broaden / on-track shape defaults, now promoted to settings. These
      # are the single source of truth for the shipped values (8.0 / 0.15 / 0.5);
      # the adapters and init.rb defaults mirror them.
      DEFAULT_MOMENTUM_ACTIVITY_HALF = 8.0
      DEFAULT_MOMENTUM_DIRECTION_BIAS = 0.15
      DEFAULT_ON_TRACK_THRESHOLD = 0.5

      attr_reader :weights, :rag_green_min, :rag_amber_min,
                  :h_stale, :h_risk, :h_blocked, :activity_window_days,
                  :momentum_activity_half, :momentum_direction_bias, :on_track_threshold

      def initialize(weights: nil, rag_green_min: 67, rag_amber_min: 34,
                     h_stale: 180, h_risk: 50, h_blocked: 20, activity_window_days: 30,
                     momentum_activity_half: DEFAULT_MOMENTUM_ACTIVITY_HALF,
                     momentum_direction_bias: DEFAULT_MOMENTUM_DIRECTION_BIAS,
                     on_track_threshold: DEFAULT_ON_TRACK_THRESHOLD)
        weights = weights.nil? ? DEFAULT_WEIGHTS : weights
        validate_weights!(weights)
        validate_non_weight_fields!(rag_green_min, rag_amber_min,
                                    h_stale, h_risk, h_blocked, activity_window_days)
        validate_momentum_onctrack_fields!(momentum_activity_half,
                                           momentum_direction_bias, on_track_threshold)

        @weights = weights.dup.freeze
        @rag_green_min = rag_green_min
        @rag_amber_min = rag_amber_min
        @h_stale = h_stale
        @h_risk = h_risk
        @h_blocked = h_blocked
        @activity_window_days = activity_window_days
        @momentum_activity_half = momentum_activity_half
        @momentum_direction_bias = momentum_direction_bias
        @on_track_threshold = on_track_threshold

        freeze
      end

      private

      def validate_weight_keys!(weights)
        unless weights.is_a?(Hash)
          raise ArgumentError, "weights must be a Hash (got #{weights.class})"
        end

        actual = weights.keys.sort
        expected = REQUIRED_WEIGHT_KEYS.sort
        unless actual == expected
          raise ArgumentError,
                "weights must contain exactly #{REQUIRED_WEIGHT_KEYS.inspect} (got #{weights.keys.inspect})"
        end

        REQUIRED_WEIGHT_KEYS.each do |key|
          finite_real_numeric!(key, weights[key])
        end
      end

      # Central guard: a weight must be a finite, real, ordered Numeric — an
      # Integer, a Rational, or a Float that is neither NaN nor Infinite. This is
      # checked BEFORE the sum/non-negative/RC-07 checks so a NaN (which makes the
      # sum NaN and slips past the tolerance test) and a Complex (unordered, which
      # would leak NoMethodError at `< 0.0`) both fail loud with ArgumentError.
      def finite_real_numeric!(key, value)
        unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)
          raise ArgumentError,
                "weight #{key} must be a finite real Numeric (got #{value.class})"
        end
        if value.is_a?(Float) && !value.finite?
          raise ArgumentError, "weight #{key} must be finite (got #{value})"
        end
      end

      # FR-02: every non-weight field is a plain Integer. Type is checked BEFORE any
      # numeric comparison so a String/nil/Float never reaches `<`/`>=` and leaks a
      # TypeError/ArgumentError-from-coercion instead of the required fail-loud message.
      def integer_field!(name, value)
        return if value.is_a?(Integer)

        raise ArgumentError, "#{name} must be an Integer (got #{value.class})"
      end

      # FR-02/FR-06/FR-11/FR-22: validate the six non-weight config fields. All must be
      # Integer; horizons (denominators in n = 1 - x/H) and the activity window must be
      # >= 1; the RAG bounds must lie in [0,100] with rag_amber_min <= rag_green_min for
      # coherent bands. Fails loud (ArgumentError) at the value-object boundary.
      def validate_non_weight_fields!(rag_green_min, rag_amber_min,
                                      h_stale, h_risk, h_blocked, activity_window_days)
        integer_field!(:rag_green_min, rag_green_min)
        integer_field!(:rag_amber_min, rag_amber_min)
        integer_field!(:h_stale, h_stale)
        integer_field!(:h_risk, h_risk)
        integer_field!(:h_blocked, h_blocked)
        integer_field!(:activity_window_days, activity_window_days)

        # FR-06: horizons are denominators => must be >= 1 (positive).
        { h_stale: h_stale, h_risk: h_risk, h_blocked: h_blocked }.each do |name, value|
          raise ArgumentError, "#{name} must be >= 1 (got #{value})" if value < 1
        end

        # FR-11: activity window size must be >= 1.
        if activity_window_days < 1
          raise ArgumentError, "activity_window_days must be >= 1 (got #{activity_window_days})"
        end

        # FR-22: RAG band bounds must be within [0,100].
        { rag_green_min: rag_green_min, rag_amber_min: rag_amber_min }.each do |name, value|
          unless value.between?(0, 100)
            raise ArgumentError, "#{name} must be within [0,100] (got #{value})"
          end
        end

        # FR-22: coherent bands require rag_amber_min <= rag_green_min.
        if rag_amber_min > rag_green_min
          raise ArgumentError,
                "rag_amber_min must be <= rag_green_min for coherent bands " \
                "(got amber=#{rag_amber_min}, green=#{rag_green_min})"
        end
      end

      # A float-shaped config field: accept a finite real Numeric (Integer or Float;
      # Integer input like 8 is valid for a float field). Type/finiteness checked
      # BEFORE any range comparison so a String/nil/NaN/Infinity never reaches `<`/`>`
      # and leaks a TypeError instead of the required fail-loud ArgumentError.
      def finite_real_field!(name, value)
        unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)
          raise ArgumentError, "#{name} must be a finite real Numeric (got #{value.class})"
        end
        if value.is_a?(Float) && !value.finite?
          raise ArgumentError, "#{name} must be finite (got #{value})"
        end
      end

      # Validate the 3 momentum / on-track shape fields (promoted from domain constants).
      # momentum_activity_half: strictly positive (> 0); momentum_direction_bias: [0.0,0.5]
      # inclusive; on_track_threshold: [0.0,1.0] inclusive. Fails loud (ArgumentError)
      # naming the field, matching the existing guard style.
      def validate_momentum_onctrack_fields!(momentum_activity_half,
                                             momentum_direction_bias, on_track_threshold)
        finite_real_field!(:momentum_activity_half, momentum_activity_half)
        finite_real_field!(:momentum_direction_bias, momentum_direction_bias)
        finite_real_field!(:on_track_threshold, on_track_threshold)

        if momentum_activity_half <= 0
          raise ArgumentError, "momentum_activity_half must be > 0 (got #{momentum_activity_half})"
        end
        unless momentum_direction_bias.between?(0.0, 0.5)
          raise ArgumentError,
                "momentum_direction_bias must be within [0.0,0.5] (got #{momentum_direction_bias})"
        end
        unless on_track_threshold.between?(0.0, 1.0)
          raise ArgumentError,
                "on_track_threshold must be within [0.0,1.0] (got #{on_track_threshold})"
        end
      end

      def validate_weights!(weights)
        # FR-39: exactly the five signal keys, each Numeric — checked BEFORE summing
        # so a missing/extra/nil/non-numeric weight fails loud with ArgumentError
        # rather than leaking a TypeError downstream in Scoring.score.
        validate_weight_keys!(weights)

        # FR-39a: weight-sum must be 1.0 within 1e-9.
        if (weights.values.sum - 1.0).abs >= 1e-9
          raise ArgumentError, "weights must sum to 1.0 (got #{weights.values.sum})"
        end
        # FR-39a: no negative weights.
        if weights.values.any? { |w| w < 0.0 }
          raise ArgumentError, 'weights must all be >= 0.0'
        end
        # FR-39b / RC-07: always-active subset weight-sum must be > 0.
        subset = ALWAYS_ACTIVE_KEYS.sum { |k| weights[k] || 0.0 }
        if subset <= 0.0
          raise ArgumentError, 'always-active subset {staleness,momentum,blocked_load} weight-sum must be > 0 (RC-07)'
        end
      end
    end
  end
end
