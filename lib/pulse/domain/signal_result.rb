# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

module Pulse
  module Domain
    # Immutable per-signal result. Nil-consistency invariant (FC-32): when active,
    # ALL numeric fields are non-nil; when inactive, ALL numeric fields are nil.
    class SignalResult
      attr_reader :key, :active, :raw_value, :n, :effective_weight, :contribution

      NUMERIC_FIELDS = %i[raw_value n effective_weight contribution].freeze

      def initialize(key:, active:, raw_value:, n:, effective_weight:, contribution:)
        numerics = [raw_value, n, effective_weight, contribution]
        if active && numerics.any?(&:nil?)
          raise ArgumentError, 'active SignalResult must have all numeric fields non-nil (FC-32)'
        end
        if !active && numerics.any? { |v| !v.nil? }
          raise ArgumentError, 'inactive SignalResult must have all numeric fields nil (FC-32)'
        end

        @key = key
        @active = active
        @raw_value = raw_value
        @n = n
        @effective_weight = effective_weight
        @contribution = contribution

        freeze
      end
    end
  end
end
