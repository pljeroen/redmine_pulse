# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # MainConcernLabels — the SINGLE authoritative dominant_signal -> localized "main
    # concern" label mapping (FR-PLB-15 / D-PLB-C01 / DG-PLB-02). Both HtmlPresenter (the
    # cockpit) and JsonSerializer (the portfolio.json / project.json API + the inline
    # badge blob) delegate here, so the cockpit and the API can never drift in their
    # vocabulary (DRY single source of truth).
    #
    # It STAYS in lib/pulse/adapters/ — it depends on Rails I18n, so it MUST NOT be placed
    # in or imported by the pure lib/pulse/domain/ layer (domain purity, enforced by
    # test_domain_does_not_import_shared_label_module).
    #
    # The mapping (en.yml-confirmed):
    #   staleness    -> :label_pulse_lens_stale       -> "Stale"
    #   momentum     -> :label_pulse_concern_momentum -> "Losing momentum"
    #   progress     -> :label_pulse_concern_progress -> "Behind schedule"
    #   risk_load    -> :label_pulse_lens_at_risk     -> "At risk"
    #   blocked_load -> :label_pulse_lens_blocked     -> "Blocked"
    #   nil          -> nil (no-data path; mirrors dominant_signal nullability)
    module MainConcernLabels
      # The authoritative severity-first dominant_signal -> I18n-key mapping.
      KEYS = {
        staleness: :label_pulse_lens_stale,
        momentum: :label_pulse_concern_momentum,
        progress: :label_pulse_concern_progress,
        risk_load: :label_pulse_lens_at_risk,
        blocked_load: :label_pulse_lens_blocked,
        # momentum-broaden D2: worst active signal healthy (n >= 0.5) => "On track".
        on_track: :label_pulse_on_track
      }.freeze

      module_function

      # Map a dominant_signal (Symbol or String, or nil) to its already-localized label.
      # nil/blank -> nil (the no-data path; serialized as JSON null). An unknown signal
      # falls back to its own string form (never raises) — keeps the renderer resilient.
      def label(dominant_signal)
        return nil if dominant_signal.nil?

        signal = dominant_signal.to_s
        return nil if signal.empty?

        key = KEYS[signal.to_sym]
        key ? I18n.t(key) : signal
      end
    end
  end
end
