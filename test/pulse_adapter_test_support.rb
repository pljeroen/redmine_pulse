# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Shared scenario-builder + helpers for the metrics-source functional /
# integration suites. Builds KNOWN-VALUE Redmine scenarios programmatically in
# setup (the standard Redmine plugin functional-test idiom) so every aggregate
# has a hand-computable expected value, independent of Redmine's shipped fixtures.
#
# This file defines NO assertions of its own; it is required by the suite files.
# It also registers the `pulse` project module + `:view_pulse` permission for the
# test environment, because init.rb deliberately defers that registration until
# the controllers are wired up (the adapter under test must still honour it).
module PulseAdapterTestSupport
  # ── Locale / User.current teardown reset ──────────────────────────────────
  # Registered via `included` so EVERY class that does `include PulseAdapterTestSupport`
  # gets a teardown that restores I18n.locale and User.current to their canonical defaults
  # after each test, regardless of run order.
  #
  # Rationale: Redmine runs tests in random order (config.active_support.test_order = :random).
  # I18nLensAndUnitsTest#test_pulse_renders_dutch_labels_for_nl_user sets I18n.locale = :nl
  # inside a request cycle without a post-test reset. Tests that call domain adapters directly
  # (e.g. HtmlPresenter.signal_rows) then see the leaked Dutch locale and fail on English
  # label assertions. Several functional tests also set User.current = user in a login_as
  # fallback without restoring User.anonymous. Both leaks are order-dependent and produce
  # intermittent failures that vanish on a fixed seed. This teardown is the canonical fix.
  #
  # Safety guards:
  #   - I18n check: only fires when I18n is defined and responds to #locale= (inert in bare-
  #     Ruby unit tests that do not load Redmine's I18n stack).
  #   - User check: only fires when User is defined and responds to .anonymous (inert in bare-
  #     Ruby unit tests where ActiveRecord is absent).
  #   - Both restore to default only; they do not suppress any test failure.
  def self.included(base)
    base.teardown do
      if defined?(I18n) && I18n.respond_to?(:locale=) &&
         defined?(I18n.default_locale) && I18n.locale != I18n.default_locale
        I18n.locale = I18n.default_locale
      end
      if defined?(User) && User.respond_to?(:current=) && User.respond_to?(:anonymous)
        User.current = User.anonymous
      end
    end
  end

  # Register the pulse module + view_pulse permission once, for the test env only.
  # The metrics-source suites reference these; init.rb registers them later with the
  # controllers. Re-registration is idempotent (guarded on AccessControl state).
  def self.ensure_pulse_permission!
    # init.rb registers the full permission surface (:view_pulse expanded to the
    # pulse_views actions + the GLOBAL :manage_public_pulse_views) at plugin load, before any
    # test runs on the harness — so this early-return normally fires and we never
    # double-register (AccessControl#permission does NOT dedupe; a re-map would duplicate the
    # entry). We only register from scratch if :view_pulse is entirely absent (a lane where
    # init.rb's registration did not run).
    return if Redmine::AccessControl.permissions.map(&:name).include?(:view_pulse)

    Redmine::AccessControl.map do |map|
      map.project_module :pulse do |pm|
        # the action map MUST include :refresh to match init.rb.
        # :view_pulse covers the pulse_views CRUD + select actions; :manage_public_pulse_views
        # is a GLOBAL permission — mirroring init.rb so the functional/integration suites see the
        # same permission surface.
        pm.permission :view_pulse,
                      { pulse: %i[index show refresh watch unwatch], pulse_api: %i[portfolio project],
                        pulse_views: %i[index new create show edit update destroy select] },
                      read: true
        pm.permission :manage_public_pulse_views,
                      { pulse_views: %i[create update destroy] },
                      require: :loggedin,
                      global: true
      end
    end
  end

  # ---- low-level builders --------------------------------------------------

  def create_user!(login:, admin: false)
    # Set a KNOWN password so the integration suites' `post '/login'` helper
    # authenticates the user for the subsequent HTTP request (the controllers-api
    # HTML/JSON suites drive real requests; User.generate! leaves the password blank,
    # which would make every login fall through to the anonymous path).
    User.generate!(login: login, firstname: login.capitalize, lastname: 'T',
                   mail: "#{login}@example.com", admin: admin,
                   status: User::STATUS_ACTIVE,
                   password: 'password', password_confirmation: 'password')
  end

  def create_role!(name:, issues_visibility: 'all', permissions: %i[view_issues view_pulse])
    Role.generate!(name: name, issues_visibility: issues_visibility, permissions: permissions)
  end

  def create_project!(name:, identifier:, status: Project::STATUS_ACTIVE,
                      modules: %w[issue_tracking pulse repository])
    p = Project.generate!(name: name, identifier: identifier)
    p.enabled_module_names = modules
    p.update_column(:status, status) unless status == Project::STATUS_ACTIVE
    p.reload
    p
  end

  def add_member!(project:, principal:, role:)
    Member.create!(project: project, principal: principal, roles: [role])
  end

  def tracker_for(project)
    project.trackers.first || begin
      t = Tracker.generate!(default_status: open_status)
      project.trackers << t
      project.reload
      t
    end
  end

  # A Filesystem repository needs no on-disk working copy to hold Changeset rows.
  def create_repository!(project)
    project.repository ||
      Repository::Filesystem.create!(project: project, url: "/tmp/repo-#{project.id}",
                                     identifier: "repo#{project.id}")
  end

  def create_changeset!(repository:, committer:, committed_on:, revision: nil)
    cs = Changeset.new(repository: repository,
                       revision: revision || "r#{SecureRandom.hex(4)}",
                       committer: committer, comments: 'c',
                       committed_on: committed_on)
    cs.save!(validate: false)
    cs.update_column(:committed_on, committed_on)
    cs.reload
    cs
  end

  def create_issue!(project:, author:, tracker: nil, subject: 'I', status: nil,
                    assigned_to: nil, is_private: false, priority: nil,
                    created_on: nil, updated_on: nil)
    tracker ||= tracker_for(project)
    status ||= IssueStatus.where(is_closed: false).first
    priority ||= IssuePriority.where(is_default: true).first || IssuePriority.first
    issue = Issue.new(project: project, tracker: tracker, author: author,
                      subject: subject, status: status, priority: priority,
                      is_private: is_private, assigned_to: assigned_to)
    issue.save!(validate: false)
    stamp!(issue, created_on: created_on, updated_on: updated_on)
    issue
  end

  # Force created_on/updated_on without firing callbacks (so reference_date /
  # event_series have deterministic timestamps). These are Redmine *fixture-setup*
  # writes, NOT adapter writes — the read-only guard applies to the adapter only.
  #
  # NOTE: an instance #update_column on an Issue *immediately after*
  # save!(validate: false) is a silent DB no-op under Redmine 6.1.2 / Rails 7.2.3,
  # because awesome_nested_set leaves lft/rgt/root_id dirty on the in-memory record
  # and the subsequent single-column UPDATE is dropped. Writing through the relation
  # (update_all) bypasses that stale in-memory state and persists reliably; the
  # trailing reload then refreshes the object. (Same effect, callback-free.)
  def stamp!(record, created_on: nil, updated_on: nil)
    columns = {}
    columns[:created_on] = created_on if created_on
    columns[:updated_on] = updated_on if updated_on
    record.class.where(id: record.id).update_all(columns) unless columns.empty?
    record.reload
  end

  def open_status
    @open_status ||= IssueStatus.where(is_closed: false).order(:position).first
  end

  def closed_status
    @closed_status ||= (IssueStatus.where(is_closed: true).order(:position).first ||
                        IssueStatus.create!(name: 'PulseClosed', is_closed: true))
  end

  # Append a status-change journal that flips is_closed false->true (a closing
  # event), timestamped at `at`.
  def add_close_journal!(issue:, user:, from_status:, to_status:, at:)
    j = Journal.new(journalized: issue, user: user, notes: '')
    j.details << JournalDetail.new(property: 'attr', prop_key: 'status_id',
                                   old_value: from_status.id.to_s, value: to_status.id.to_s)
    j.save!
    j.update_column(:created_on, at)
    issue.update_column(:status_id, to_status.id)
    issue.reload
    j
  end

  def numeric_custom_field!(name:, format: 'int')
    f = IssueCustomField.create!(name: name, field_format: format, is_for_all: true)
    f
  end

  def set_custom_value!(issue:, field:, value:)
    issue.custom_field_values = { field.id => value }
    issue.save_custom_field_values
    issue.reload
  end

  # blocks relation: issue_from BLOCKS issue_to (issue_to is the blocked one).
  def add_blocks_relation!(blocker:, blocked:)
    IssueRelation.create!(issue_from: blocker, issue_to: blocked,
                          relation_type: IssueRelation::TYPE_BLOCKS)
  end

  def create_version!(project:, name:, effective_date: nil)
    Version.create!(project: project, name: name, effective_date: effective_date)
  end

  # ---- query-write guard (read-only) --------------------------------------

  REDMINE_DOMAIN_TABLES = %w[
    projects issues journals journal_details issue_statuses changesets
    repositories versions issue_relations enumerations roles members
    member_roles users groups_users custom_values settings trackers
  ].freeze

  # Subscribe to sql.active_record and collect any INSERT/UPDATE/DELETE against a
  # Redmine domain table fired while the block runs. Returns the array of write
  # SQL strings (empty == read-only).
  def capture_write_statements
    writes = []
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = args.last
      sql = payload[:sql].to_s
      next if payload[:name].to_s =~ /SCHEMA|TRANSACTION/i
      next unless sql =~ /\A\s*(INSERT|UPDATE|DELETE)\b/i
      next unless REDMINE_DOMAIN_TABLES.any? { |t| sql =~ /\b#{Regexp.escape(t)}\b/i }

      writes << sql
    end
    yield
    writes
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # A frozen-date test double satisfying the Clock port (#today -> Date, #now -> Time).
  FixedClock = Struct.new(:date) do
    def today
      date
    end

    # #now — the absolute instant on the fixed date (midnight UTC). Required by the
    # Clock port (snapshot-max-age-refresh); the projection Engine calls @clock.now on
    # every cache HIT (age_stale?), so the double must answer #now, not only #today —
    # otherwise a warm-cache re-read NoMethodErrors.
    def now
      Time.utc(date.year, date.month, date.day)
    end
  end

  # ---- controllers-api support (controller + store suites) ----------

  # Write the plugin settings hash (the ONE permitted settings-table write — it is
  # the admin form's persistence mechanism, exercised here as test setup, NOT a
  # pulse GET/POST action body; GET/refresh writes are confined to
  # pulse_snapshots). Merges over the init.rb defaults.
  def pulse_settings!(overrides = {})
    base = {
      'rag_green_min' => 67, 'rag_amber_min' => 34,
      'h_stale' => 180, 'h_risk' => 50, 'h_blocked' => 20,
      'activity_window_days' => 30, 'weights' => {},
      'effort_field' => '', 'risk_trackers' => [], 'blocked_status' => ''
    }
    Setting.plugin_redmine_pulse = base.merge(overrides.transform_keys(&:to_s))
  end

  # Build a default settings provider (no enrichment mappings) backed by the real
  # RedmineSettingsProvider so settings_version_hash actually tracks Setting state.
  def real_settings_provider
    Pulse::Adapters::RedmineSettingsProvider.new
  end

  # The full set of Redmine domain tables the read-only guard must see ZERO writes
  # on — pulse_snapshots is NOT in this set (it is the plugin-owned cache table the
  # GET/refresh paths are permitted to write).
  def redmine_domain_write_tables
    REDMINE_DOMAIN_TABLES
  end
end
