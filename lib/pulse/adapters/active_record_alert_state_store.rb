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
    # model / pulse_alert_states table (C6 / FC-C6-05). Keyed SOLELY by project_id (the
    # canonical/global profile; DEC-10). A second upsert on the same project_id UPDATES the
    # existing row (the UNIQUE index guarantees one row per project) — never a second row.
    #
    # This adapter is reachable ONLY from the scan_and_alert composition root
    # (lib/tasks/pulse.rake) — NEVER from any request-cycle path (INV-ADDITIVE).
    class ActiveRecordAlertStateStore
      # -> { last_rag:, last_dominant:, last_no_data:, last_score: } | nil.
      # nil on first run (no prior row for this project).
      def find_by_project(project_id)
        row = PulseAlertState.find_by(project_id: project_id)
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
