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
    # Immutable composite health result for one project. Carries NO Date / computed_at
    # field (FC-31/OSD-08): the "as-of" day is consumed during scoring, not stored.
    class HealthResult
      attr_reader :project_id, :health_score, :rag, :dominant_signal,
                  :signal_completeness, :breakdown, :lens_keys, :effort_open

      def initialize(project_id:, health_score:, rag:, dominant_signal:,
                     signal_completeness:, breakdown:, lens_keys:, effort_open:)
        @project_id = project_id
        @health_score = health_score
        @rag = rag
        @dominant_signal = dominant_signal
        @signal_completeness = signal_completeness
        @breakdown = breakdown.freeze
        @lens_keys = lens_keys.freeze
        @effort_open = effort_open

        freeze
      end
    end
  end
end
