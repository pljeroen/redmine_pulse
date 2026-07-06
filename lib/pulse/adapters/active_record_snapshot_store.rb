# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'date'
require 'json'

module Pulse
  module Adapters
    # ActiveRecordSnapshotStore — the production SnapshotStore adapter (FC-CA-06/07/08).
    # Owns ALL database I/O for the plugin-owned pulse_snapshots cache table; the
    # SnapshotStore PORT stays stdlib-only. It NEVER writes a Redmine domain table —
    # its sole write surface is pulse_snapshots (INV-READ-ONLY / FC-CA-13).
    #
    # The payload column is JSON text (DG-03 / OSI-CA-02). Because JSON erases the
    # Ruby Date/Symbol types ProjectMetrics requires (FR-01), serialize_metrics /
    # deserialize_metrics explicitly round-trip Date<->String and Symbol<->String so a
    # deserialized snapshot reconstructs ProjectMetrics and scores identically (BR-03 /
    # FC-CA-07).
    class ActiveRecordSnapshotStore
      # The plugin-owned cache row. Declared inline so the adapter is self-contained;
      # it maps to the pulse_snapshots table created by the contract migration.
      class PulseSnapshot < ActiveRecord::Base
        self.table_name = 'pulse_snapshots'
      end

      def initialize; end

      # fetch_row(project_id, visibility_context_id, fingerprint) -> {payload:, computed_at:} | nil
      # Like #fetch but returns the stored computed_at alongside the deserialized payload
      # in a SINGLE query (so the caller needs no second round-trip for the snapshot
      # instant — FC-CA-15 with one SELECT per project, not two).
      def fetch_row(project_id, visibility_context_id, fingerprint)
        row = PulseSnapshot
              .where(project_id: project_id,
                     visibility_context_id: visibility_context_id,
                     snapshot_fingerprint: fingerprint)
              .first
        return nil if row.nil?

        { payload: JSON.parse(row.payload), computed_at: row.computed_at }
      end

      # fetch_rows(keys) -> { [pid, ctx, fp] => {payload:, computed_at:} }
      # Bulk variant: ONE SELECT for a whole portfolio's worth of cache keys, so the warm
      # portfolio path is O(1) queries, not N+1 (SOFT-PERF / CA-30). `keys` is an array
      # of [project_id, visibility_context_id, fingerprint] tuples.
      def fetch_rows(keys)
        return {} if keys.empty?

        # CDX-04 (security-S2-dos, perf): fetch ONLY the exact requested cache-key tuples
        # instead of `where(project_id: pids).find_each` scanning + JSON-parsing every row for
        # those projects (which, combined with the RT-04 accretion, was an unbounded scan/parse
        # lever). We build an OR-of-tuples predicate with BOUND params (portable across Postgres
        # and MySQL; parameterized, so injection-safe) so only the requested rows are loaded and
        # deserialized. The return shape is identical: { [pid, ctx, fp] => {payload:, computed_at:} }.
        uniq_keys = keys.uniq
        clause = (['(project_id = ? AND visibility_context_id = ? AND snapshot_fingerprint = ?)'] *
                  uniq_keys.size).join(' OR ')
        binds = uniq_keys.flat_map { |k| [k[0], k[1], k[2]] }

        index = {}
        PulseSnapshot.where([clause, *binds]).find_each do |row|
          k = [row.project_id, row.visibility_context_id, row.snapshot_fingerprint]
          index[k] = { payload: JSON.parse(row.payload), computed_at: row.computed_at }
        end
        keys.each_with_object({}) do |k, acc|
          hit = index[[k[0], k[1], k[2]]]
          acc[k] = hit if hit
        end
      end

      # store(project_id, visibility_context_id, fingerprint, payload, profile_id:) -> void
      # Idempotent insert-or-ignore on the unique cache key: a duplicate-key store is a
      # silent no-op (the concurrent cold-miss race converges to exactly one row,
      # FC-CA-06). Writes ONLY pulse_snapshots.
      def store(project_id, visibility_context_id, fingerprint, payload,
                computed_at: Time.now.utc, profile_id: '')
        now = computed_at
        pid = profile_id.to_s
        # RT-04 (security-S2-dos): prune SUPERSEDED fingerprints. A changed fingerprint for the
        # same (project_id, visibility_context_id) means the underlying DATA changed, so any row
        # under that cell carrying a DIFFERENT fingerprint is dead — it can never again be a valid
        # cache hit. Without this the cell accretes one dead row per data change (unbounded scan +
        # memory on every warm fetch — an availability lever).
        #
        # C4 (INV-C4-CACHE-PARTITION / IT-C4-01): the prune is SCOPED to profile_id. Pre-C4 a
        # (project, visibility_context) cell held at most ONE live fingerprint, so pruning every
        # OTHER-fingerprint row was correct. With C4 the SAME cell legitimately holds one live row
        # PER ACTIVE PROFILE (each a distinct fingerprint). An UNSCOPED prune would delete profile
        # A's row when profile B is warmed under the same viewer — a cross-serve / cache-partition
        # breach (A's row vanishes; a later A request misses and can even be served B's warmed row
        # via the shared cell). Scoping to profile_id deletes only stale-DATA fingerprints WITHIN
        # the SAME profile (RT-04's DoS bound preserved) while letting distinct profiles coexist.
        # The reserved default/nil profile stores profile_id '' so a default-only install still
        # collapses its cell to exactly one row (pre-C4 behavior unchanged).
        #
        # We delete only the OTHER-fingerprint rows for THIS profile (the SAME-key re-store /
        # #refresh path deletes nothing, so those stay one row), then create. Under a concurrent
        # create of the same NEW key the create raises RecordNotUnique and is swallowed below, so
        # the cell still converges to exactly one row per profile. Writes ONLY pulse_snapshots
        # (INV-READ-ONLY / FC-CA-13).
        PulseSnapshot
          .where(project_id: project_id, visibility_context_id: visibility_context_id,
                 profile_id: pid)
          .where.not(snapshot_fingerprint: fingerprint)
          .delete_all
        PulseSnapshot.create!(
          project_id: project_id,
          visibility_context_id: visibility_context_id,
          snapshot_fingerprint: fingerprint,
          profile_id: pid,
          payload: JSON.generate(payload),
          computed_at: now,
          created_at: now
        )
        nil
      rescue ActiveRecord::RecordNotUnique
        # A row for this exact key already exists — the insert-or-ignore semantics
        # (ON CONFLICT DO NOTHING) swallow the unique-constraint violation, no raise.
        nil
      end

      # refresh(project_id, visibility_context_id, fingerprint, payload) -> void
      # The max-age freshness-cap write path: OVERWRITE the row for this exact key
      # in place (payload replaced + computed_at bumped to now; created_at left as-is)
      # so "computed X ago" resets. Distinct from #store (insert-or-ignore) — refresh is
      # the deliberate overwrite. If no row exists for the key it CREATES one (store
      # fallback, defensive). Overwrites the SAME key -> no new row (growth unchanged).
      # Idempotent under concurrency (last-write-wins; the payload is identical since the
      # fingerprint is unchanged). Writes ONLY pulse_snapshots (INV-READ-ONLY / FC-CA-13).
      #
      # computed_at defaults to the wall-clock instant (Time.now.utc); the projection
      # engine passes its INJECTED @clock.now so the persisted freshness instant is the
      # same clock the age-check reads (SystemClock#now == Time.now.utc in production, so
      # this is transparent there — it only matters under a test/fixed clock).
      def refresh(project_id, visibility_context_id, fingerprint, payload,
                  computed_at: Time.now.utc, profile_id: '')
        now = computed_at
        # Update by the UNIQUE cache key (project, visibility_context, fingerprint); the
        # fingerprint already folds the profile, so this touches exactly the one row for this
        # profile+data. profile_id is threaded only for the create-fallback below (a row that
        # somehow does not yet exist), so a freshly created row carries the right partition.
        updated = PulseSnapshot
                  .where(project_id: project_id,
                         visibility_context_id: visibility_context_id,
                         snapshot_fingerprint: fingerprint)
                  .update_all(payload: JSON.generate(payload), computed_at: now)
        if updated.zero?
          store(project_id, visibility_context_id, fingerprint, payload,
                computed_at: now, profile_id: profile_id)
        end
        nil
      end

      # invalidate_project(project_id) -> Integer (deleted-row count)
      # Per-project scope ONLY (CD-CA-04): deletes every cache row for that project,
      # touches no other project's rows, and returns the affected-row count (0 + no
      # error when nothing was cached).
      def invalidate_project(project_id)
        PulseSnapshot.where(project_id: project_id).delete_all
      end

      # invalidate_context(project_id, visibility_context_id) -> Integer (deleted-row count)
      # RT-06 (security-S2-dos): the caller-SCOPED runtime invalidation for POST /pulse/refresh.
      # Deletes ONLY the rows for this (project_id, visibility_context_id) cell — every OTHER
      # visibility context's warmed snapshot for the same project is left intact, bounding the
      # blast radius of a single viewer's refresh to that viewer's own context. Returns the
      # affected-row count (0 + no error when nothing was cached). Writes ONLY pulse_snapshots
      # (INV-READ-ONLY / FC-CA-13). invalidate_project (all contexts) stays for the admin rake
      # flush; this is the least-privilege runtime path.
      def invalidate_context(project_id, visibility_context_id)
        PulseSnapshot
          .where(project_id: project_id, visibility_context_id: visibility_context_id)
          .delete_all
      end

      # clear_all -> Integer (deleted-row count)
      # GLOBAL cache flush: deletes EVERY pulse_snapshots row across all projects and
      # visibility contexts, returning the affected-row count. This is the admin-driven
      # global rebuild path (the `pulse:cache:clear` rake task) — distinct from the
      # per-project POST /pulse/refresh, which is the ONLY runtime invalidation.
      #
      # GROWTH CHARACTERISTIC: the pulse_snapshots cache has NO TTL / eviction. A row is
      # written on every cold (project_id, visibility_context_id, snapshot_fingerprint)
      # miss and removed only by invalidate_project (per-project refresh) or this method
      # (global clear). A long-lived instance with many viewers / churning fingerprints
      # accumulates rows unboundedly; `pulse:cache:clear` lets an admin reclaim the table.
      # Writes ONLY pulse_snapshots (INV-READ-ONLY / FC-CA-13).
      def clear_all
        PulseSnapshot.delete_all
      end

      # ---- BR-03 serialization round-trip (FC-CA-07; OPTIONAL helpers) -----------

      # serialize_metrics(ProjectMetrics) -> Hash (JSON-safe; Dates -> ISO strings,
      # Symbols -> strings) suitable to pass to #store.
      def serialize_metrics(metrics)
        payload = {
          'project_id' => metrics.project_id,
          'reference_date' => metrics.reference_date.iso8601,
          'effort_open' => metrics.effort_open,
          'effort_total' => metrics.effort_total,
          'risk_raw' => metrics.risk_raw,
          'blocked_count' => metrics.blocked_count,
          'risk_mapped' => metrics.risk_mapped,
          'effort_mapped' => metrics.effort_mapped,
          'event_series' => metrics.event_series.map do |e|
            { 'date' => e[:date].iso8601, 'type' => e[:type].to_s }
          end,
          'version_due_dates' => metrics.version_due_dates.map do |v|
            { 'version_id' => v[:version_id], 'name' => v[:name], 'due_date' => v[:due_date].iso8601 }
          end
        }
        # C2 (FC-C2-08 / A10-C2-003 b): coverage_gap signal inputs. Plain Integer/Float —
        # JSON-safe as-is. OMITTED when they are the neutral default (0 / 0.0) — i.e. on the
        # default-OFF path where coverage gathering is skipped (redmine_metrics_source returns
        # 0/0.0). So a default-OFF snapshot payload is BYTE-IDENTICAL to a pre-C2 payload
        # (no coverage keys), and the deserializer's pre-C2 fallback (absent => 0/0.0) restores
        # them losslessly. Only an ENABLED snapshot with real coverage data persists the fields.
        unless metrics.open_issue_count.zero? && metrics.covered_sum.zero?
          payload['open_issue_count'] = metrics.open_issue_count
          payload['covered_sum'] = metrics.covered_sum
        end
        payload
      end

      # deserialize_metrics(Hash) -> Pulse::Domain::ProjectMetrics. Re-hydrates ISO
      # date strings -> plain Date and type strings -> Symbol so ProjectMetrics (which
      # rejects anything but instance_of?(Date) / the closed event-type Symbol set)
      # accepts them. Lossless w.r.t. the score.
      def deserialize_metrics(hash)
        Pulse::Domain::ProjectMetrics.new(
          project_id: hash['project_id'],
          reference_date: Date.iso8601(hash['reference_date']),
          effort_open: hash['effort_open'],
          effort_total: hash['effort_total'],
          risk_raw: hash['risk_raw'],
          blocked_count: hash['blocked_count'],
          risk_mapped: hash['risk_mapped'],
          effort_mapped: hash['effort_mapped'],
          event_series: Array(hash['event_series']).map do |e|
            { date: Date.iso8601(e['date']), type: e['type'].to_sym }
          end,
          version_due_dates: Array(hash['version_due_dates']).map do |v|
            { version_id: v['version_id'], name: v['name'], due_date: Date.iso8601(v['due_date']) }
          end,
          # C2 (FC-C2-08): coverage_gap inputs. PRE-C2 FALLBACK — a snapshot payload written
          # before C2 lacks these keys; default open_issue_count:0 / covered_sum:0.0 places
          # coverage_gap on the INACTIVE path so an old snapshot still deserializes and scores
          # identically on the default-OFF (5-signal) path. `fetch` with a default preserves an
          # explicit 0 while supplying the fallback only when the key is genuinely absent.
          open_issue_count: hash.fetch('open_issue_count', 0),
          covered_sum: (hash['covered_sum'].nil? ? 0.0 : hash['covered_sum'])
        )
      end
    end
  end
end
