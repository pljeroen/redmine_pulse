# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

#
# This file is the plugin MANIFEST: declarative registration + tunable setting
# defaults. The behavioural code (the pure-Ruby scoring engine under
# lib/pulse/domain, the Redmine adapters, the HTML/JSON controllers) is wired up
# below. Menu items, the permission, and the settings partial are registered
# together with the controllers/views that satisfy them, so the plugin never
# advertises a route or partial that 404s.

Redmine::Plugin.register :redmine_pulse do
  name        'Redmine Pulse'
  author      'Jeroen'
  description 'Portfolio / project-health cockpit: composite health scoring, ' \
              'prioritization lenses, and a read API — computed from real ' \
              'Redmine data. No invented dates; read-only; permission-safe.'
  version     '0.1.0'
  url         'https://github.com/pljeroen/redmine_pulse'
  author_url  'https://github.com/pljeroen'

  requires_redmine version_or_higher: '6.1.0'

  # Tunable scoring configuration.
  # Community-sane defaults. Empty enrichment mappings mean the
  # corresponding signal is omitted and its weight redistributed (graceful
  # degradation) — never faked.
  settings default: {
    'rag_green_min'        => 67,   # RAG green threshold
    'rag_amber_min'        => 34,   # RAG amber threshold (below => red)
    'h_stale'              => 180,  # staleness horizon (days)
    'h_risk'               => 50,   # risk horizon
    'h_blocked'            => 20,   # blocked horizon
    'activity_window_days' => 30,   # trailing window for momentum/recompute
    'momentum_activity_half'  => 8.0,  # activity count read as neutral momentum (0.5)
    'momentum_direction_bias' => 0.15, # net open/close direction nudge, capped at ±this
    'on_track_threshold'      => 0.5,  # worst-signal n at/above which main concern = on-track
    'snapshot_max_age_minutes' => 60,  # cache freshness cap (minutes); 0 = disabled
    'weights'              => {},   # per-signal weight overrides; empty => engine defaults
    'effort_field'         => '',   # optional effort/story-points field mapping
    'risk_trackers'        => [],   # optional risk-tracker mapping
    'blocked_status'       => '',   # optional blocked-status mapping
    # alerting: two alert-OFF defaults so NO alert fires on
    # install until the operator configures them. Both are consumed ONLY by the rake-task
    # composition root (never the request cycle). nil = disabled (auto-subscribe off /
    # score_delta off).
    'pulse_alert_auto_subscribe_role_id' => nil, # Redmine role id to auto-subscribe (nil = off)
    'pulse_alert_score_delta_threshold'  => nil, # min |Δscore| to fire score_delta (nil/0 = off)
    # webhooks: two OFF-by-default webhook-endpoint keys so NO
    # outbound HTTP fires on install until the operator configures a destination. Both are
    # consumed ONLY by the rake-task composition root (scan_and_alert) + the admin test-event
    # action — NEVER the scoring request cycle (additive). An empty list is the shipped
    # state; the dispatcher's per-endpoint loop then never runs (structural short-circuit).
    'pulse_webhook_endpoints_global'      => [], # Array<EndpointConfig>; [] = off (no endpoints)
    'pulse_webhook_endpoints_per_project' => {}  # Hash<project_id, Array<EndpointConfig>>; {} = off
    # deliverables_field is REMOVED — it was a deferred feature
    # that never shipped, so the manifest must not advertise it (the settings partial
    # exposes only the shipped field set).
  }, partial: 'settings/pulse_settings'

  # the pulse project module gates the :view_pulse permission
  # over EXACTLY the controller actions { pulse: [index,show,refresh],
  # pulse_api: [portfolio,project] }, read-only. Registered here (with the
  # controllers/views that satisfy it) so the plugin never advertises a route or
  # partial that 404s.
  project_module :pulse do
    # :view_pulse EXPANDS additively to cover the pulse#watch/#unwatch
    # health-watch toggle actions. These are member write-actions on the viewer's OWN
    # subscription (a Watcher row), not a Redmine-domain write — read:true is retained
    # because the permission still gates read visibility; the per-action authorize ladder
    # enforces :view_pulse at request time, and the scan re-checks permission at send.
    permission :view_pulse,
               { pulse: %i[index show refresh watch unwatch], pulse_api: %i[portfolio project],
                 pulse_views: %i[index new create show edit update destroy select] },
               read: true
    # publishing public/role-scoped saved views is portfolio-wide config — a GLOBAL
    # permission (global: true), NOT per-project. The check everywhere is
    # User.current.allowed_to?(:manage_public_pulse_views, nil, global: true). A holder on an
    # unrelated project ONLY does not satisfy the global check (global-semantics falsifier).
    permission :manage_public_pulse_views,
               { pulse_views: %i[create update destroy] },
               require: :loggedin,
               global: true
  end

  # a project-menu tab -> pulse#show, gated on the pulse module being enabled
  # (the permission is enforced per-action by the controller's authorize ladder).
  menu :project_menu, :pulse,
       { controller: 'pulse', action: 'show' },
       caption: :label_pulse,
       param: :id,
       if: proc { |project| project.module_enabled?(:pulse) }

  # R-F: a global top-menu link to the portfolio overview (/pulse -> pulse#index),
  # shown only to users who can view Pulse somewhere. Without this the portfolio is
  # reachable only by typing the URL (discoverability gap; the per-project tab above
  # only covers the single-project panel). String URL keeps it independent of the
  # project-scoped route helpers.
  # NOTE: this :if gate is INTENTIONALLY stricter than pulse#index. The index action
  # has no authorize gate -- it self-scopes to visible projects and renders a 200
  # empty-state for users with no visible Pulse projects (the never-403 portfolio
  # guarantee). So this condition controls link VISIBILITY only and must NOT be used
  # to justify adding an authorize gate to index, which would break that guarantee.
  menu :top_menu, :pulse, '/pulse',
       caption: :label_pulse,
       if: proc { User.current.allowed_to?(:view_pulse, nil, global: true) }
