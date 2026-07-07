# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # RedmineAlertDelivery — the AlertDelivery port over Pulse::Mailer.
    # v1 is EMAIL-ONLY: it dispatches one Pulse::Mailer.health_alert(user, event) per
    # recipient via deliver_now.
    #
    # BEST-EFFORT per recipient: a per-recipient mailer failure is RESCUED +
    # LOGGED (Rails.logger.error) and MUST NOT propagate out — so one failing recipient
    # never aborts the remaining deliveries NOR the scan_and_alert run, and the alert-state
    # still advances afterwards. The recipient set passed in is ALREADY permission-filtered
    # by RedmineSubscriptionStore (the permission gate does NOT live here).
    #
    # Reachable ONLY from the scan_and_alert composition root — never on a request cycle.
    class RedmineAlertDelivery
      # deliver(alert_event, recipients) -> void. Never raises out.
      def deliver(alert_event, recipients)
        Array(recipients).each do |recipient|
          begin
            Pulse::Mailer.health_alert(recipient, alert_event).deliver_now
          rescue StandardError => e
            log_failure(recipient, alert_event, e)
          end
        end
        nil
      end

      private

      # Best-effort structured log of a per-recipient delivery failure. A logger that is
      # absent or itself raises must NEVER mask the swallow (the caller keeps going).
      def log_failure(recipient, alert_event, error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        login = recipient.respond_to?(:login) ? recipient.login : recipient.inspect
        Rails.logger.error(
          "[redmine_pulse] alert delivery failed for user=#{login} " \
          "project_id=#{alert_event.project_id} event=#{alert_event.event_type}: " \
          "#{error.class}: #{error.message}"
        )
      rescue StandardError
        nil
      end
    end
  end
end
