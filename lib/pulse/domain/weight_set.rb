# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/signal_registry'

module Pulse
  module Domain
    # WeightSet — a frozen value object mapping registered-signal-key => weight over a
    # SUBSET of the registered signals. NOT a probability simplex:
    # there is NO sum==1.0 requirement (that constraint lives in ScoringConfig, layered on
    # top). Validation, in order: keys must be registered (else ArgumentError); the map must
    # be non-empty; each weight must be a finite real Numeric (Integer | Rational | non-
    # NaN/Inf Float) — type/finiteness checked BEFORE any comparison so a String/Complex/nil
    # fails loud as ArgumentError, never leaking a TypeError/NoMethodError at `< 0` — and
    # >= 0; at least one weight must be > 0. Frozen at construction (the internal Hash is
    # deep-frozen). #to_h returns a plain frozen Hash preserving input insertion order.
    # The formal read surface is #[](key) (weight or nil), #keys (frozen,
    # ordered) and #values (frozen, ordered) — all delegating to the frozen internal Hash,
    # non-mutating. #== is Hash-aware and order-independent (WeightSet == Hash and WeightSet
    # == WeightSet both compare by content) for downstream reuse.
    class WeightSet
      def initialize(weights)
        validate!(weights)
        @weights = weights.dup.freeze
        freeze
      end

      # A plain FROZEN Hash of {signal_key => weight}, in input insertion order.
      def to_h
        @weights
      end

      # Formal read surface: ws[key], ws.keys, ws.values — all delegating to
      # the frozen internal Hash, insertion-order-preserving, non-mutating.

      # The weight for +key+, or nil if the key is absent. Delegates to the frozen Hash.
      def [](key)
        @weights[key]
      end

      # A FROZEN Array of the signal keys, in input insertion order. Frozen so the caller
      # cannot mutate a collection that shares state with the internal Hash's key set.
      def keys
        @weights.keys.freeze
      end

      # A FROZEN Array of the weights, in input insertion order (aligned with #keys).
      def values
        @weights.values.freeze
      end

      # Value-based, order-independent equality. Compares against another WeightSet by
      # content and against a plain Hash by content (Hash#== is order-independent).
      def ==(other)
        case other
        when WeightSet then @weights == other.to_h
        when Hash      then @weights == other
        else false
        end
      end

      alias eql? ==

      def hash
        @weights.hash
      end

      private

      def validate!(weights)
        unless weights.is_a?(Hash)
          raise ArgumentError, "weights must be a Hash (got #{weights.class})"
        end
        if weights.empty?
          raise ArgumentError, 'weights must be a non-empty subset of the registered signals'
        end

        weights.each_key do |key|
          unless SignalRegistry.registered?(key)
            raise ArgumentError,
                  "weight key #{key.inspect} is not a registered signal " \
                  "(registered: #{SignalRegistry.keys.inspect})"
          end
        end

        # Type/finiteness BEFORE any compare so String/Complex/nil/NaN/Inf fail loud.
        weights.each { |key, value| finite_real_numeric!(key, value) }

        if weights.values.any? { |w| w < 0 }
          raise ArgumentError, 'weights must all be >= 0'
        end
        unless weights.values.any? { |w| w > 0 }
          raise ArgumentError, 'at least one weight must be > 0'
        end
      end

      def finite_real_numeric!(key, value)
        unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)
          raise ArgumentError,
                "weight #{key} must be a finite real Numeric (got #{value.class})"
        end
        if value.is_a?(Float) && !value.finite?
          raise ArgumentError, "weight #{key} must be finite (got #{value})"
        end
      end
    end
  end
end
