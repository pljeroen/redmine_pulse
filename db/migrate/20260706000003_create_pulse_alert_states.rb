# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Creates the plugin-owned pulse_alert_states table.
#
# This is the per-project alert-state ledger the scan task compares against to detect a
# transition. It is a SEPARATE table from pulse_snapshots (the projection cache) — no
# cache impact, no schema change to pulse_snapshots. It is keyed by project_id ONLY (the
# canonical/global profile) — NEVER visibility_context_id / profile_id
# (contrast pulse_snapshots, which partitions per viewer + profile). A UNIQUE index on
# project_id guarantees exactly one canonical alert-state row per project (upsert, not
# insert-a-second-row).
#
# NO foreign keys to Redmine domain tables (a dropped project simply orphans its row; the
# scan only ever reads the row for a project it is actively scanning). Reversible: `down`
# drops the table cleanly (drop_table drops its index too, matching the pulse_views idiom).
class CreatePulseAlertStates < ActiveRecord::Migration[6.1]
  def up
    create_table :pulse_alert_states do |t|
      t.integer  :project_id,   null: false                # canonical key (per-project only)
      t.string   :last_rag,     null: true                 # last evaluated RAG band ('green'/…/'no_data')
      t.string   :last_dominant, null: true                # last dominant signal key
      t.boolean  :last_no_data, null: false, default: false # was the last band :no_data?
      t.float    :last_score,   null: true                 # last health_score (nil in :no_data)
      t.datetime :updated_at,   null: false                # last evaluation instant
    end

    add_index :pulse_alert_states, :project_id, unique: true,
              name: 'index_pulse_alert_states_on_project_id'
  end

  # drop_table also drops the table's indexes, so no separate remove_index is needed.
  def down
    drop_table :pulse_alert_states
  end
end
