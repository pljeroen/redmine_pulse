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
    # ScanAndAlert — the composition root for `rake redmine_pulse:scan_and_alert` (C6 /
    # FR-C6-02 / FC-C6-15 / OI-C6-01). It holds NO domain logic itself — it WIRES the pure
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
    #       (OI-C6-01 — state advances even on a partial delivery failure; a re-run with
    #       unchanged health then emits nothing).
    #
    # Reachable ONLY from lib/tasks/pulse.rake — never on a request cycle (INV-ADDITIVE).
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

            # (4b) C7 — ADDITIVE outbound-webhook dispatch on the SAME event stream, AFTER the
            # C6 email path. Best-effort: the dispatcher dead-letters every failure and never
            # raises out, so advance_state (5) still runs regardless of webhook outcome (GR-05 /
            # OI-C6-01). `previous` is the prior alert-state row (GR-03). When no endpoint is
            # configured for this project the dispatcher's endpoint list is empty and its
            # per-endpoint loop never runs — ZERO outbound HTTP (the OFF-by-default short-circuit).
            dispatch_webhooks(project, health, events, prior)
          end

          # (5) advance the alert-state AFTER evaluation, once, regardless of delivery
          #     outcome (OI-C6-01). Even a first-run baseline (no events) writes the row so
          #     the NEXT scan has a prior to compare against (no first-cron flood).
          advance_state(state_store, project.id, health)

          all_events.concat(events)
        end
        all_events
      end

      # C7 — dispatch each event to the operator-configured webhook endpoints for this project
      # (global + per-project), best-effort. The dispatcher owns HTTPS/SSRF/HMAC/retry/dead-letter
      # and never raises out, so this call cannot abort the scan or gate advance_state (GR-05).
      # `previous` (the prior health snapshot for the payload) is derived from the prior
      # alert-state row: {rag: last_rag, dominant_signal: last_dominant}, or nil on first
      # observation / an all-nil prior row (GR-03).
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