end

# Load the pure-Ruby domain + the Redmine ports/adapters. The domain layer is
# stdlib-only (no Rails/AR); the adapters bridge it to Redmine's models
# (read-only). The plugin's lib/ dir is put on $LOAD_PATH so the domain's internal
# `require 'pulse/...'` lines resolve, then the public surface is required here.
pulse_lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(pulse_lib) unless $LOAD_PATH.include?(pulse_lib)

require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'
require 'pulse/domain/project_metrics'
require 'pulse/ports/clock'
require 'pulse/ports/metrics_source'
require 'pulse/ports/settings_provider'
require 'pulse/ports/profile_provider'
require 'pulse/adapters/system_clock'
require 'pulse/adapters/redmine_settings_provider'
require 'pulse/adapters/redmine_profile_provider'
require 'pulse/adapters/visibility_context'
require 'pulse/adapters/snapshot_fingerprint'
require 'pulse/adapters/redmine_metrics_source'

# Controllers + API: the SnapshotStore port (standard library only) + the AR-backed
# cache adapter, the settings sanitizer, the per-request projection engine, and the
# JSON serializer / lens ranker / HTML presenter the controllers (composition root)
# wire together. The PulseSnapshot AR model is defined at require time, so these load
# after Rails/ActiveRecord is available (init.rb runs post-boot).
require 'pulse/ports/snapshot_store'
require 'pulse/adapters/active_record_snapshot_store'
# saved-views: the ViewStore port (standard library only) + the pulse_views-backed adapter, in the
# established port->adapter order. The PulseView AR model + PulseViewsController are autoloaded
# by Rails from app/models / app/controllers (top-level constants, path-matched — no explicit
# require, consistent with PulseSnapshot / PulseController).
require 'pulse/ports/view_store'
require 'pulse/adapters/active_record_view_store'
require 'pulse/adapters/settings_sanitizer'
require 'pulse/adapters/pulse_projection'
# the SINGLE authoritative dominant_signal -> localized label mapping, reused
# by BOTH JsonSerializer and HtmlPresenter (DRY) — required BEFORE them so the constant
# is resolved when they delegate to it.
require 'pulse/adapters/main_concern_labels'
require 'pulse/adapters/json_serializer'
require 'pulse/adapters/lens_ranker'
require 'pulse/adapters/html_presenter'

