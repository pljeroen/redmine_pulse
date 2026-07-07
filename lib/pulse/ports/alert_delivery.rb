# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # AlertDelivery — a duck-typed port. Any object responding to #deliver
    # satisfies the protocol. RETAINED though v1 ships only the EMAIL adapter
    # (RedmineAlertDelivery over Pulse::Mailer) — a future in-app / webhook adapter plugs in
    # here without a domain or port change (in-app delivery is deferred).
    #
    # Protocol:
    #   deliver(alert_event, recipients) -> void
    #       Dispatch the alert to each recipient. Best-effort per recipient: a per-recipient
    #       failure is RESCUED + LOGGED and MUST NOT propagate out, so one bad
    #       recipient never aborts the scan or the remaining deliveries.
    #
    # The domain layer NEVER depends on this module.
    module AlertDelivery
    end
  end
end
