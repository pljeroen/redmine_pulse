# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseAlertState — the per-project canonical alert-state row over pulse_alert_states
# (C6 / FC-C6-05). Autoloaded by Rails from app/models (top-level constant, path-matched —
# consistent with PulseSnapshot / PulseView). Keyed by project_id ONLY (per-project /
# canonical profile; DEC-10). It is written ONLY by the scan_and_alert composition root
# (via ActiveRecordAlertStateStore) — never on any request-cycle path (INV-ADDITIVE).
#
# The table declares only updated_at (no created_at), so record_timestamps must NOT try to
# stamp a missing created_at column; the store sets updated_at explicitly instead.
class PulseAlertState < ActiveRecord::Base
  self.record_timestamps = false
end
