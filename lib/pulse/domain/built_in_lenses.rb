# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/weight_set'
require 'pulse/domain/custom_lens'

module Pulse
  module Domain
    # BuiltInLenses — the v1 seed catalog of ranking lenses.
    # EXACTLY 2 frozen CustomLens entries, IN ORDER:
    #   [0] "Delivery risk": {risk_load: 0.5, blocked_load: 0.3, staleness: 0.2}, :asc, nil
    #   [1] "Momentum":      {momentum: 0.6, progress: 0.4},                       :asc, nil
    # Only weighted-signal-score lenses — NO raw-metric (stale/done/blocked) pass-throughs.
    # Every entry is LensRanking-computable by the same machinery a user-defined saved lens uses.
    module BuiltInLenses
      ALL = [
        CustomLens.new(
          name: 'Delivery risk',
          weight_set: WeightSet.new(risk_load: 0.5, blocked_load: 0.3, staleness: 0.2),
          sort_direction: :asc,
          threshold: nil
        ),
        CustomLens.new(
          name: 'Momentum',
          weight_set: WeightSet.new(momentum: 0.6, progress: 0.4),
          sort_direction: :asc,
          threshold: nil
        )
      ].freeze

      module_function

      # The frozen v1 catalog Array of frozen CustomLens entries, in canonical order.
      def all
        ALL
      end
    end
  end
end
