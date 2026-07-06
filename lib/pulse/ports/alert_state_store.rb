# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # AlertStateStore — a duck-typed port (C6 / FC-C6-05). Any object responding to the
    # methods below satisfies the contract. It is stdlib-only — the port carries NO
    # persistence types; the production adapter (ActiveRecordAlertStateStore) owns all I/O.
    #
    # Keyed SOLELY by project_id (per-project / canonical profile; DEC-10 / FC-C6-12).
    #
    # Protocol:
    #   find_by_project(project_id)
    #     -> { last_rag:, last_dominant:, last_no_data:, last_score: } | nil   # nil on first run
    #   upsert(project_id, last_rag:, last_dominant:, last_no_data:, last_score:)
    #     -> void   # insert-or-update on the unique project_id key (never a second row)
    #
    # The domain layer NEVER depends on this module; it documents the alert-state boundary
    # the scan_and_alert composition root consumes.
    module AlertStateStore
    end
  end
end
