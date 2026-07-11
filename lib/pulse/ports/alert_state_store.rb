# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # AlertStateStore — a duck-typed port. Any object responding to the
    # methods below satisfies the protocol. It is standard-library-only — the port carries NO
    # persistence types; the production adapter (ActiveRecordAlertStateStore) owns all I/O.
    #
    # Keyed SOLELY by project_id (per-project / canonical profile).
    #
    # Protocol:
    #   find_by_project(project_id, lock: false)
    #     -> { last_rag:, last_dominant:, last_no_data:, last_score: } | nil   # nil on first run
    #     The optional `lock:` kwarg requests a committed/locking read (SELECT ... FOR UPDATE) of
    #     the alert-state row for the serialized critical section. When true the read bypasses the
    #     transaction's pinned MVCC snapshot and returns the LATEST committed row, so the serialized
    #     second scan observes an already-advanced state and does not re-deliver (fire-once). The
    #     caller sets it ONLY on engines that need it (MySQL/InnoDB REPEATABLE READ); it defaults to
    #     false, leaving the plain-read path — and PostgreSQL — byte-identical.
    #   upsert(project_id, last_rag:, last_dominant:, last_no_data:, last_score:)
    #     -> void   # insert-or-update on the unique project_id key (never a second row)
    #
    # The domain layer NEVER depends on this module; it documents the alert-state boundary
    # the scan_and_alert composition root consumes.
    module AlertStateStore
    end
  end
end
