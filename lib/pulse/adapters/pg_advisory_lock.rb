# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # PgAdvisoryLock — the AdvisoryLock port over a PostgreSQL transaction-scoped advisory
    # lock. BYTE-IDENTICAL to the pre-refactor inline behaviour in ScanAndAlert#with_project_lock:
    # a transaction-scoped advisory lock keyed by (classid=LOCK_NAMESPACE, objid=Integer(id)) is
    # taken via pg_advisory_xact_lock inside a `conn.transaction(requires_new: true)`, the block
    # runs UNDER that lock, and the lock auto-releases when the surrounding transaction
    # commits/rolls back — no explicit unlock, no leak on a crashed process. It requires NO state
    # row (correct on the FIRST run) and adds NO schema (reversible).
    #
    # pg_advisory_xact_lock BLOCKS until acquired (no timeout): the second overlapping scan waits
    # until the first commits its advance_state, then reads the already-advanced state and emits
    # nothing — the fire-once-per-transition guarantee.
    class PgAdvisoryLock
      # LOCK_NAMESPACE = 0x70756c73 ('puls') — the stable per-plugin advisory-lock classid,
      # keeping our keyspace disjoint from any other advisory-lock user in the same database. Its
      # canonical home now lives here (the Pg adapter owns the PG keyspace); the numeric value is
      # preserved verbatim so PG lock keys are byte-identical to the pre-refactor implementation.
      LOCK_NAMESPACE = 0x70756c73

      def initialize(connection)
        @conn = connection
      end

      # with_lock(project_id) { ... } -> the block's return value.
      def with_lock(project_id)
        @conn.transaction(requires_new: true) do
          @conn.execute(
            "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(project_id)})"
          )
          yield
        end
      end
    end
  end
end
