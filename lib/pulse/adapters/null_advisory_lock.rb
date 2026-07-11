# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # NullAdvisoryLock — a DOCUMENTED no-op degrade for connections with no advisory-lock
    # primitive (dev SQLite / any other adapter outside the PG + MySQL/MariaDB support matrix).
    # It simply yields the block and passes its return value through, issuing ZERO SQL.
    #
    # The single-writer guarantee is NOT asserted here: on such an engine two overlapping scans
    # could both run the critical section (the pre-refactor `else yield` behaviour). This is
    # acceptable only because the production DB shape is PostgreSQL or MySQL8, where a real
    # adapter is selected; SQLite is a dev convenience, not a concurrent-cron target.
    class NullAdvisoryLock
      def initialize(connection = nil)
        @conn = connection
      end

      # with_lock(project_id) { ... } -> the block's return value. No lock taken; no SQL issued.
      def with_lock(_project_id)
        yield
      end
    end
  end
end
