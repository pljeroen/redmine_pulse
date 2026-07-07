# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # ProfileProvider — the DUCK-TYPED port (structural typing;
    # standard library only; no ABC / inheritance) for resolving which ScoringProfile is active
    # for a viewer. It mirrors the as-built MetricsSource / Clock / SnapshotStore documentation
    # modules: a plain Module carrying only the protocol narrative, not an enforced base class.
    #
    # An implementation MUST respond to:
    #
    #   #profiles
    #     -> Array<Pulse::Domain::ScoringProfile>, the published set. It ALWAYS includes the
    #        synthetic system default (id "default", config == the current global ScoringConfig).
    #
    #   #resolve(viewer, project, requested_id = nil)
    #     -> Pulse::Domain::ScoringProfile, resolved by precedence:
    #          1. an explicit, transient requested_id (viewer selection) if it names a
    #             published profile;
    #          2. else the viewer's role-default binding (multi-role tie-break: FIRST match by
    #             role.id ASCENDING);
    #          3. else the system default.
    #        A requested/bound id that is NOT in the published set degrades to the system
    #        default AND surfaces a non-empty warning via #last_warning — never raises.
    #
    #   #last_warning
    #     -> String | nil, the human-readable warning from the LAST #resolve call (nil on a
    #        clean resolution; set when a dangling reference degraded to the default).
    #
    # Dependency-free: this port introduces no external dependency (no persistence / framework
    # reference). The RedmineProfileProvider adapter is the shipped implementation.
    module ProfileProvider
    end
  end
end
