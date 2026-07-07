# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Scoring-profiles support: add profile_id to pulse_snapshots so the
# superseded-fingerprint prune (in ActiveRecordSnapshotStore#store) is SCOPED to
# a single active profile. Previously a (project_id, visibility_context_id) cell held at
# most one live fingerprint, so the prune could delete every OTHER-fingerprint row on write.
# With scoring profiles the SAME (project, visibility_context) cell legitimately holds N
# concurrent rows — one per active scoring profile (each a distinct fingerprint). Without a
# profile dimension the prune would delete profile A's row when profile B is warmed under
# the same viewer (a cross-serve / cache-partition breach). Scoping the
# prune to profile_id restores the prune's DoS bound (still prunes stale-DATA fingerprints
# WITHIN one profile) while letting distinct profiles coexist.
#
# profile_id stores the RESOLVED active profile id, with the reserved "default"/nil path
# stored as the empty string '' so a default-only install keeps ONE row per cell exactly
# as before this change (zero behavioral change on upgrade). NULL-safe default '' avoids a backfill.
# Reversible.
class AddProfileIdToPulseSnapshots < ActiveRecord::Migration[6.1]
  def up
    # Default '' so existing rows and default-only installs partition identically
    # to the earlier single-profile behavior (the prune still collapses each cell to one row).
    add_column :pulse_snapshots, :profile_id, :string, null: false, default: ''
  end

  def down
    remove_column :pulse_snapshots, :profile_id
  end
end
