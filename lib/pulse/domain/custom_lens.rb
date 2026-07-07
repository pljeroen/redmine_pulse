# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/weight_set'

module Pulse
  module Domain
    # CustomLens — a frozen value object describing one ranking lens:
    #   name           — a non-empty String (blank/whitespace/nil/non-String => ArgumentError);
    #                     stored as name.dup.freeze so post-construction mutation of the
    #                     caller-owned String cannot change lens.name
    #   weight_set     — a WeightSet instance (a raw Hash or nil => ArgumentError)
    #   sort_direction — :asc or :desc (anything else => ArgumentError)
    #   threshold      — nil OR a finite real Numeric (Integer | Rational | non-NaN/Inf
    #                    Float); NaN/Infinity/Complex/String/etc => ArgumentError, type-
    #                    checked BEFORE any comparison (same guard as WeightSet)
    # Declarative fields only — no formula/expression surface. Frozen at construction;
    # mutation raises FrozenError.
    class CustomLens
      SORT_DIRECTIONS = %i[asc desc].freeze

      attr_reader :name, :weight_set, :sort_direction, :threshold

      def initialize(name:, weight_set:, sort_direction:, threshold:)
        unless name.is_a?(String) && !name.strip.empty?
          raise ArgumentError, "name must be a non-empty String (got #{name.inspect})"
        end
        unless weight_set.is_a?(WeightSet)
          raise ArgumentError, "weight_set must be a WeightSet (got #{weight_set.class})"
        end
        unless SORT_DIRECTIONS.include?(sort_direction)
          raise ArgumentError,
                "sort_direction must be one of #{SORT_DIRECTIONS.inspect} (got #{sort_direction.inspect})"
        end
        unless threshold.nil?
          finite_real_numeric!(:threshold, threshold)
        end

        # dup.freeze AFTER validation so the caller can't mutate the stored name via the
        # original String reference (the frozen value-object immutability guarantee).
        @name = name.dup.freeze
        @weight_set = weight_set
        @sort_direction = sort_direction
        @threshold = threshold

        freeze
      end

      private

      # A threshold must be a finite, real, ordered Numeric — an Integer, a Rational, or a
      # Float that is neither NaN nor Infinite. Type/finiteness are checked BEFORE any
      # comparison so String/Complex/NaN/Inf fail loud as ArgumentError rather than leaking
      # a TypeError/NoMethodError downstream (same guard shape as WeightSet/ScoringConfig).
      def finite_real_numeric!(name, value)
        unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)
          raise ArgumentError,
                "#{name} must be a finite real Numeric or nil (got #{value.class})"
        end
        if value.is_a?(Float) && !value.finite?
          raise ArgumentError, "#{name} must be finite (got #{value})"
        end
      end
    end
  end
end
