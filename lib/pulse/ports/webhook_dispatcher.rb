# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # WebhookDispatcher — a duck-typed port. Any object responding to
    # #dispatch satisfies the protocol. It depends ONLY on Pulse::Domain::AlertEvent (a pure
    # value object); it names NO adapter constant, performs NO outbound HTTP, and touches no
    # persistence / plugin config — those live exclusively in the concrete adapter.
    #
    # Protocol:
    #   dispatch(alert_event, project:, health_result:, previous:) -> void
    #       Fan out the alert to EVERY configured, enabled, event-filter-matching endpoint
    #       (the settings-driven list). Best-effort per endpoint: a delivery failure is
    #       dead-lettered (logged) and MUST NOT propagate out. With an empty endpoint
    #       list the loop body never runs (the OFF-by-default structural short-circuit) —
    #       ZERO outbound HTTP.
    #
    # The concrete adapter also exposes a single-endpoint primitive (#deliver) — the shared
    # work unit invoked by #dispatch (fan-out) AND by the admin test-event action (exactly ONE
    # endpoint). The domain layer NEVER depends on this module.
    module WebhookDispatcher
    end
  end
end
