# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

module Pulse
  module Ports
    # MetricsSource is a duck-typed port: any object that responds to the methods
    # below satisfies the contract. The domain never depends on this module; it is
    # documentation of the adapter boundary the controllers consume.
    #
    # Protocol:
    #   metrics_for(user, project_ids: nil)
    #     -> Array<Pulse::Domain::ProjectMetrics>
    #     project_ids nil   => every project visible + pulse-enabled + view_pulse
    #     project_ids Array => the visibility-filtered subset of those ids
    #     result ALWAYS ordered by project_id ascending (FC-34).
    #   access_decision(user, project_id) -> :ok | :forbidden | :not_found
    #   portfolio_project_ids(user)       -> Array<Integer>
    #
    # All aggregates are visibility-scoped for the requesting user; the returned
    # ProjectMetrics are AR-free frozen value objects (FC-33). No ABC/inheritance.
    module MetricsSource
    end
  end
end
