# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # SnapshotStore is a duck-typed port: any object responding to the methods
    # below satisfies the contract (FC-CA-04/25). It is stdlib-only — the port
    # surface carries NO framework/persistence types; the production adapter
    # (Pulse::Adapters, the AR-backed snapshot store) owns ALL database I/O.
    #
    # The domain layer NEVER depends on this module (CA-25): it documents the
    # cache boundary the controllers (the composition root) consume.
    #
    # Protocol:
    #   fetch_row(project_id, visibility_context_id, fingerprint)
    #     -> {payload: Hash, computed_at: Time} | nil   # single-query hit, nil on miss
    #   fetch_rows(keys)
    #     -> { [pid, ctx, fp] => {payload:, computed_at:} }  # bulk hit-map (no N+1)
    #   store(project_id, visibility_context_id, fingerprint, payload)
    #     -> void          # idempotent insert-or-ignore on the unique key
    #   refresh(project_id, visibility_context_id, fingerprint, payload)
    #     -> void          # deliberate OVERWRITE of the keyed row: payload replaced +
    #                      #   computed_at = now (created_at left as-is); creates the row
    #                      #   if absent (store fallback). The max-age freshness-cap write
    #                      #   path — distinct from #store (insert-or-ignore). Overwrites
    #                      #   the SAME key (no new row), so growth is unchanged.
    #   invalidate_project(project_id)
    #     -> Integer       # number of cache rows deleted for that project
    #
    # The cache key is the tuple (project_id, visibility_context_id,
    # snapshot_fingerprint). The Clock is DELIBERATELY excluded from the key so
    # the time-derived score re-projects per request without a recompute
    # (FC-CA-20/21). No ABC/inheritance is required.
    module SnapshotStore
    end
  end
end