# alerting: the pure alert domain + the alert ports/adapters + the two
# task composition roots. These are reachable ONLY from lib/tasks/pulse.rake (the
# scan_and_alert / recompute rake tasks) and the Watch-toggle controller action — NEVER
# from the scoring request cycle (additive; a no-coupling scan confirms the
# 7 alert symbols never appear under app/controllers, app/helpers, or served app/views).
# The alert-state is a SEPARATE table (pulse_alert_states) from the pulse_snapshots cache.
require 'pulse/domain/alert_event'
require 'pulse/domain/alert_rules'
require 'pulse/ports/alert_state_store'
require 'pulse/ports/subscription_store'
require 'pulse/ports/alert_delivery'
require 'pulse/adapters/active_record_alert_state_store'
require 'pulse/adapters/redmine_subscription_store'
require 'pulse/adapters/redmine_alert_delivery'
# Pulse::Mailer lives at lib/pulse/mailer.rb (path-matches its namespaced constant, so it
# is Zeitwerk eager-load-safe under production — no ignore needed, unlike the top-level
# hooks). It subclasses Redmine's ::Mailer base (loadable by plugin-init time). Its HTML +
# text views live at app/views/pulse/mailer/ (resolved via the plugin's view path).
require 'pulse/mailer'
# webhooks: the WebhookDispatcher port (standard library + domain only) + the three
# adapters (SSRF guard, payload serializer, HTTP dispatcher). Reachable ONLY from the
# scan_and_alert composition root + the admin test-event action — NEVER from the scoring
# request cycle (additive; a no-coupling scan confirms the webhook symbols appear on
# the request cycle solely in pulse_controller's test-event action). All outbound HTTP /
# DNS / HMAC lives in the adapters (Net::HTTP -> http_webhook_dispatcher; Resolv -> ssrf_guard).
require 'pulse/ports/webhook_dispatcher'
require 'pulse/adapters/ssrf_guard'
require 'pulse/adapters/webhook_payload_serializer'
require 'pulse/adapters/http_webhook_dispatcher'
require 'pulse/tasks/canonical_scan'
require 'pulse/tasks/recompute'
require 'pulse/tasks/scan_and_alert'

# project-list-badge (server-inline): the view hook that emits the
# RAG-chip stylesheet, the badge JS asset, and the inlined viewer-scoped portfolio blob on
# projects#index for a user with global :view_pulse. Required after the adapters it wires.
#
# Zeitwerk eager-load safety: Redmine 6.x puts each plugin's lib/ on
# Rails.autoloaders.main and EAGER-LOADS it in production. Zeitwerk derives the constant a
# file MUST define from its path, so it expects lib/redmine_pulse/hooks.rb to define
# `RedminePulse::Hooks`. This file deliberately defines the TOP-LEVEL `RedminePulseHooks`
# (the hook class the registration + the tests rely on), so the path/constant
# mismatch makes `Rails.application.eager_load!` raise `Zeitwerk::NameError`
# (uninitialized constant RedminePulse::Hooks) at production boot. We tell Zeitwerk to
# IGNORE this file (it is loaded classically by the explicit require just below, which
# defines RedminePulseHooks in ALL environments — eager_load is OFF in dev/test, so the
# require is what registers the view hook). The ignore must be in effect before
# eager_load! runs; registering it here (plugin init, before the autoloaders are set up
# for eager loading) is the correct timing. The lib/pulse/** tree is left autoloadable —
# it already path-matches its Pulse::... constants.
Rails.autoloaders.main.ignore(File.expand_path('lib/redmine_pulse/hooks.rb', __dir__))
require 'redmine_pulse/hooks'

