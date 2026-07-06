# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/scoring_config'

module Pulse
  module Domain
    # LensRanking — a pure, side-effect-free module computing one lens's ranking score
    # (FC-C3-07..FC-C3-10). The score is the normalized weighted mean
    #   Σ_{k∈INCLUDED}(wₖ · nₖ) / Σ_{k∈INCLUDED}(wₖ)
    # over the lens's chosen signals (keys of its WeightSet) that are BOTH
    #   * enabled  — k ∈ config.enabled_signals, AND
    #   * active   — the SignalResult for k in health_result.breakdown is active with a
    #                non-nil normalized score n.
    # A chosen signal that is disabled OR inactive is EXCLUDED from BOTH the numerator and
    # the denominator. When the included-weight sum is 0 (all chosen signals excluded, or
    # all included weights zero) the score is nil — unrankable — never NaN and never raised.
    # Inputs are only read, never mutated.
    module LensRanking
      module_function

      def score(lens, health_result, config)
        enabled = config.enabled_signals
        by_key = health_result.breakdown.each_with_object({}) do |sr, acc|
          acc[sr.key] = sr
        end

        numerator = 0.0
        denominator = 0.0

        lens.weight_set.to_h.each do |key, weight|
          next unless enabled.include?(key)

          sr = by_key[key]
          next if sr.nil? || !sr.active || sr.n.nil?

          numerator += weight * sr.n
          denominator += weight
        end

        return nil if denominator.zero?

        numerator / denominator
      end
    end
  end
end
