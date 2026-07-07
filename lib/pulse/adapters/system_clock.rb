# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # Clock port implementation backed by Redmine's instance-configured timezone.
    # #today returns a plain Date in Time.zone — NOT the UTC date —
    # so day-boundary cases respect the instance setting.
    class SystemClock
      # -> Date == Time.zone.today (instance tz, not UTC).
      def today
        Time.zone.today
      end

      # -> Time (absolute UTC instant). The snapshot max-age freshness check compares
      # this against the stored computed_at (both UTC); injectable/testable so the
      # age-refresh never reads a bare Time.now.
      def now
        Time.now.utc
      end
    end
  end
end
