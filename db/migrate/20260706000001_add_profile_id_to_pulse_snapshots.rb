# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# C4 (FR-C4-05 / INV-C4-CACHE-PARTITION): add profile_id to pulse_snapshots so the
# RT-04 superseded-fingerprint prune (in ActiveRecordSnapshotStore#store) is SCOPED to
# a single active profile. Before C4 a (project_id, visibility_context_id) cell held at
# most one live fingerprint, so RT-04 could delete every OTHER-fingerprint row on write.
# With C4 the SAME (project, visibility_context) cell legitimately holds N concurrent
# rows — one per active scoring profile (each a distinct fingerprint). Without a profile
# dimension the RT-04 prune would delete profile A's row when profile B is warmed under
# the same viewer (cross-serve / cache-partition breach: IT-C4-01(2)/(3)). Scoping the
# prune to profile_id restores RT-04's DoS bound (still prunes stale-DATA fingerprints
# WITHIN one profile) while letting distinct profiles coexist.
#
# profile_id stores the RESOLVED active profile id, with the reserved "default"/nil path
# stored as the empty string '' so a default-only install keeps ONE row per cell exactly
# as pre-C4 (zero behavioral change on upgrade). NULL-safe default '' avoids a backfill.
# Reversible.
class AddProfileIdToPulseSnapshots < ActiveRecord::Migration[6.1]
  def up
    # Default '' so existing (pre-C4) rows and default-only installs partition identically
    # to the single-profile pre-C4 behavior (RT-04 still collapses each cell to one row).
    add_column :pulse_snapshots, :profile_id, :string, null: false, default: ''
  end

  def down
    remove_column :pulse_snapshots, :profile_id
  end
end
