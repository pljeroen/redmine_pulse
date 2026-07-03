# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# H1 I18n sweep — RED guard for F1–F5 (badge JS hardcoded RAG words + aria prefix).
#
#   I18N-F1..F5  assets/javascripts/project_list_badge.js hardcodes 'Green'/'Amber'/
#                'Red'/'No data' and the aria prefix 'Health: '. The pure renderer must
#                NOT hold its own vocabulary; the SERVER must pass the localized RAG words
#                + an aria FORMAT string down through the inline blob (the existing data
#                channel), using the already-present label_pulse_rag_* keys, so the JS can
#                render localized labels with an English fallback.
#
# This is the SERVER half (the inline blob produced by RedminePulseHooks). It asserts the
# blob carries a "labels" object with the localized RAG words AND a health aria format
# string. It FAILS NOW (the hook emits only {"projects":[...]}, no "labels" object) and
# PASSES once A9 extends inline_blob with the server-localized labels.
#
# Postgres-only evidence lane (mirrors project_list_badge_hook_test).
class I18nBadgeLabelsBlobTest < ActionDispatch::IntegrationTest
  include PulseAdapterTestSupport

  BLOB_ID = 'pulse-portfolio-data'
  HEAD_HOOK = :view_layouts_base_html_head

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @role = create_role!(name: 'BadgeI18nAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse])
    @user = create_user!(login: 'badgei18nuser')
    @project = create_project!(name: 'BadgedI18n', identifier: 'badge-i18n-proj')
    add_member!(project: @project, principal: @user, role: @role)
    create_issue!(project: @project, author: @user, status: open_status,
                  created_on: Time.utc(2026, 6, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
  end

  # ── harness (mirrors project_list_badge_hook_test) ────────────────────────────

  def listener
    RedminePulseHooks.instance
  end

  def stub_controller(controller_name:, action_name:)
    Struct.new(:controller_name, :action_name).new(controller_name, action_name)
  end

  def hook_context(controller_name:, action_name:, project: nil)
    ctrl = stub_controller(controller_name: controller_name, action_name: action_name)
    { controller: ctrl, action_name: action_name, controller_name: controller_name,
      project: project, request: ActionDispatch::TestRequest.create, hook_caller: ctrl }
  end

  def emit_as(user, ctx)
    prior = User.current
    User.current = user
    listener.public_send(HEAD_HOOK, ctx).to_s
  ensure
    User.current = prior || User.anonymous
  end

  def blob_json(html)
    body = html[%r{<script[^>]*id="#{BLOB_ID}"[^>]*>(.*?)</script>}m, 1]
    refute_nil body, "emitted head must contain a <script id=\"#{BLOB_ID}\"> blob:\n#{html}"
    JSON.parse(body)
  end

  # ── I18N-F1..F4 : the blob carries a "labels" object with the localized RAG words ──

  def test_blob_carries_labels_object_with_localized_rag_words
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    data = blob_json(emit_as(@user, ctx))

    refute_nil data['labels'],
               'I18N-F1..F5: the inline blob MUST carry a "labels" object so the pure-' \
               'renderer JS can render LOCALIZED RAG words (the JS must not hold its own ' \
               'vocabulary). The hook emits only {"projects":[...]} today -> RED.'
    labels = data['labels']

    # The localized RAG words come from the EXISTING label_pulse_rag_* keys (no new key
    # work). The blob must carry each of green/amber/red/no_data so the JS replaces its
    # hardcoded 'Green'/'Amber'/'Red'/'No data' with the server-localized value.
    {
      'rag_green'   => I18n.t(:label_pulse_rag_green),
      'rag_amber'   => I18n.t(:label_pulse_rag_amber),
      'rag_red'     => I18n.t(:label_pulse_rag_red),
      'rag_no_data' => I18n.t(:label_pulse_rag_no_data)
    }.each do |key, expected|
      assert_equal expected, labels[key],
                   "I18N-F1..F4: blob labels.#{key} must be the localized RAG word " \
                   "#{expected.inspect} (from label_pulse_rag_*), so the JS need not hardcode it"
    end
  end

  # ── I18N-F5 : the blob carries a health ARIA FORMAT string (not a JS-side prefix) ──

  def test_blob_carries_health_aria_format_string
    ctx = hook_context(controller_name: 'projects', action_name: 'index')
    data = blob_json(emit_as(@user, ctx))
    labels = data['labels'] || {}

    # The badge JS today builds aria as 'Health: ' + word (a hardcoded English prefix that
    # cannot be word-order-inverted by translators). The server must instead pass a full
    # aria FORMAT string (with a %s/%{state} slot) derived from the existing
    # label_pulse_rag_aria_label key, so the JS formats a LOCALIZED accessible label.
    aria_format = labels['rag_aria_format'] || labels['rag_aria_prefix']
    refute_nil aria_format,
               'I18N-F5: the blob "labels" object MUST carry a health aria format string ' \
               '(rag_aria_format) so the JS can build a LOCALIZED accessible label instead ' \
               "of the hardcoded 'Health: ' prefix -> RED until A9 adds it"
    # A format string carries a substitution slot (the word is interpolated, word-order-
    # translatable) — a bare English 'Health: ' prefix does not satisfy this.
    assert_match(/%s|%\{?\w+\}?/, aria_format.to_s,
                 'I18N-F5: the aria format string must carry a substitution slot (%s / ' \
                 "%{state}) for the RAG word, not a fixed prefix. Got: #{aria_format.inspect}")
  end
end