# the admin settings POST persists via
# Redmine's SettingsController#plugin, which writes params[:settings] straight to
# Setting.plugin_redmine_pulse= and then UNCONDITIONALLY flashes
# l(:notice_successful_update) and redirects — there is no per-plugin validation hook
# (see Redmine 6.1.2 app/controllers/settings_controller.rb#plugin). To enforce the
# EXACT ScoringConfig bounds we (1) wrap that setter so an invalid scalar is
# REJECTED — the previously-persisted value is kept; the invalid input is never
# persisted — and (2) record the rejected keys in a per-thread slot so the controller
# can surface a user-facing, LOCALIZED rejection error instead of a silent success.
#
# The dynamic `plugin_redmine_pulse=` singleton method is defined by Redmine LATE in
# boot (Setting.load_plugin_settings, after every plugin's init.rb runs), so we
# prepend a module that calls `super` — `super` resolves the dynamic writer lazily at
# call time, not at prepend time. Idempotent.
PULSE_SETTINGS_REJECTION_SLOT = :pulse_settings_rejected_keys
if defined?(Setting) && !Setting.singleton_class.method_defined?(:pulse_sanitizing_writer_installed)
  Setting.singleton_class.prepend(Module.new do
    def plugin_redmine_pulse=(value)
      previous = begin
        plugin_redmine_pulse
      rescue StandardError
        {}
      end
      sanitized, errors = Pulse::Adapters::SettingsSanitizer.sanitize(value, previous.is_a?(Hash) ? previous : {})
      # Record the rejected field keys so SettingsController#plugin can surface a
      # localized flash[:error] (the sanitizer already dropped the invalid values back
      # to the prior valid ones, so `sanitized` carries NO out-of-bounds value).
      Thread.current[PULSE_SETTINGS_REJECTION_SLOT] = Array(errors).map(&:to_s).uniq
      super(sanitized)
    end

    def pulse_sanitizing_writer_installed
      true
    end
  end)
end

# surface the sanitizer's rejection as a user-facing, LOCALIZED error.
# Redmine's SettingsController#plugin flashes success unconditionally after calling the
# setter, so we add an after_action (scoped to :plugin, and only when THIS plugin's
# settings were the POST target) that reads the per-thread rejection slot and replaces
# the misleading success notice with flash[:error]. The invalid value is already not
# persisted (the setter kept the prior value); this closes the silent-success gap.
#
# We ALSO include PulseSettingsHelper so the settings partial can consume the prepared
# tracker option data (no AR access in the ERB view).
if defined?(SettingsController)
  unless SettingsController.method_defined?(:pulse_settings_rejection_guard_installed)
    # Expose PulseSettingsHelper to the SettingsController's VIEW chain. Redmine
    # renders the plugin settings partial in the ActionView context, NOT the
    # controller instance, so a bare `include` leaves `pulse_tracker_options`
    # undefined at render time (NameError -> 500). `SettingsController.helper`
    # registers the module on the controller's _helpers module so the method is
    # reachable from the partial. The plain `include` is also kept so the
    # after_action guard (controller scope) can call it if needed; `helper` is
    # the load-bearing fix for the settings-page 500 error.
    SettingsController.include(PulseSettingsHelper)
    SettingsController.helper(PulseSettingsHelper)
    SettingsController.prepend(Module.new do
      def pulse_settings_rejection_guard_installed
        true
      end
    end)

    SettingsController.after_action(only: :plugin) do
      if request.post? && params[:id].to_s == 'redmine_pulse'
        rejected = Thread.current[PULSE_SETTINGS_REJECTION_SLOT]
        if rejected.is_a?(Array) && rejected.any?
          fields = rejected.map { |k| I18n.t("label_pulse_#{k}", default: k.to_s.tr('_', ' ')) }
          # Replace the unconditional success notice with a localized rejection error so
          # the admin sees that the out-of-bounds value(s) were NOT applied.
          flash.delete(:notice)
          flash[:error] = I18n.t(:error_pulse_settings_rejected,
                                 fields: fields.join(', '),
                                 default: "Some Pulse settings were out of range and were not " \
                                          "saved (kept the previous value): %{fields}.")
        end
        Thread.current[PULSE_SETTINGS_REJECTION_SLOT] = nil
      end
    end
  end
end

