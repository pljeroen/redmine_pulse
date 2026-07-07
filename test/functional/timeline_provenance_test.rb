# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'json'

# No invented dates: every date/datetime emitted in an API response carries a provenance
# tag from the CLOSED set {redmine_timestamp, version_due_date, computed, derived_bucket};
# no projected/estimated; retrospective bucket = midnight-UTC date-time; version due
# date = date-only; forward empty when no versions; the two date encodings are
# distinct. Verified end-to-end through the API projection.
#
# Runs on PostgreSQL 16 (the production engine).
class TimelineProvenanceApiTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  CLOSED_PROVENANCE = %w[redmine_timestamp version_due_date computed derived_bucket].freeze
  FORBIDDEN_PROVENANCE = %w[projected estimated forecast].freeze

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    # Runs on PostgreSQL (the production engine) — skip on non-Postgres adapters
    # (counted as skips, not failures) so the MySQL CI legs stay green; on Postgres the
    # guard never fires and the suite runs unchanged.
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'TlAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'tluser')
    @project = create_project!(name: 'Tl', identifier: 'tl-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  def api_key_header(user)
    token = user.api_token || Token.create!(user: user, action: 'api')
    { 'X-Redmine-API-Key' => token.value }
  end

  def get_project
    with_settings rest_api_enabled: '1' do
      get "/pulse/projects/#{@project.identifier}.json", headers: api_key_header(@user)
    end
  end

  # Walk the parsed JSON collecting every value under a "provenance" key.
  def collect_provenance(node, acc = [])
    case node
    when Hash
      node.each do |k, v|
        acc << v if k == 'provenance' && v.is_a?(String)
        collect_provenance(v, acc)
      end
    when Array
      node.each { |e| collect_provenance(e, acc) }
    end
    acc
  end

  def test_every_provenance_tag_is_in_the_closed_set
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    get_project
    assert_response :success
    tags = collect_provenance(JSON.parse(response.body)).uniq
    refute_empty tags, 'the payload must carry provenance-tagged dates'
    tags.each do |t|
      assert_includes CLOSED_PROVENANCE, t, "provenance #{t.inspect} not in the closed set"
    end
  end

  def test_no_projected_or_estimated_provenance_anywhere
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    get_project
    assert_response :success
    # No-invented-dates is about provenance VALUES, not raw substrings: the schema
    # REQUIRES the operational field name `projected_at` (when the per-request projection
    # ran), so a raw /projected/ scan over the body self-collides with a required key.
    # Scan the actual provenance values and assert none is in the forbidden class.
    tags = collect_provenance(JSON.parse(response.body)).uniq
    refute_empty tags, 'the payload must carry provenance-tagged dates'
    tags.each do |t|
      refute_includes FORBIDDEN_PROVENANCE, t,
                      "forbidden provenance class #{t.inspect} must not appear"
      assert_includes CLOSED_PROVENANCE, t, "provenance #{t.inspect} not in the closed set"
    end
  end

  def test_retrospective_midnight_utc_version_date_only
    create_version!(project: @project, name: 'v1.0', effective_date: Date.new(2026, 9, 30))
    get_project
    assert_response :success
    j = JSON.parse(response.body)

    j['timeline']['retrospective'].each do |b|
      %w[start end].each do |edge|
        assert_equal 'derived_bucket', b[edge]['provenance']
        assert_match(/^\d{4}-\d{2}-\d{2}T00:00:00Z$/, b[edge]['at'],
                     'retrospective bucket boundaries are midnight-UTC')
      end
    end

    j['timeline']['forward'].each do |mk|
      assert_equal 'version_due_date', mk['due_date']['provenance']
      assert_match(/^\d{4}-\d{2}-\d{2}$/, mk['due_date']['date'])
      refute_match(/T00:00:00Z/, mk['due_date']['date'],
                   'version due dates are date-only, NEVER midnight-UTC (MM-03)')
    end
  end

  def test_forward_axis_empty_without_versions
    get_project
    assert_response :success
    assert_equal [], JSON.parse(response.body)['timeline']['forward']
  end

  def test_operational_instants_carry_computed_provenance
    get_project
    assert_response :success
    j = JSON.parse(response.body)
    assert_equal 'computed', j['snapshot_computed_at']['provenance']
    assert_equal 'computed', j['projected_at']['provenance']
  end
end
