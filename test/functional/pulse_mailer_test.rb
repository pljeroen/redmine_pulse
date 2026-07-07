# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# Pulse::Mailer + RedmineAlertDelivery — email-only health alerts.
#
# Pulse::Mailer < Redmine's Mailer base (app/models/mailer.rb) — inherits SMTP /
# default_url_options / I18n from Redmine's existing config; introduces NO new SMTP
# settings, env vars, or delivery_method (low footprint). health_alert(user, event)
# renders HTML + text and delivers via ActionMailer. RedmineAlertDelivery#deliver
# dispatches per recipient, best-effort (per-recipient rescue+log), never raises out.
# The in-app channel is a deliberate deferral — email is the ONLY channel.
#
# Postgres-gated for parity.
class PulseMailerTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    ActionMailer::Base.deliveries.clear
    @project = create_project!(name: 'MailP', identifier: 'mail-p')
    @user = create_user!(login: 'mail_u')
  end

  def event
    Pulse::Domain::AlertEvent.new(
      project_id: @project.id, event_type: :rag_transition,
      from: 'green', to: 'amber', score: 55.0, previous_score: 80.0, delta: -25.0,
      occurred_at: Time.utc(2026, 7, 6, 9, 0, 0)
    )
  end

  # ── Pulse::Mailer inherits the Redmine Mailer base ────────────────
  def test_pulse_mailer_inherits_redmine_mailer_base
    assert defined?(Pulse::Mailer), 'Pulse::Mailer must be defined'
    assert_includes Pulse::Mailer.ancestors, Mailer,
                    'Pulse::Mailer < Redmine Mailer base (inherits SMTP / URL / I18n config)'
  end

  # ── no new SMTP config / delivery_method introduced ───────────────
  def test_no_new_smtp_config_in_manifests
    plugin_root = File.expand_path('../../..', File.expand_path(__FILE__))
    manifests = Dir.glob(File.join(plugin_root, '{Gemfile,*.gemspec,init.rb}'))
    offenders = []
    manifests.each do |f|
      body = File.read(f)
      %w[smtp_settings delivery_method smtp_address].each do |k|
        offenders << "#{File.basename(f)} sets #{k}" if body.include?(k)
      end
    end
    assert_equal [], offenders, "Pulse must introduce NO new SMTP config: #{offenders.inspect}"
  end

  # ── health_alert renders + delivers an email to the recipient ─────
  def test_health_alert_delivers_email_to_user
    assert_difference 'ActionMailer::Base.deliveries.size', +1 do
      Pulse::Mailer.health_alert(@user, event).deliver_now
    end
    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.to, @user.mail, 'the alert email is addressed to the recipient'
    refute_empty mail.subject.to_s, 'the alert email has a subject'
  end

  def test_health_alert_renders_html_and_text_parts
    Pulse::Mailer.health_alert(@user, event).deliver_now
    mail = ActionMailer::Base.deliveries.last
    body = mail.body.to_s
    refute_empty body, 'health_alert renders a non-empty body (HTML + text views)'
  end

  # ── RedmineAlertDelivery dispatches per recipient, email-only ──────
  def test_delivery_dispatches_email_per_recipient
    u2 = create_user!(login: 'mail_u2')
    delivery = Pulse::Adapters::RedmineAlertDelivery.new
    assert_difference 'ActionMailer::Base.deliveries.size', +2 do
      delivery.deliver(event, [@user, u2])
    end
    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_includes recipients, @user.mail
    assert_includes recipients, u2.mail
  end

  # ── deliver never raises out — a failing recipient is logged only ──
  def test_deliver_never_raises_out_on_recipient_failure
    delivery = Pulse::Adapters::RedmineAlertDelivery.new
    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |m| logged << m.to_s }
    %i[info warn debug].each { |m| fake_logger.define_singleton_method(m) { |*| } }

    Pulse::Mailer.stub(:health_alert, ->(_user, _event) { raise 'boom' }) do
      Rails.stub(:logger, fake_logger) do
        assert_nothing_raised { delivery.deliver(event, [@user]) }
      end
    end
    refute_empty logged, 'a per-recipient failure is logged, not propagated (best-effort)'
  end
end
