# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

require 'digest'

module Pulse
  module Adapters
    # SnapshotFingerprint (MS-26/27/28, FC-27/28/29) — the content-addressed cache
    # key over EVERY non-time-dependent score input (DEC-11 / spec §6.4). Nine
    # ordered components; the Clock (today) is DELIBERATELY excluded so the
    # time-derived part re-projects per request without a snapshot recompute.
    #
    # Components (ordered):
    #   1. max(updated_on) over the requester's visible issues
    #   2. visible_issue_count (catches deletion when max(updated_on) does not move)
    #   3. latest_changeset_id (ONLY when repository module + :view_changesets held)
    #   4. blocker_fingerprint (FC-28; cross-project visible blocker state flip)
    #   5. sorted {version_id => due_date}
    #   6. priority_enum_version (FC-29; (id,position,is_default) only — NOT names)
    #   7. settings_version_hash
    #   8. visibility_context_id
    #   9. effort_field_visibility (S1; mapped effort field id + its per-user
    #      visibility to THIS requester on THIS project — catches a field-visibility
    #      revoke that degrades effort() while max(updated_on) is unmoved)
    #
    # Read-only: it only reads Redmine model state.
    class SnapshotFingerprint
      # NOTE: NO clock parameter — Clock(today) is excluded by design (DEC-11).
      def initialize(user, project, settings_provider:)
        @user = user
        @project = project
        @settings_provider = settings_provider
      end

      # -> String, hash over the 9 ordered components.
      def value
        Digest::SHA256.hexdigest(components.join("\n"))
      end

      # -> String, component 6 exposed for falsification. (id, position, is_default)
      #    tuples only; a name-only rename leaves this unchanged (FC-29 / EA-MS-004).
      def priority_enum_version
        tuples = IssuePriority.order(:id).pluck(:id, :position, :is_default)
        Digest::SHA256.hexdigest(tuples.map { |t| t.join(':') }.join('|'))
      end

      private

      def components
        [
          max_updated_on,
          visible_issue_count,
          latest_changeset_id,
          blocker_fingerprint,
          version_due_date_set,
          priority_enum_version,
          @settings_provider.settings_version_hash,
          visibility_context_id,
          effort_field_visibility
        ]
      end

      # Component 9 (S1): '' (stable) when no effort field is mapped; otherwise
      # "#{field_id}:#{visible?}" where visible? mirrors the direct-compute gate
      # (redmine_metrics_source.rb effort_field_visible?): a missing field => not
      # visible => 0. When the field's per-user visibility flips, this component
      # moves => the fingerprint moves => cache miss => recompute => correct degrade.
      def effort_field_visibility
        return '' unless @settings_provider.respond_to?(:effort_mapped?)
        return '' unless @settings_provider.effort_mapped?

        field_id = @settings_provider.effort_custom_field_id
        visible = IssueCustomField.find_by(id: field_id)&.visible_by?(@project, @user)
        "#{field_id}:#{visible ? 1 : 0}"
      end

      def visible_scope
        Issue.where(project_id: @project.id).visible(@user)
      end

      def max_updated_on
        visible_scope.maximum(:updated_on).to_s
      end

      def visible_issue_count
        visible_scope.count.to_s
      end

      # Component 3: only meaningful when the user may see changesets (FC-10/THAW-001).
      def latest_changeset_id
        return '' unless @project.module_enabled?(:repository)
        return '' unless @user.allowed_to?(:view_changesets, @project)
        return '' unless @project.repository

        Changeset.where(repository_id: @project.repository.id).maximum(:id).to_s
      end

      # Component 4 (FC-28): over `blocks` relations whose blocked endpoint is one of
      # this project's visible OPEN issues, the sorted tuple-hash of
      # (relation_id, issue_from_id, issue_from.is_closed, issue_from.updated_on) for
      # each blocker the requester can see. Catches a cross-project visible blocker
      # flipping open<->closed even though this project's max(updated_on) is unmoved.
      def blocker_fingerprint
        blocked_ids = visible_scope.open.pluck(:id)
        return '' if blocked_ids.empty?

        relations = IssueRelation
                    .where(relation_type: IssueRelation::TYPE_BLOCKS, issue_to_id: blocked_ids)
                    .includes(:issue_from)

        tuples = relations.filter_map do |rel|
          blocker = rel.issue_from
          next nil if blocker.nil?
          next nil unless blocker.visible?(@user)

          [rel.id, blocker.id, (blocker.closed? ? 1 : 0), blocker.updated_on.to_s].join(':')
        end

        Digest::SHA256.hexdigest(tuples.sort.join('|'))
      end

      # Component 5: sorted {version_id => due_date}; NULL effective_date excluded.
      def version_due_date_set
        rows = Version.where(project_id: @project.id)
                      .where.not(effective_date: nil)
                      .pluck(:id, :effective_date)
        rows.map { |id, d| "#{id}=#{d}" }.sort.join(',')
      end

      def visibility_context_id
        VisibilityContext.new(@user, @project).id
      end
    end
  end
end
