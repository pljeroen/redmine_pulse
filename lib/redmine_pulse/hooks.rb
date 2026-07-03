# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# RedminePulseHooks — the project-list-badge view hook (B2 server-inline, D-PLB-C04).
#
# On view_layouts_base_html_head it runs SERVER-SIDE with User.current = the session
# user (so it is naturally viewer-scoped) and, ONLY on projects#index for a user with
# global :view_pulse, emits THREE things gated together (INV-GATE):
#   1. the redmine_pulse stylesheet <link> (the RAG-chip CSS, reused verbatim),
#   2. the project_list_badge JS asset <script> tag, and
#   3. an inlined <script type="application/json" id="pulse-portfolio-data"> blob = the
#      viewer-scoped portfolio (minimal per-project {identifier, rag, main_concern}),
#      built from engine.portfolio_projections(User.current) via the shared label module.
#
# The browser JS reads the blob via JSON.parse(textContent) and decorates the project
# rows — NO fetch / NO network request for badge data (INV-NO-EXTERNAL): Redmine 6.1.2
# bypasses session auth for .json, so a browser fetch could not authenticate. The blob is
# escaped with ERB::Util.json_escape so a hostile project name cannot break out of the
# <script> element (INV-INLINE-XSS). The whole computation is wrapped in begin/rescue and
# returns '' on ANY error so /projects always renders (INV-FAILSILENT). It performs NO
# Redmine domain write — it only reads the (possibly cached) portfolio (INV-READONLY).
class RedminePulseHooks < Redmine::Hook::ViewListener
  BLOB_ID = 'pulse-portfolio-data'

  def view_layouts_base_html_head(context = {})
    controller = context[:controller]
    return '' unless on_projects_index?(controller, context)
    return '' unless User.current.allowed_to?(:view_pulse, nil, global: true)

    rows = badge_rows
    return '' if rows.nil?

    assets = stylesheet_link_tag('redmine_pulse', plugin: 'redmine_pulse') +
             javascript_include_tag('project_list_badge', plugin: 'redmine_pulse')
    # Return a plain String (not a SafeBuffer): Redmine's call_hook re-marks the joined
    # head fragment html_safe, and a plain String makes the emitted blob extractable by a
    # standard String#[] regex (SafeBuffer#[] does not reliably set $~ at runtime).
    (assets + inline_blob(rows)).to_str
  rescue StandardError => e
    # INV-FAILSILENT (server layer): any error -> emit nothing, /projects still renders.
    Rails.logger.error("[redmine_pulse] project-list-badge hook failed: #{e.class}: #{e.message}") if defined?(Rails)
    ''
  end

  private

  # Gate (route): ONLY projects#index. Reads controller_name/action_name off the
  # controller (the Redmine call_hook default_context), falling back to the context
  # keys the test harness provides.
  def on_projects_index?(controller, context)
    cname = (controller&.controller_name if controller.respond_to?(:controller_name)) || context[:controller_name]
    aname = (controller&.action_name if controller.respond_to?(:action_name)) || context[:action_name]
    cname.to_s == 'projects' && aname.to_s == 'index'
  end

  # Build the minimal viewer-scoped badge rows [{identifier, rag, main_concern}] from the
  # engine's portfolio projections. main_concern comes from the SHARED authoritative label
  # module (FR-PLB-15) so the badge label can never drift from the cockpit / API.
  def badge_rows
    pulse_engine.portfolio_projections(User.current).map do |projection|
      h = projection.health
      {
        'identifier' => projection.project.identifier,
        'name' => projection.project.name,
        'rag' => h.rag.to_s,
        'main_concern' => Pulse::Adapters::MainConcernLabels.label(h.dominant_signal)
      }
    end
  end

  # The inlined data blob: ERB::Util.json_escape escapes < > & to \uXXXX so a project name
  # containing '</script>' (or '<!--', '<![CDATA[') CANNOT terminate the <script> element
  # early or inject markup (INV-INLINE-XSS). The escaped body is pure-ASCII safe, so it is
  # marked html_safe to keep content_tag from re-escaping the \uXXXX sequences.
  def inline_blob(rows)
    body = json_escape({ 'projects' => rows, 'labels' => blob_labels }.to_json).html_safe # rubocop:disable Rails/OutputSafety
    # Attribute order id-then-type is asserted by the contract test regex; content_tag
    # preserves the option-hash insertion order, so emit id: before type:.
    content_tag(:script, body, id: BLOB_ID, type: 'application/json')
  end

  # Server-localized label channel for the pure-renderer JS (I18N-F1..F5). The renderer
  # holds NO RAG vocabulary of its own; it reads these server-localized words + the aria
  # FORMAT string (with a %{state} slot) so translators control wording and word order.
  def blob_labels
    {
      'rag_green' => I18n.t(:label_pulse_rag_green),
      'rag_amber' => I18n.t(:label_pulse_rag_amber),
      'rag_red' => I18n.t(:label_pulse_rag_red),
      'rag_no_data' => I18n.t(:label_pulse_rag_no_data),
      'rag_aria_format' => I18n.t(:label_pulse_rag_aria_label)
    }
  end

  # Per-request engine, wired with the SAME adapter composition the controllers
  # (PulseBaseController) use — read-only; no domain write.
  def pulse_engine
    settings_provider = Pulse::Adapters::RedmineSettingsProvider.new
    clock = Pulse::Adapters::SystemClock.new
    Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: Pulse::Adapters::RedmineMetricsSource.new(
        settings_provider: settings_provider, clock: clock
      ),
      store: Pulse::Adapters::ActiveRecordSnapshotStore.new,
      settings_provider: settings_provider,
      clock: clock
    )
  end
end
