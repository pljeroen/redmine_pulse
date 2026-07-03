# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

# Creates the plugin-owned pulse_snapshots cache table (FC-CA-05). It collides
# with no Redmine core table (plugin-prefixed; CD-CA-03) and is the ONLY table
# the GET/refresh paths are permitted to write (INV-READ-ONLY confines all
# writes to pulse_snapshots + the plugin settings row).
#
# payload is a `text` column (DG-03 / OSI-CA-02): the Date-bearing static
# aggregate is serialized to JSON text so the round-trip reconstructs Dates
# (BR-03) and the schema stays portable (SQLite/MySQL/PostgreSQL) — JSONB is a
# deferred optimization, not a correctness requirement. Reversible.
class CreatePulseSnapshots < ActiveRecord::Migration[6.1]
  def up
    create_table :pulse_snapshots do |t|
      t.integer  :project_id,            null: false
      t.string   :visibility_context_id, null: false
      t.string   :snapshot_fingerprint,  null: false
      t.text     :payload,               null: false
      t.datetime :computed_at,           null: false
      t.datetime :created_at,            null: false
    end

    # The content-addressed cache key (project_id, visibility_context_id,
    # snapshot_fingerprint). UNIQUE so a concurrent cold-miss insert-or-ignore
    # converges to exactly one row (FC-CA-06).
    add_index :pulse_snapshots,
              %i[project_id visibility_context_id snapshot_fingerprint],
              unique: true,
              name: 'index_pulse_snapshots_on_cache_key'
  end

  # drop_table also drops the table's index, so no separate remove_index is needed;
  # this keeps the down path robust even against a dirty/partial DB state where an
  # index lookup could otherwise fail.
  def down
    drop_table :pulse_snapshots
  end
end
