# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/alert_rules'

module Pulse
  module Tasks
    # ScanAndAlert — the composition root for `rake redmine_pulse:scan_and_alert`.
    # It holds NO domain logic itself — it WIRES the pure
    # AlertRules domain to the alert-state store, the subscription store (permission-at-send),
    # and the email delivery adapter. Five steps per project:
    #   (1) compute the current canonical HealthResult (CanonicalScan);
    #   (2) read prior alert-state (ActiveRecordAlertStateStore.find_by_project — nil/all-nil
    #       on first run => baseline, nothing fires);
    #   (3) AlertRules.evaluate(prior, health, N) -> [AlertEvent];
    #   (4) per event: resolve recipients via RedmineSubscriptionStore.subscribers_for
    #       (the permission re-check happens THERE, at send) then RedmineAlertDelivery.deliver
    #       (best-effort, per-recipient rescue+log — never raises out);
    #   (5) upsert PulseAlertState AFTER evaluation, ONCE, regardless of delivery outcome
    #       (state advances even on a partial delivery failure; a re-run with
    #       unchanged health then emits nothing).
    #
    # Reachable ONLY from lib/tasks/pulse.rake — never on a request cycle (additive to the request path).
    module ScanAndAlert
      module_function

      # run(project_ids: nil, force_rag: nil) -> Array<AlertEvent> (all events across the
      # scanned projects; [] when nothing transitioned). force_rag is a deterministic-
      # transition test seam (see CanonicalScan#current_health).
      def run(project_ids: nil, force_rag: nil)
        viewer = Pulse::Tasks::CanonicalScan.canonical_viewer
        engine = Pulse::Tasks::CanonicalScan.canonical_engine
        ids = Pulse::Tasks::CanonicalScan.target_project_ids(project_ids)

        state_store   = Pulse::Adapters::ActiveRecordAlertStateStore.new
        subscriptions = Pulse::Adapters::RedmineSubscriptionStore.new
        delivery      = Pulse::Adapters::RedmineAlertDelivery.new
        threshold     = score_delta_threshold
        occurred_at   = Time.now.utc

        all_events = []
        ids.each do |pid|
          project = Project.find_by(id: pid)
          next if project.nil?

          # Fire-once-per-transition under overlapping cron: the whole
          # read->evaluate->deliver->advance section is SINGLE-WRITER per project. Without this
          # serialization two concurrent scan_and_alert runs could both read the SAME prior
          # state, both deliver the SAME transition, and both advance — duplicate emails for one
          # transition. with_project_lock takes a Postgres transaction-scoped ADVISORY LOCK keyed
          # by project_id: the second overlapping run BLOCKS until the first commits its
          # advance_state, then reads the already-advanced state and emits nothing.
          events = with_project_lock(project.id) do
            scan_project(
              project, state_store: state_store, subscriptions: subscriptions,
              delivery: delivery, viewer: viewer, engine: engine, threshold: threshold,
              occurred_at: occurred_at, force_rag: force_rag
            )
          end

          all_events.concat(events)
        end
        all_events
      end

      # The per-project critical section (steps 2-5), run UNDER with_project_lock so it is
      # single-writer against overlapping scans. Returns the events this run emitted.
      def scan_project(project, state_store:, subscriptions:, delivery:, viewer:, engine:,
                       threshold:, occurred_at:, force_rag:)
        prior = state_store.find_by_project(project.id)
        health = Pulse::Tasks::CanonicalScan.current_health(
          viewer, engine, project, prior: prior, force_rag: force_rag
        )

        events = Pulse::Domain::AlertRules.evaluate(
          prior, health, score_delta_threshold: threshold, occurred_at: occurred_at
        )

        # (4) deliver each event to the permission-filtered recipient set.
        unless events.empty?
          recipients = subscriptions.subscribers_for(project.id)
          events.each { |event| delivery.deliver(event, recipients) }

          # (4b) ADDITIVE outbound-webhook dispatch on the SAME event stream, AFTER the
          # email path. Best-effort: the dispatcher dead-letters every failure and never
          # raises out, so advance_state (5) still runs regardless of webhook outcome.
          # `previous` is the prior alert-state row. When no endpoint is
          # configured for this project the dispatcher's endpoint list is empty and its
          # per-endpoint loop never runs — ZERO outbound HTTP (the OFF-by-default short-circuit).
          dispatch_webhooks(project, health, events, prior)
        end

        # (5) advance the alert-state AFTER evaluation, once, regardless of delivery
        #     outcome. Even a first-run baseline (no events) writes the row so
        #     the NEXT scan has a prior to compare against (no first-cron flood).
        advance_state(state_store, project.id, health)

        events
      end

      # Run the block holding a Postgres transaction-scoped ADVISORY LOCK keyed by project_id.
      # pg_advisory_xact_lock(classid, objid) auto-releases
      # when the surrounding transaction commits/rolls back — no explicit unlock, no leak on a
      # crashed process. It requires NO state row to exist (correct on the FIRST run) and adds NO
      # schema (reversible). LOCK_NAMESPACE is a stable, plugin-private classid keeping our keyspace
      # disjoint from any other advisory-lock user in the same database. On a non-Postgres adapter
      # (dev SQLite, etc.) there is no advisory-lock primitive — we degrade to a plain yield; the
      # single-writer guarantee is asserted on the Postgres harness (the production DB shape).
      LOCK_NAMESPACE = 0x70756c73 # 'puls' — a stable per-plugin advisory-lock classid.

      def with_project_lock(project_id)
        conn = ActiveRecord::Base.connection
        return yield unless conn.adapter_name =~ /postgres/i

        conn.transaction(requires_new: true) do
          conn.execute(
            "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(project_id)})"
          )
          yield
        end
      end

      # Dispatch each event to the operator-configured webhook endpoints for this project
      # (global + per-project), best-effort. The dispatcher owns HTTPS/SSRF/HMAC/retry/dead-letter
      # and never raises out, so this call cannot abort the scan or gate advance_state.
      # `previous` (the prior health snapshot for the payload) is derived from the prior
      # alert-state row: {rag: last_rag, dominant_signal: last_dominant}, or nil on first
      # observation / an all-nil prior row.
      def dispatch_webhooks(project, health, events, prior)
        endpoints = webhook_endpoints_for(project.id)
        return if endpoints.empty? # OFF-by-default: nothing configured => zero outbound HTTP

        dispatcher = Pulse::Adapters::HttpWebhookDispatcher.new(endpoints: endpoints)
        previous = previous_snapshot(prior)
        events.each do |event|
          dispatcher.dispatch(event, project: project, health_result: health, previous: previous)
        end
      rescue StandardError
        # Defense-in-depth: the dispatcher is already best-effort, but a construction-time
        # failure (e.g. a malformed settings value) must STILL not propagate into the scan.
        nil
      end

      # Resolve the endpoint list for a project: the global endpoints plus this project's
      # per-project endpoints. Reads the (sanitized-at-write) plugin settings; tolerant of a
      # nil/absent key (OFF => []). Per-project keys are string-keyed by project id.
      def webhook_endpoints_for(project_id)
        settings = plugin_settings
        global = Array(settings['pulse_webhook_endpoints_global'])
        per_project_map = settings['pulse_webhook_endpoints_per_project']
        per_project = per_project_map.is_a?(Hash) ? Array(per_project_map[project_id.to_s]) : []
        (global + per_project).select { |ep| ep.is_a?(Hash) }
      end

      # Build the payload `previous` snapshot from the prior alert-state row. nil (=> null in the
      # payload) on first observation or an all-nil prior row (matches AlertRules.first_run?).
      def previous_snapshot(prior)
        return nil if prior.nil?

        rag = prior[:last_rag]
        dominant = prior[:last_dominant]
        return nil if rag.nil? && dominant.nil?

        { rag: rag, dominant_signal: dominant }
      end

      # Persist the just-evaluated canonical health as the new prior (idempotent upsert).
      def advance_state(state_store, project_id, health)
        no_data = health.rag == Pulse::Domain::AlertRules::NO_DATA
        state_store.upsert(
          project_id,
          last_rag: health.rag.to_s,
          last_dominant: health.dominant_signal&.to_s,
          last_no_data: no_data,
          last_score: health.health_score
        )
      end

      # The canonical/global score_delta threshold N (Numeric|nil; nil/0 = disabled DEFAULT).
      def score_delta_threshold
        raw = plugin_settings['pulse_alert_score_delta_threshold']
        return nil if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)

        n = raw.is_a?(Numeric) ? raw : (Float(raw, exception: false))
        return nil if n.nil? || !n.finite? || n <= 0

        n
      end

      def plugin_settings
        s = Setting.plugin_redmine_pulse
        s.is_a?(Hash) ? s : {}
      end
    end
  end
end
