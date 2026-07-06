# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # SubscriptionStore — a duck-typed port (C6 / FC-C6-07). Any object responding to the
    # methods below satisfies the contract. stdlib-only surface; the production adapter
    # (RedmineSubscriptionStore) owns all Redmine I/O.
    #
    # Protocol:
    #   subscribers_for(project_id) -> Array<User>
    #       The recipient set for a project's alert: the UNION of explicit "Watch project
    #       health" watchers AND members of the admin auto-subscribe role, FILTERED by the
    #       permission-at-send gate — a candidate is included ONLY IF, at RESOLUTION time,
    #       user.allowed_to?(:view_pulse, project) is TRUE against LIVE permission state
    #       (INV-C6-PERM-AT-SEND). ANY conforming implementation MUST apply that gate here
    #       (the gate MUST NOT live downstream in delivery — RISK-C6-01).
    #   watch!(user, project)   -> void   # subscribe (idempotent)
    #   unwatch!(user, project) -> void   # unsubscribe (idempotent)
    #
    # The domain layer NEVER depends on this module.
    module SubscriptionStore
    end
  end
end
