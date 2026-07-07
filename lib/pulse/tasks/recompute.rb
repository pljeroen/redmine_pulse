# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Tasks
    # Recompute — the composition root for `rake redmine_pulse:recompute`. It WARMS the
    # pulse_snapshots cache for all (or a subset of) projects under the canonical/global
    # ('default') profile, REUSING the existing PulseProjection::Engine warm path +
    # fingerprint/max-age mechanics — so a FRESH row (within max-age) is NOT recomputed
    # (idempotent). It writes ONLY pulse_snapshots (pre-existing cache table); it NEVER
    # touches pulse_alert_states and emits NO notifications. Additive: never invoking it
    # leaves the synchronous request cycle byte-identical.
    #
    # It scores under the CANONICAL profile by injecting NO profile_provider into the Engine
    # (the default-config behavior — the exact canonical/global scoring the request
    # cycle uses when no per-viewer profile is resolved), and reads under a privileged
    # canonical viewer so every pulse-enabled project is warmed regardless of membership.
    module Recompute
      module_function

      # run(project_ids: nil) -> Integer (count of projects warmed). A nil project_ids
      # warms the full pulse-enabled portfolio; an explicit list scopes it.
      def run(project_ids: nil)
        viewer = Pulse::Tasks::CanonicalScan.canonical_viewer
        engine = Pulse::Tasks::CanonicalScan.canonical_engine
        ids = Pulse::Tasks::CanonicalScan.target_project_ids(project_ids)

        count = 0
        ids.each do |pid|
          project = Project.find_by(id: pid)
          next if project.nil?

          # Reuse the EXISTING per-project projection (warm-on-miss / refresh-on-stale).
          # This is the same cache mechanics the request cycle uses — idempotent within
          # max-age (a fresh row is served, not recomputed).
          engine.project_projection(viewer, project, nil)
          count += 1
        end
        count
      end
    end
  end
end
