# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # ActiveRecordAlertStateStore — the AlertStateStore port over the PulseAlertState AR
    # model / pulse_alert_states table. Keyed SOLELY by project_id (the canonical/global
    # scoring profile). A second upsert on the same project_id UPDATES the existing row
    # (the UNIQUE index guarantees one row per project) — never a second row.
    #
    # This adapter is reachable ONLY from the scan_and_alert composition root
    # (lib/tasks/pulse.rake) — NEVER from any request-cycle path (it is additive: no
    # request ever reads or writes alert state).
    class ActiveRecordAlertStateStore
      # -> { last_rag:, last_dominant:, last_no_data:, last_score: } | nil.
      # nil on first run (no prior row for this project).
      #
      # lock: when true, the prior-state row is read with a LOCKING read (SELECT ... FOR UPDATE)
      # instead of a plain snapshot read. This is the MySQL freshness guarantee: under InnoDB's
      # default REPEATABLE READ isolation a plain consistent read reuses the transaction's pinned
      # snapshot, so a second concurrent scan (already serialized behind the per-project advisory
      # lock) could still read a STALE prior state and re-deliver. A locking read bypasses the
      # pinned snapshot and returns the LATEST row state, so the serialized second scan observes
      # the already-advanced state and emits nothing (fire-once-per-transition). The flag is set
      # by the caller ONLY on the MySQL path (see ScanAndAlert#advisory_lock), so PostgreSQL —
      # which already gets a fresh READ COMMITTED read after acquiring its transaction-scoped lock
      # — is byte-identical (lock: false, default). The lock is a no-op unless the read runs
      # inside a transaction (it always does: the advisory-lock critical section / test fixture).
      def find_by_project(project_id, lock: false)
        scope = PulseAlertState.where(project_id: project_id)
        scope = scope.lock if lock
        row = scope.first
        return nil if row.nil?

        {
          last_rag: row.last_rag,
          last_dominant: row.last_dominant,
          last_no_data: row.last_no_data,
          last_score: row.last_score
        }
      end

      # Insert-or-update the canonical alert-state row for project_id. updated_at is set
      # explicitly (the table declares no created_at; record_timestamps is off on the model).
      def upsert(project_id, last_rag:, last_dominant:, last_no_data:, last_score:)
        row = PulseAlertState.find_or_initialize_by(project_id: project_id)
        row.last_rag = last_rag
        row.last_dominant = last_dominant
        row.last_no_data = last_no_data
        row.last_score = last_score
        row.updated_at = Time.now.utc
        row.save!
        nil
      end
    end
  end
end
