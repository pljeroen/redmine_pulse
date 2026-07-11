# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # MysqlAdvisoryLock — the AdvisoryLock port over a MySQL/MariaDB SESSION advisory lock
    # (GET_LOCK / RELEASE_LOCK). It gives MySQL the SAME single-writer serialization guarantee
    # PostgreSQL provides today: the per-project read->evaluate->deliver->advance critical section
    # runs holding the lock, so two overlapping scans of one transition deliver EXACTLY ONCE.
    #
    # ── ACQUISITION SEMANTICS (ASM-04 — pinned here) ──
    # GET_LOCK(name, timeout) returns 1 (acquired), 0 (timed out), or NULL (error/killed session).
    # We use a BOUNDED-BLOCKING acquire: ACQUIRE_TIMEOUT = 5 seconds. On contention the call BLOCKS
    # up to that timeout, then returns 1 the instant the current holder releases. This MIRRORS
    # PostgreSQL's block-then-observe semantics (R4): the second overlapping scan BLOCKS until the
    # first critical section finishes, then acquires, then observes the already-advanced state and
    # does NOT re-deliver — instead of skipping its scan entirely this cycle. The 5s bounds how
    # long the CONTENDED WAITER'S GET_LOCK call blocks — NOT the critical section itself (see
    # ACQUIRE_TIMEOUT comment below for what the lock is actually held across).
    #
    # ── FAIL CLOSED ON EXPIRY (the F1 invariant — backstop, not the normal path) ──
    # The timeout is a backstop for a STUCK holder (a wedged/killed session that never releases),
    # NOT the normal contention path. If GET_LOCK returns 0 (the 5s genuinely expired) or NULL
    # (error/killed session), the adapter MUST NOT run the critical section UNLOCKED — running
    # unlocked would BE the double-delivery bug. It returns [] (no events emitted) so advance_state
    # never runs unprotected; the next cron run retries. Only when GET_LOCK == 1 does the block run,
    # and RELEASE_LOCK ALWAYS fires in an `ensure` so the session lock is freed even if the block
    # raises (no held-lock leak). This block-with-bounded-timeout + fail-closed-on-expiry contract
    # SUPERSEDES the earlier "try once / timeout 0 / skip on contention" prose.
    #
    # ── OPERABILITY PRECONDITION (ASM-01/ASM-02) ──
    # MySQL session advisory locks are SESSION-scoped: GET_LOCK, the yielded block's queries, and
    # RELEASE_LOCK MUST all run on the SAME backend session. This adapter runs them all on the one
    # connection it captures at construction. This assumes a DIRECT DB connection (the standard
    # Redmine topology) — NOT a session-splitting multiplexer (e.g. ProxySQL) that could route
    # successive statements to different backend sessions.
    #
    # ── SINGLE-WRITER SCOPE (the two-tier serialization — pinned here) ──
    # MySQL's GET_LOCK is SESSION-scoped and, unlike PostgreSQL's pg_advisory_xact_lock,
    # RE-ENTRANT within a session: the SAME session can acquire the same named lock more than
    # once (each GET_LOCK returns 1). That is exactly the shape of an overlapping cron run that
    # shares one AR connection/session (Rails' transactional-test model pins all threads to one
    # connection). Under that shape GET_LOCK alone does NOT serialize the two critical sections —
    # both acquire and both run, re-delivering the transition (the F1 double-fire). PostgreSQL
    # avoids this because its lock is TRANSACTION-scoped (released at the requires_new savepoint
    # boundary), so the second in-session acquisition genuinely BLOCKS until the first critical
    # section finishes.
    #
    # To give MySQL the SAME real mutual exclusion PG provides, this adapter serializes the
    # critical section on TWO tiers:
    #   (1) CROSS-PROCESS (the real overlapping-cron defect: two `rake scan_and_alert` processes =
    #       two backend SESSIONS): the SESSION advisory lock GET_LOCK/RELEASE_LOCK. Session B in a
    #       DIFFERENT process cannot acquire while session A holds it -> fail closed -> skip.
    #   (2) SAME-PROCESS / SAME-SESSION (the reentrant-GET_LOCK hole, exercised by the overlapping-
    #       thread test on a shared connection): an in-PROCESS per-project Mutex, taken BEFORE
    #       GET_LOCK and held for the whole critical section. Two threads in one process cannot run
    #       the section concurrently, so the second thread runs strictly AFTER the first advanced
    #       the state — mirroring PG's transaction-scoped blocking. The mutex is process-local and
    #       adds ZERO SQL, so it is invisible to the pure-adapter SQL-shape unit spies.
    #
    # ── SNAPSHOT FRESHNESS (defense-in-depth for the serialized second scan) ──
    # Once serialized (tier 2), the second scan runs after the first's UPDATE. On a shared
    # connection that write is the transaction's OWN write, so even a plain read sees it. To also
    # cover the cross-process case under InnoDB REPEATABLE READ (where a plain consistent read
    # would reuse the pinned MVCC snapshot and miss a sibling process's committed advance), the
    # prior-alert-state read is a LOCKING read (SELECT ... FOR UPDATE) — see
    # ActiveRecordAlertStateStore#find_by_project(lock:). A locking read bypasses the snapshot and
    # returns the LATEST row, so the serialized second scan observes the already-advanced state and
    # emits nothing. Setting the transaction isolation here is not an option (InnoDB forbids SET
    # TRANSACTION ISOLATION inside the already-open fixture transaction). The locking read is gated
    # by the caller so PostgreSQL (R3) is byte-identical: it is requested ONLY on the MySQL path.
    #
    # ── FAIL CLOSED ON EXPIRY (the F1 invariant — backstop) ──
    # If GET_LOCK returns 0 (the bounded 5s wait genuinely expired — a stuck holder) or NULL
    # (error/killed), the adapter MUST NOT run the critical section UNLOCKED. It returns [] (no
    # events emitted) so advance_state never runs unprotected; the next cron run retries. The
    # in-process mutex is ALWAYS released and RELEASE_LOCK ALWAYS fires (only when GET_LOCK
    # acquired) in `ensure`, so neither tier can leak on a raised block.
    #
    # ── OPERABILITY PRECONDITION (ASM-01/ASM-02) ──
    # MySQL session advisory locks are SESSION-scoped: GET_LOCK, the yielded block's queries, and
    # RELEASE_LOCK MUST all run on the SAME backend session. This adapter runs them all on the one
    # connection it captures at construction. This assumes a DIRECT DB connection (the standard
    # Redmine topology) — NOT a session-splitting multiplexer (e.g. ProxySQL) that could route
    # successive statements to different backend sessions.
    class MysqlAdvisoryLock
      # Bounded-blocking acquire window, in seconds (see ACQUISITION SEMANTICS above).
      #
      # HONEST SCOPE OF THE LOCK: the lock is held for the WHOLE scan_project critical section of one
      # project — NOT just "a couple of reads + one UPDATE". That section (scan_and_alert.rb) also
      # runs recipient resolution AND the outbound side effects being deduped: EMAIL delivery and, if
      # configured, WEBHOOK HTTP dispatch, ALL before advance_state. Delivery is inside the lock BY
      # NECESSITY — the whole point is that only the single writer that owns the transition delivers
      # it. So the lock CAN be held across outbound I/O and CAN exceed 5s (e.g. a slow SMTP server or
      # a slow webhook endpoint).
      #
      # What the 5s actually bounds: it is NOT a claim that the critical section finishes within 5s.
      # It bounds how long a CONTENDED concurrent scan of the SAME project WAITS on GET_LOCK before
      # giving up. If the current holder finishes within 5s, the waiter acquires the instant it
      # releases and observes the already-advanced state (PG-like block-then-observe, no re-fire). If
      # the holder runs LONGER than 5s (slow webhook / SMTP), the waiter's GET_LOCK returns 0 and it
      # FAILS CLOSED — it safely SKIPS that project for THIS cron cycle and retries on the next run,
      # rather than blocking unbounded or (the F1 bug) running the section unlocked.
      #
      # Why 5s is kept: same-project cron overlap is an operational edge (a cron period is far longer
      # than one scan), webhooks are OFF by default, and fail-closed is SAFE (a skipped project is
      # re-scanned next cycle — at worst a one-cycle delay of an alert, never a double-fire and never
      # a lost transition, since state only advances under the lock). A larger timeout would make a
      # contended waiter block longer on a genuinely stuck holder for no correctness gain.
      ACQUIRE_TIMEOUT = 5

      # Stable per-plugin lock-name prefix. "pulse_advisory_" (15 chars) + a Bigint-max
      # project_id (19 digits) = 34 chars, well under MySQL's 64-char GET_LOCK name limit
      # (ASM-03), and disjoint from any other advisory-lock user in the same database.
      NAME_PREFIX = 'pulse_advisory_'

      # Process-local per-project mutex registry (tier 2). Keyed by Integer project_id so two
      # threads in ONE process (which may share one backend session, defeating the reentrant
      # session GET_LOCK) cannot run the same project's critical section concurrently. A single
      # guard mutex protects the lazy creation of the per-project mutexes.
      #
      # No reaping (bounded, not a leak): the registry holds one Mutex per DISTINCT project_id
      # touched by THIS process. The scan runs in a short-lived cron process that exits after the
      # cycle, so the registry lives only as long as that process and is bounded by the project
      # count — a few thousand entries at most, each a bare Mutex. Reaping would add locking
      # complexity for no real memory benefit; it is deliberately omitted.
      @project_mutexes = {}
      @registry_guard = Mutex.new

      class << self
        # The Mutex for this project_id, created once and reused (stable identity across adapter
        # instances, which are constructed per scan run).
        def project_mutex(project_id)
          key = Integer(project_id)
          @registry_guard.synchronize do
            @project_mutexes[key] ||= Mutex.new
          end
        end
      end

      def initialize(connection)
        @conn = connection
      end

      # with_lock(project_id) { ... } -> the block's return value on acquire; [] fail-closed.
      def with_lock(project_id)
        # Tier 2: serialize same-process threads for this project BEFORE touching the session lock,
        # so the reentrant session GET_LOCK can never let two in-process critical sections overlap.
        self.class.project_mutex(project_id).synchronize do
          acquire_and_run(project_id) { yield }
        end
      end

      private

      # Tier 1: the cross-process session advisory lock around the critical section.
      def acquire_and_run(project_id)
        name = lock_name(project_id)
        quoted = @conn.quote(name)

        # Blocks up to ACQUIRE_TIMEOUT seconds, then returns 1 the instant the holder releases.
        acquired = @conn.select_value("SELECT GET_LOCK(#{quoted}, #{ACQUIRE_TIMEOUT})")
        # FAIL CLOSED ON EXPIRY: 0 (the bounded wait expired — a stuck holder) or NULL
        # (error/killed) => do NOT yield unlocked; skip this run, next cron retries.
        return [] unless acquired.to_i == 1

        begin
          yield
        ensure
          @conn.select_value("SELECT RELEASE_LOCK(#{quoted})")
        end
      end

      # Stable, <=64-char lock name derived from the plugin namespace + Integer-coerced id.
      def lock_name(project_id)
        "#{NAME_PREFIX}#{Integer(project_id)}"
      end
    end
  end
end
