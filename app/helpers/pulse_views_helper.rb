# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseViewsHelper — prepares the saved-view form's option data OUTSIDE the ERB view
# (the view holds no domain/AR logic), mirroring PulseSettingsHelper. This helper auto-loads for
# PulseViewsController's views (Rails convention: app/helpers/pulse_views_helper.rb).
# The single Redmine AR queries (Role.givable, the current user's member projects, the
# issue-status list) live HERE, never in the ERB — the _form partial consumes only the
# prepared [name, id] pairs.
#
# SECURITY: these are presentation-only option inventories for the author's convenience.
# They do NOT weaken any server-side gate — the controller's publish gate, visibility
# re-check, and system-view immutability run irrespective of what the form offered. The
# project list is scoped to the current user's own memberships so the form never
# enumerates projects the author cannot already see.
module PulseViewsHelper
  # Roles offered for a role-scoped view's role_ids multi-select. Role.givable is the
  # member-assignable role set (excludes the builtin Non-member / Anonymous pseudo-roles),
  # ordered by position — the same set an admin assigns on a project's members tab.
  # Returns an ordered Array of [role_name, id_string] pairs.
  def pulse_view_role_options
    Role.givable.map { |role| [role.name, role.id.to_s] }
  end

  # Projects offered for a project_scope=selected view's scope_params[:project_ids]
  # multi-select. Scoped to the projects the CURRENT user is a member of (portfolio scope,
  # consistent with the cockpit's own project set) so the author never selects a project
  # outside their own visibility. Returns an ordered Array of [project_name, id_string].
  def pulse_view_project_options
    Project.active
           .joins(:members)
           .where(members: { user_id: User.current.id })
           .distinct
           .sorted
           .map { |project| [project.name, project.id.to_s] }
  end

  # PROJECT statuses offered for a project_scope=status_filter view's scope_params[:status_id].
  # A status_filter view narrows the portfolio to projects whose Project#status matches the
  # stored value (see PulseController#apply_view_scope), so the control MUST offer PROJECT
  # statuses (Active/Closed/Archived), NOT issue statuses — otherwise the authored value would
  # never match what the runtime scope reads. Returns an ordered Array of [status_name, id_string].
  def pulse_view_status_options
    [
      [l(:project_status_active),   Project::STATUS_ACTIVE.to_s],
      [l(:project_status_closed),   Project::STATUS_CLOSED.to_s],
      [l(:project_status_archived), Project::STATUS_ARCHIVED.to_s]
    ]
  end

  # The lens keys a saved view may sort/lens by (the cockpit's built-in lens vocabulary).
  def pulse_view_lens_options
    Pulse::Adapters::LensRanker::LENSES
  end

  # The currently-selected project_ids for a persisted view (deserialized scope_params),
  # as a set of id strings for the multi-select's `selected` marking. [] when unset.
  def pulse_view_selected_project_ids(view)
    Array((view.scope_params || {})['project_ids'] ||
          (view.scope_params || {})[:project_ids]).map(&:to_s)
  end

  # The persisted status filter id (scope_params[:status_id]) as a string, or ''.
  def pulse_view_selected_status_id(view)
    ((view.scope_params || {})['status_id'] ||
     (view.scope_params || {})[:status_id]).to_s
  end

  # The persisted sort column (view.sort is a serialized Array [column, direction]); ''
  # when unset. The saved-view sort is a minimally-persisted preference.
  def pulse_view_sort_column(view)
    Array(view.sort)[0].to_s
  end

  # The persisted sort direction ('asc' | 'desc'), defaulting to 'desc' (worst-first, the
  # cockpit's natural risk ordering).
  def pulse_view_sort_direction(view)
    dir = Array(view.sort)[1].to_s
    %w[asc desc].include?(dir) ? dir : 'desc'
  end

  # A persisted preference value (view.prefs is a serialized Hash), '' when unset.
  def pulse_view_pref(view, key)
    ((view.prefs || {})[key.to_s] || (view.prefs || {})[key.to_sym]).to_s
  end
end
