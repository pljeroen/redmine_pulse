# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# EXPLAINABILITY PASSTHROUGH. The wiring layer emits the
# per-signal breakdown (active, raw_value, n, effective_weight, contribution) EXACTLY
# as the domain HealthResult produced it — no recompute, no re-round. The rendered
# payload must satisfy round_half_up(Σ active contributions) == health_score even
# after the serialize/deserialize round-trip. Guards against the round-trip
# silently corrupting the explainability invariant.
#
# Runs on PostgreSQL.
class ExplainabilityPassthroughTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # runs on PostgreSQL (the production engine) — skip on non-Postgres adapters
    # (counted as skips, not failures) so the other CI legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'ExpAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'expuser')
    @project = create_project!(name: 'Exp', identifier: 'exp-proj')
    add_member!(project: @project, principal: @user, role: @role)
    # A mix of open/closed issues so several signals are active and non-trivial.
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    closed = create_issue!(project: @project, author: @user, status: open_status,
                           created_on: Time.utc(2026, 6, 2, 0))
    add_close_journal!(issue: closed, user: @user, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 6, 12, 0))
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def project_json
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@project.identifier}.json", headers: api_key_header(@user)
    end
    JSON.parse(response.body)
  end

  def round_half_up(x)
    (x + 0.5).floor
  end

  def test_active_contributions_sum_to_health_score_in_rendered_payload
    j = project_json
    assert_response :success
    active = j['signals'].values.select { |s| s['active'] }
    sum = active.sum { |s| s['contribution'].to_f }
    assert_equal j['health_score'], round_half_up(sum),
                 'round_half_up(Σ active contributions) == health_score must hold in the payload'
  end

  def test_rendered_contributions_equal_domain_health_result
    # Compute the domain HealthResult directly over the same metrics and compare the
    # emitted breakdown field-by-field (no wiring recompute/round/alteration).
    clock = Pulse::Adapters::SystemClock.new
    config = real_settings_provider.scoring_config
    metrics = Pulse::Adapters::RedmineMetricsSource
              .new(settings_provider: real_settings_provider, clock: clock)
              .metrics_for(@user, project_ids: [@project.id]).first
    health = Pulse::Domain::Scoring.score(metrics, clock, config)

    j = project_json
    assert_response :success
    health.breakdown.each do |sig|
      rendered = j['signals'][sig.key.to_s]
      assert_equal sig.active, rendered['active'], "signal #{sig.key} active mismatch"
      if sig.active
        assert_in_delta sig.contribution, rendered['contribution'].to_f, 1e-6,
                        "signal #{sig.key} contribution must be emitted verbatim"
        assert_in_delta sig.effective_weight, rendered['effective_weight'].to_f, 1e-6
      else
        assert_nil rendered['contribution']
        assert_nil rendered['effective_weight']
      end
    end
    assert_equal health.health_score, j['health_score']
  end

  def test_weights_effective_equals_domain_effective_weights
    clock = Pulse::Adapters::SystemClock.new
    config = real_settings_provider.scoring_config
    metrics = Pulse::Adapters::RedmineMetricsSource
              .new(settings_provider: real_settings_provider, clock: clock)
              .metrics_for(@user, project_ids: [@project.id]).first
    health = Pulse::Domain::Scoring.score(metrics, clock, config)

    j = project_json
    assert_response :success
    domain_eff = health.breakdown.select(&:active)
                       .to_h { |s| [s.key.to_s, s.effective_weight] }
    assert_equal domain_eff.keys.sort, j['weights_effective'].keys.sort,
                 'weights_effective contains exactly the active signal keys'
    domain_eff.each do |k, v|
      assert_in_delta v, j['weights_effective'][k].to_f, 1e-6, "effective weight #{k} mismatch"
    end
  end
end
