# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'digest'

module Pulse
  module Adapters
    # VisibilityContext — a deterministic fingerprint of
    # the FULL resolved Redmine visibility predicate for a requester on a project.
    # It is the cache-partition key: two requesters who would
    # see EXACTLY the same issue set share an id; any predicate-affecting change
    # (role/group/membership/tracker-permission/module/admin/:view_changesets) moves
    # the id. There is NO view_private_issues dimension (it does not exist in 6.1).
    #
    # Read-only: it only reads Redmine model state.
    class VisibilityContext
      ROLE_IDENTITY_VISIBILITY = %w[own default].freeze

      def initialize(user, project)
        @user = user
        @project = project
      end

      # -> String, deterministic over the full resolved predicate (+ identity when
      #    any applicable role is identity-dependent).
      def id
        Digest::SHA256.hexdigest(serialized_dimensions)
      end

      # OPTIONAL falsification surface: the input dimensions. MUST NOT
      # contain a view_private_issues dimension.
      def dimensions
        dims = base_dimensions
        dims[:identity] = identity_component if identity_dependent?
        dims
      end

      private

      def serialized_dimensions
        d = dimensions
        d.keys.map(&:to_s).sort.map { |k| "#{k}=#{stringify(d[k.to_sym])}" }.join('|')
      end

      def base_dimensions
        {
          user_status: @user.status,
          admin: @user.admin? ? 1 : 0,
          # (1) view_issues: issue_tracking module + active/closed project precondition.
          issue_tracking_module: module_enabled?(:issue_tracking) ? 1 : 0,
          project_status: @project.status,
          # pulse + repository module state.
          pulse_module: module_enabled?(:pulse) ? 1 : 0,
          repository_module: module_enabled?(:repository) ? 1 : 0,
          # (2)+(3)+(4) per-project effective roles, their issues_visibility level,
          # per-tracker view restrictions, and the relevant permission flags —
          # captured as a sorted role descriptor set. Reading the permission flags
          # off the fresh role objects (rather than User#allowed_to?, which caches
          # per User instance) ensures a role permission grant moves the id.
          roles: role_descriptors
        }
      end

      # Permissions whose state participates in the visibility predicate (view_issues
      # gates the issue set; :view_changesets gates changeset dates;
      # :view_private_notes gates private-note momentum journals in event_series, so a
      # change to it must move the cache-partition id — otherwise a stale snapshot warmed
      # while permitted leaks private-note momentum after the revoke).
      PREDICATE_PERMISSIONS = %i[view_issues view_changesets view_private_notes].freeze

      # Sorted, deterministic descriptor for each effective role on the project.
      # Permission flags are read from a FRESH Role load (not the user-cached role
      # objects from roles_for_project, which can be stale after a permission grant)
      # so a :view_changesets grant moves the id.
      def role_descriptors
        fresh = Role.where(id: roles_for_project.map(&:id)).index_by(&:id)
        roles_for_project.sort_by(&:id).map do |cached|
          role = fresh[cached.id] || cached
          perms = PREDICATE_PERMISSIONS.map { |p| role.has_permission?(p) ? 1 : 0 }
          [
            role.id,
            role.issues_visibility,
            tracker_restriction(role),
            "p#{perms.join}"
          ].join(':')
        end
      end

      # Per-tracker view restriction: 'all' when the role views all trackers, else the
      # sorted set of permitted tracker ids.
      def tracker_restriction(role)
        return 'all' if !role.respond_to?(:permissions_all_trackers?) ||
                        role.permissions_all_trackers?(:view_issues)

        ids = role.permissions_tracker_ids(:view_issues)
        "t#{Array(ids).map(&:to_i).sort.join(',')}"
      end

      # Identity is part of the predicate whenever ANY applicable role resolves
      # identity-dependently (own/default).
      def identity_dependent?
        roles_for_project.any? do |role|
          ROLE_IDENTITY_VISIBILITY.include?(role.issues_visibility.to_s)
        end
      end

      def identity_component
        group_ids = @user.respond_to?(:groups) ? @user.groups.map(&:id).sort : []
        "u#{@user.id};g#{group_ids.join(',')}"
      end

      def roles_for_project
        @roles_for_project ||= @user.roles_for_project(@project)
      end

      def module_enabled?(name)
        @project.module_enabled?(name) ? true : false
      end

      def allowed_to?(permission)
        @user.allowed_to?(permission, @project)
      end

      def stringify(value)
        case value
        when Array then "[#{value.map { |e| stringify(e) }.join(',')}]"
        else value.to_s
        end
      end
    end
  end
end
