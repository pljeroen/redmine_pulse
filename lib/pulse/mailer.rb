# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  # Pulse::Mailer — the EMAIL-ONLY health-alert mailer.
  #
  # It INHERITS Redmine's own Mailer base (app/models/mailer.rb), so it reuses the existing
  # SMTP configuration, delivery_method, default_url_options, layout, and I18n locale
  # handling — it introduces NO new SMTP settings, env vars, or delivery_method
  # (low-footprint: it adds no new infrastructure). The Redmine base's #process requires the first action
  # argument to be a User (the recipient), which health_alert(user, event) satisfies; the
  # base then sets User.current + the recipient's language for the render.
  #
  # Lives at lib/pulse/mailer.rb — its path matches the namespaced constant Pulse::Mailer, so
  # it is Zeitwerk eager-load-safe in production without an ignore (unlike the top-level
  # hooks). Its HTML + text views live at app/views/pulse/mailer/, resolved via the plugin's
  # view path. Reachable ONLY from RedmineAlertDelivery under the scan_and_alert rake task —
  # never on a request-cycle path (additive to the request path).
  class Mailer < ::Mailer
    # Render + return an ActionMailer::MessageDelivery for one alert to one recipient. The
    # caller invokes .deliver_now (RedmineAlertDelivery does so per recipient, best-effort).
    #
    # The message is a SINGLE-PART text/html email whose body is the rendered
    # app/views/pulse/mailer/health_alert.html.erb view. Single-part is deliberate: a
    # multipart/alternative container's own #body.to_s is empty (the content lives in
    # #parts), whereas a single-part message exposes its rendered content directly on
    # #body — the readable, testable, universally-rendered surface. The sibling
    # health_alert.text.erb is retained for a future plain-text/multipart delivery mode; v1
    # ships the single-part HTML body (EMAIL-ONLY, no new SMTP config).
    def health_alert(user, event)
      @user = user
      @event = event
      @project = Project.find_by(id: event.project_id)
      @project_name = @project&.name || "##{event.project_id}"

      html = render_to_string(template: 'pulse/mailer/health_alert', formats: [:html])
      mail(to: user, subject: alert_subject(event)) do |format|
        format.html { render(html: html.html_safe) }
      end
    end

    private

    # A localized subject describing the transition, with a plain-English fallback so the
    # subject is ALWAYS non-empty even without the locale key present.
    def alert_subject(event)
      kind = I18n.t("label_pulse_alert_event_#{event.event_type}",
                    default: event.event_type.to_s.tr('_', ' '))
      title = Setting.respond_to?(:app_title) ? Setting.app_title : 'Redmine'
      "[#{title}] #{I18n.t(:label_pulse_health_alert, default: 'Pulse health alert')}: " \
        "#{@project_name} — #{kind}"
    end
  end
end
