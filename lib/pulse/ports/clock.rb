# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'date'

module Pulse
  module Ports
    # Clock is a duck-typed port: any object that responds to #today and returns a
    # plain Date satisfies the protocol. The domain reads the current day ONLY through
    # an injected Clock; it never reads the system calendar directly.
    #
    # Protocol:
    #   clock.today -> Date   # the "as-of" calendar day used for staleness/momentum
    #   clock.now   -> Time   # the absolute UTC instant (used for the snapshot
    #                         #   max-age freshness check; injectable/testable, never
    #                         #   read from the system clock directly)
    #
    # This module documents the contract. No ABC/inheritance is required; production
    # adapters and test doubles simply implement #today (and #now).
    module Clock
    end
  end
end
