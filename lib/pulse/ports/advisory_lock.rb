# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # AdvisoryLock — a duck-typed port. Any object responding to #with_lock satisfies the
    # protocol. It is standard-library-only — the port carries NO persistence type and names
    # NO adapter constant. The block form keeps the release discipline INSIDE the adapter
    # (PG txn auto-release vs MySQL ensure RELEASE_LOCK vs null no-op): the caller cannot
    # forget to unlock, and it is exception-safe by construction.
    #
    # Protocol:
    #   with_lock(project_id) { ... } -> (whatever the block returns)
    #     * project_id is the lock KEY (Integer-coerced by the SQL adapters). It is namespaced
    #       per-plugin so it cannot collide with any other advisory-lock user in the same DB.
    #     * The adapter takes the lock, yields the block WHILE HOLDING it, and releases the lock
    #       after the block returns OR raises (the adapter's own ensure/txn-unwind). The block's
    #       return value passes through unchanged.
    #     * The port MUST NOT swallow exceptions raised by the block — it propagates them after
    #       releasing the lock, so a scan error is never masked.
    #     * On a bounded-acquire adapter (MySQL), a non-acquire (timeout / NULL) FAILS CLOSED:
    #       the block does NOT run unlocked (running unlocked would be the double-delivery bug);
    #       the adapter returns [] (no events emitted) so the next cron run retries.
    #
    # The domain layer NEVER depends on this module; it documents the single-writer boundary the
    # scan_and_alert composition root consumes. No ABC/inheritance is required.
    module AdvisoryLock
    end
  end
end
