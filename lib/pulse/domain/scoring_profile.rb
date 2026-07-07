# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit (pure scoring domain).
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/scoring_config'

module Pulse
  module Domain
    # ScoringProfile — an immutable value object binding a human-facing {id, name} to a
    # full, independently-validated ScoringConfig. A profile carries ONLY scoring shape
    # (weights + enabled set + thresholds) — never a user / project / permission reference,
    # so switching profiles can never change the visible issue set (structurally: the
    # profile is not even a visibility input).
    #
    # Immutability: id and name are stored as
    # dup.freeze'd copies, so mutating the caller's ORIGINAL String never reaches the VO;
    # the whole object is frozen at construction. Invalid id/name/config => ArgumentError
    # (no partial build). Two profiles MAY carry different enabled sets (one enables
    # coverage_gap, another does not) — the config is the sole authority for the enabled set.
    #
    # Pure domain: stdlib only (no persistence / framework / adapter reference).
    class ScoringProfile
      attr_reader :id, :name, :config

      def initialize(id:, name:, config:)
        @id = validate_string!(:id, id)
        @name = validate_string!(:name, name)
        @config = validate_config!(config)

        freeze
      end

      private

      # A non-empty String, stored as a dup.freeze'd copy so the caller's original String
      # is decoupled from the VO field (deep immutability).
      def validate_string!(field, value)
        unless value.is_a?(String)
          raise ArgumentError, "#{field} must be a String (got #{value.class})"
        end
        if value.strip.empty?
          raise ArgumentError, "#{field} must be a non-empty String"
        end

        value.dup.freeze
      end

      # The config must be a ScoringConfig (already self-validated at its own construction —
      # weights sum, registered keys, etc. cannot be bypassed by the profile). A non-config
      # value fails loud as ArgumentError (never a leaked TypeError/NoMethodError downstream).
      def validate_config!(config)
        unless config.is_a?(Pulse::Domain::ScoringConfig)
          raise ArgumentError,
                "config must be a Pulse::Domain::ScoringConfig (got #{config.class})"
        end

        config
      end
    end
  end
end