# Test-environment scenario prerequisites (NOT production behaviour). The
# adapter test-support builders construct a Repository::Filesystem (needs the
# Filesystem SCM enabled) and a cross-project `blocks` relation (needs
# cross_project_issue_relations) to exercise cross-project blockers. Redmine's
# `db:test:prepare` purges the settings table to settings.yml defaults, which omit
# both, so we re-assert them at plugin load under the test env only. Guarded so it
# can never affect a real instance.
if defined?(Rails) && Rails.env.test?
  require 'active_support/test_case'

  # alerting — Minitest stubbing (test env ONLY). The mailer / task suites
  # (pulse_mailer_test, pulse_alert_tasks_test) exercise best-effort delivery via
  # Pulse::Mailer.stub / Rails.stub, but Redmine 6.1.2's test_helper does not require
  # minitest/mock, so Object#stub is otherwise undefined on the harness. Requiring it here
  # (guarded to the test env) makes those suites' stub calls resolve. Best-effort.
  begin
    require 'minitest/mock'
  rescue LoadError
    nil
  end

  # JSON-Schema draft-07 support (test env ONLY). The API schemas declare
  # "$schema": draft-07, but the bundled json-schema 6.2.0 ships validators only up to
  # draft-06 (it cannot resolve the draft-07 meta-schema URI). The features the
  # redmine_pulse schemas actually use (required, additionalProperties, const, enum,
  # pattern, $ref JSON-pointers into $defs, format) are all draft-06-compatible, so we
  # register a draft-07 validator that reuses the draft-06 attribute set under the
  # draft-07 URI. This lets the API-schema suite validate against the published
  # schemas without a gem upgrade. Best-effort; never affects a real instance.
  begin
    require 'json-schema'
    unless JSON::Validator.validators.key?('http://json-schema.org/draft-07/schema#')
      draft07 = Class.new(JSON::Schema::Draft6) do
        def initialize
          super
          @uri = JSON::Util::URI.parse('http://json-schema.org/draft-07/schema#')
          @names = ['draft7', 'http://json-schema.org/draft-07/schema#']
          @metaschema_name = 'draft-06.json'
        end
      end
      JSON::Validator.register_validator(draft07.new)
    end
  rescue LoadError, StandardError
    # json-schema not present / API shape differs — the API-schema suite will report.
  end

  # Test-assertion availability shims (test env ONLY; never affects a real instance).
  # The controller/API suites call two assertion helpers that this Redmine
  # 6.1.2 / Minitest build does not provide on ActiveSupport::TestCase out of the box:
  #   * assert_routing — needs ActionDispatch::Assertions::RoutingAssertions mixed in
  #     (+ @routes bound) for the route-recognition assertions in RegistrationTest.
  #   * assert_nothing_raised('message') — Minitest's #assert_nothing_raised takes no
  #     args; the suites pass an explanatory message. Provide a message-tolerant form.
  unless ActiveSupport::TestCase.include?(ActionDispatch::Assertions::RoutingAssertions)
    ActiveSupport::TestCase.include(ActionDispatch::Assertions::RoutingAssertions)
    ActiveSupport::TestCase.set_callback(:setup, :before) do
      @routes ||= Rails.application.routes
    end
  end

  unless ActiveSupport::TestCase.method_defined?(:pulse_assert_nothing_raised_installed)
    ActiveSupport::TestCase.prepend(Module.new do
      def assert_nothing_raised(*args)
        yield
        assert(true) # register an assertion so the test is not flagged "missing assertions"
      rescue Minitest::Assertion
        raise
      rescue StandardError => e
        prefix = args.empty? ? '' : "#{args.first}: "
        raise Minitest::Assertion, "#{prefix}#{e.class}: #{e.message}"
      end

      def pulse_assert_nothing_raised_installed
        true
      end
    end)
  end

  ActiveSupport::TestCase.set_callback(:setup, :before) do
    Setting.enabled_scm = (Setting.enabled_scm | ['Filesystem'])
    Setting.cross_project_issue_relations = '1'
    # Projects are private by default so a non-member genuinely cannot see another
    # project's issues (the cross-project hidden-blocker scenario).
    Setting.default_projects_public = '0'
    # Persist rest_api_enabled so the read-only API suites — which wrap the
    # GET in `with_settings rest_api_enabled: '1'` INSIDE the captured write block — see
    # an UNCHANGED setting (no INSERT/UPDATE on the settings table) rather than the
    # first-time row creation. The GET path itself performs no Redmine-domain writes;
    # this pre-seed keeps the with_settings save a no-op so the write-set is genuinely
    # empty. It does NOT affect the explicit rest_api_enabled '0'/'1'
    # toggling the access suites rely on (they save/restore their own value).
    Setting.rest_api_enabled = '1'
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
    # settings table not yet migrated/prepared.
  end
end
