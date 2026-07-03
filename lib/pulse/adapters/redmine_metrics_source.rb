# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # MetricsSource implementation: builds a visibility-scoped Pulse::Domain::
    # ProjectMetrics per project for a requesting user, computed ENTIRELY over the
    # issues/changesets/versions/relations that user is allowed to see (§3.1 /
    # INV-PERMISSION-SAFE). READ-ONLY — it never writes a Redmine domain table
    # (INV-READ-ONLY / FC-02).
    #
    # All aggregate derivations follow spec §4.1 / FC-09..FC-22.
    class RedmineMetricsSource
      def initialize(settings_provider:, clock:)
        @settings_provider = settings_provider
        @clock = clock
      end

      # MS-01 / FC-34: ordered project_id ascending; Array<ProjectMetrics>.
      #   project_ids nil   => the user's full portfolio set
      #   project_ids Array => the visibility-filtered subset of those ids
      def metrics_for(user, project_ids: nil)
        ids = if project_ids.nil?
                portfolio_project_ids(user)
              else
                Project.visible(user).where(id: project_ids).pluck(:id)
              end

        Project.visible(user).where(id: ids).order(:id).map do |project|
          build_project_metrics(user, project)
        end
      end

      # MS-04 / FC-05: per-project HTTP-status decision function.
      def access_decision(user, project_id)
        project = Project.visible(user).find_by(id: project_id)
        return :not_found if project.nil?

        return :forbidden unless project.module_enabled?(:pulse)
        return :forbidden unless user.allowed_to?(:view_pulse, project)

        :ok
      end

      # MS-05 / FC-04: visible AND pulse-module-on AND view_pulse subset.
      def portfolio_project_ids(user)
        Project.visible(user)
               .where(id: pulse_enabled_project_ids)
               .order(:id)
               .select { |project| user.allowed_to?(:view_pulse, project) }
               .map(&:id)
      end

      private

      def pulse_enabled_project_ids
        EnabledModule.where(name: 'pulse').distinct.pluck(:project_id)
      end

      def build_project_metrics(user, project)
        visible = visible_issues(user, project)
        effort_open, effort_total, effort_mapped = effort(user, project, visible)
        risk_raw, risk_mapped = risk(visible)

        Pulse::Domain::ProjectMetrics.new(
          project_id: project.id,
          reference_date: reference_date(user, project, visible),
          effort_open: effort_open,
          effort_total: effort_total,
          risk_raw: risk_raw,
          blocked_count: blocked_count(user, visible),
          risk_mapped: risk_mapped,
          effort_mapped: effort_mapped,
          event_series: event_series(user, project, visible),
          version_due_dates: version_due_dates(project)
        )
      end

      # The requester's visible issue set for the project (INV-PERMISSION-SAFE).
      def visible_issues(user, project)
        Issue.where(project_id: project.id).visible(user)
      end

      # --- reference_date (MS-08/09, FC-09/10) ---------------------------------

      def reference_date(user, project, visible)
        # reference_date = max(latest visible issue.updated_on, latest visible eligible
        # changeset.committed_on, project.created_on) — project.created_on is a FULL
        # max participant, not a fallback (spec §4.1 / FC-09 / MS-08): a freshly-created
        # project reads as fresh. project.created_on guarantees a non-nil result.
        candidates = [project.created_on]
        latest_issue = visible.maximum(:updated_on)
        candidates << latest_issue if latest_issue

        changeset_date = latest_changeset_committed_on(user, project)
        candidates << changeset_date if changeset_date

        to_local_date(candidates.compact.max)
      end

      # Changeset date ONLY when repository module + :view_changesets (NOT
      # :browse_repository) — THAW-001 / EA-MS-001.
      def latest_changeset_committed_on(user, project)
        return nil unless project.module_enabled?(:repository)
        return nil unless user.allowed_to?(:view_changesets, project)
        return nil unless project.repository

        Changeset.where(repository_id: project.repository.id).maximum(:committed_on)
      end

      # --- effort (MS-10/10a/11/12, FC-11/12/13) -------------------------------

      def effort(user, project, visible)
        if @settings_provider.respond_to?(:effort_mapped?) && @settings_provider.effort_mapped? &&
           effort_field_visible?(user, project)
          field_id = @settings_provider.effort_custom_field_id
          total = sum_custom_field(visible, field_id)
          open  = sum_custom_field(visible.open, field_id)
          [open, total, true]
        else
          [visible.open.count, visible.count, false]
        end
      end

      # RT-02 / INV-PERMISSION-SAFE: sum the configured effort custom field ONLY when the
      # REQUESTER may see that field on the project. A field-blind viewer must never receive
      # field-derived numbers, so we degrade to the unmapped issue-count fallback. Absent or
      # unresolvable field => not visible.
      def effort_field_visible?(user, project)
        field_id = @settings_provider.effort_custom_field_id
        field = IssueCustomField.find_by(id: field_id)
        return false if field.nil?

        field.visible_by?(project, user)
      end

      # Per-issue NULL/blank/unparseable contributes 0 (MS-10a) — NOT excluded.
      def sum_custom_field(scope, field_id)
        ids = scope.pluck(:id)
        return 0 if ids.empty?

        values = CustomValue.where(customized_type: 'Issue',
                                   customized_id: ids,
                                   custom_field_id: field_id)
                            .pluck(:value)
        values.sum { |v| parse_numeric(v) }
      end

      def parse_numeric(value)
        return 0 if value.nil?

        s = value.to_s.strip
        return 0 if s.empty?

        Float(s)
      rescue ArgumentError, TypeError
        0
      end

      # --- risk (MS-13/14, FC-14/15) -------------------------------------------

      def risk(visible)
        return [0, false] unless @settings_provider.respond_to?(:risk_mapped?) &&
                                 @settings_provider.risk_mapped?

        tracker_ids = @settings_provider.risk_tracker_ids
        return [0, true] if tracker_ids.empty?

        priority_positions = IssuePriority.pluck(:id, :position).to_h
        raw = visible.open.where(tracker_id: tracker_ids).pluck(:priority_id).sum do |pid|
          priority_positions[pid] || 0
        end
        [raw, true]
      end

      # --- blocked_count (MS-15/16/17, FC-16/17) -------------------------------

      def blocked_count(user, visible)
        visible_all = visible.to_a
        return 0 if visible_all.empty?

        open_ids = visible_all.reject(&:closed?).map(&:id)
        blocked_status_id = if @settings_provider.respond_to?(:blocked_status_id)
                              @settings_provider.blocked_status_id
                            end

        # (a) relation rule: a visible OPEN issue blocked by a visible OPEN blocker.
        relation_blocked = open_ids.empty? ? [] : relation_blocked_ids(user, open_ids)

        # (b) status rule: a visible OPEN issue carrying the configured blocked status
        # (FC-16/MS-15 — blocked_count is over visible OPEN issues only). A visible
        # CLOSED issue whose status maps to the blocked status is NOT counted. An issue
        # that is itself an active blocker of another issue is NOT itself "blocked" and
        # is excluded, so an issue satisfying both rules is still counted exactly once.
        status_blocked = if blocked_status_id
                           blockers = blocking_issue_ids(open_ids)
                           visible_all
                             .reject(&:closed?)
                             .select { |i| i.status_id == blocked_status_id }
                             .map(&:id)
                             .reject { |id| blockers.include?(id) }
                         else
                           []
                         end

        (relation_blocked | status_blocked).uniq.size
      end

      # Ids of issues that are the issue_from (blocker) of a `blocks` relation whose
      # blocked endpoint is one of the requester's visible open issues.
      def blocking_issue_ids(open_ids)
        return [] if open_ids.empty?

        IssueRelation
          .where(relation_type: IssueRelation::TYPE_BLOCKS, issue_to_id: open_ids)
          .pluck(:issue_from_id)
      end

      # Issue X (open, visible) is relation-blocked iff a `blocks` relation has
      # issue_to = X and an issue_from that is OPEN and VISIBLE to the requester
      # (IssueRelation#visible? semantics — both endpoints visible).
      def relation_blocked_ids(user, open_ids)
        relations = IssueRelation
                    .where(relation_type: IssueRelation::TYPE_BLOCKS, issue_to_id: open_ids)
                    .includes(:issue_from)

        relations.filter_map do |rel|
          blocker = rel.issue_from
          next nil if blocker.nil?
          next nil if blocker.closed?
          next nil unless blocker.visible?(user)

          rel.issue_to_id
        end
      end

      # --- event_series (MS-18/19/20/21, FC-18/19/20/21) -----------------------

      def event_series(user, project, visible)
        events = []
        # Order source issues by id so iteration is independent of DB row order (FC-36).
        issues = visible.includes(:journals).order(:id).to_a

        # momentum-broaden §7: the activity window bounds the broadened :issue_commented /
        # :commit payload so the snapshot stays bounded (only momentum consumes these);
        # :issue_created / :issue_closed remain full-history (unchanged).
        today = @clock.today
        window_start = today - activity_window_days
        in_window = ->(date) { date >= window_start && date < today }

        issues.each do |issue|
          events << { date: to_local_date(issue.created_on), type: :issue_created, source_id: issue.id }
          collect_close_events(issue).each do |d|
            events << { date: d, type: :issue_closed, source_id: issue.id }
          end
          # :issue_commented — every journal whose created_on (local date) is in-window
          # (a close-journal also counting as activity is acceptable per §7).
          # M-01 / INV-PERMISSION-SAFE: a private-notes journal is counted ONLY when the
          # requester may view private notes on the project (symmetric with the :commit
          # gate); otherwise momentum/health would leak the existence/timing of private
          # activity to a user who cannot see it. Non-private journals are always counted.
          may_view_private = view_private_notes?(user, project)
          issue.journals.each do |journal|
            next if journal.private_notes? && !may_view_private

            d = to_local_date(journal.created_on)
            next unless in_window.call(d)

            events << { date: d, type: :issue_commented, source_id: issue.id }
          end
        end

        # :commit — gated exactly like latest_changeset_committed_on (module + permission +
        # repo), graceful fallback to none otherwise; only in-window changesets.
        commit_changesets(user, project).each do |id, committed_on|
          d = to_local_date(committed_on)
          next unless in_window.call(d)

          events << { date: d, type: :commit, source_id: id }
        end

        # Stable defined order: [date, type_rank, source_id]; drop the internal sort key so
        # only the frozen public fields (:date, :type) remain (FC-36).
        type_rank = { issue_created: 0, issue_closed: 1, issue_commented: 2, commit: 3 }
        events
          .sort_by { |e| [e[:date], type_rank[e[:type]], e[:source_id]] }
          .map { |e| { date: e[:date], type: e[:type] } }
      end

      # In-window-eligible changesets for the :commit activity events. SAME gate as
      # latest_changeset_committed_on (THAW-001 / EA-MS-001): repository module enabled,
      # :view_changesets (NOT :browse_repository), and a configured repository. Returns
      # [[changeset_id, committed_on], ...]; [] is the graceful no-repo/no-permission path.
      def commit_changesets(user, project)
        return [] unless project.module_enabled?(:repository)
        return [] unless user.allowed_to?(:view_changesets, project)
        return [] unless project.repository

        # RT-03 (security-S2-dos): push the activity-window predicate into SQL rather than
        # plucking the WHOLE repository and Ruby-filtering (an unbounded scan/transfer lever on a
        # large repo). The window is the SAME half-open [today - activity_window_days, today) the
        # :commit event filter (event_series#in_window) applies, evaluated by LOCAL date. Because
        # committed_on is a timestamp, we translate the local-date window into its timestamp bounds
        # in Time.zone: committed_on >= (start of window_start day) AND < (start of today) — which
        # reproduces `to_local_date(committed_on) >= window_start && < today` EXACTLY, including the
        # half-open upper bound (the exact-`today` commits at 09:00 are excluded because they fall
        # on/after the today-midnight upper bound). The event_series in_window guard is retained as
        # the invariant floor; the DB now does the heavy filtering.
        today = @clock.today
        window_start = today - activity_window_days
        lower = Time.zone.local(window_start.year, window_start.month, window_start.day)
        upper = Time.zone.local(today.year, today.month, today.day)

        Changeset
          .where(repository_id: project.repository.id)
          .where(committed_on: lower...upper)
          .pluck(:id, :committed_on)
      end

      # Whether the requester may see private-notes journals on this project (M-01 /
      # INV-PERMISSION-SAFE). Computed once per project (hoisted out of the issue loop)
      # so the :issue_commented gate adds no per-issue query.
      def view_private_notes?(user, project)
        user.allowed_to?(:view_private_notes, project)
      end

      # Activity window (days) read from the injected settings provider's scoring config —
      # the same ScoringConfig the domain consumes (momentum-broaden §7).
      def activity_window_days
        @settings_provider.scoring_config.activity_window_days
      end

      # Closing events for one issue (§4.1 / FC-19):
      #   * a journal status detail whose OLD status had is_closed=false and NEW
      #     status has is_closed=true -> one event at journal.created_on; plus
      #   * an issue created directly in a closed status -> one event at created_on
      #     (only when no opening journal/state precedes — i.e. it started closed).
      def collect_close_events(issue)
        dates = []
        status_closed = closed_status_ids

        # Was the issue created already in a closed status?
        created_closed = status_closed.include?(initial_status_id(issue))
        dates << to_local_date(issue.created_on) if created_closed

        status_journals(issue).each do |detail, at|
          old_id = detail.old_value.to_i
          new_id = detail.value.to_i
          old_closed = status_closed.include?(old_id)
          new_closed = status_closed.include?(new_id)
          dates << to_local_date(at) if !old_closed && new_closed
        end

        dates
      end

      # Status-change journal details with the journal created_on, in chronological order.
      def status_journals(issue)
        issue.journals.sort_by(&:created_on).flat_map do |journal|
          journal.details
                 .select { |d| d.property == 'attr' && d.prop_key == 'status_id' }
                 .map { |d| [d, journal.created_on] }
        end
      end

      # The issue's status at creation = the OLD value of its first status-change
      # journal if any, else its current status (no transitions ever occurred).
      def initial_status_id(issue)
        first = status_journals(issue).first
        first ? first[0].old_value.to_i : issue.status_id
      end

      def closed_status_ids
        @closed_status_ids ||= IssueStatus.where(is_closed: true).pluck(:id)
      end

      # --- version_due_dates (MS-22, FC-22) ------------------------------------

      def version_due_dates(project)
        Version.where(project_id: project.id)
               .where.not(effective_date: nil)
               .order(:id)
               .pluck(:id, :name, :effective_date)
               .map { |id, name, d| { version_id: id, name: name, due_date: to_plain_date(d) } }
      end

      # --- date helpers --------------------------------------------------------

      # Normalize a timestamp to a plain Date in the instance-configured timezone
      # (MS-18 / FC-18). Accepts Time/ActiveSupport::TimeWithZone; returns Date.
      def to_local_date(value)
        return value if value.instance_of?(Date)

        to_plain_date(value.in_time_zone(Time.zone).to_date)
      end

      # Coerce any Date-like (incl. DateTime / a Date subclass) into a plain Date,
      # since Pulse::Domain::ProjectMetrics requires instance_of?(Date) (CR-04).
      def to_plain_date(value)
        return value if value.instance_of?(Date)

        Date.new(value.year, value.month, value.day)
      end
    end
  end
end
