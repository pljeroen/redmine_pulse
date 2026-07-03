# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # SettingsProvider is a duck-typed port: any object responding to the methods
    # below satisfies the contract. It maps plugin Settings into the pure-domain
    # ScoringConfig and exposes the enrichment-mapping state the adapter reads.
    #
    # Protocol:
    #   scoring_config         -> Pulse::Domain::ScoringConfig
    #   settings_version_hash  -> String (deterministic; changes on any settings change)
    #   effort_mapped?         -> Boolean (true iff configured AND numeric-format)
    #   effort_custom_field_id -> Integer | nil
    #   risk_mapped?           -> Boolean
    #   risk_tracker_ids       -> Array<Integer>
    #   blocked_status_id      -> Integer | nil
    #
    # No ABC/inheritance is required; production adapters and test doubles simply
    # implement the subset of these methods they use.
    module SettingsProvider
    end
  end
end
