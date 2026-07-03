# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

# PulseSettingsHelper — prepares the settings-partial's form option data OUTSIDE the
# ERB view (COND-A4-002 / Rule 18). The settings partial is rendered by Redmine's own
# SettingsController, which does not run the plugin's composition root, so the tracker
# option list cannot be precomputed in a Pulse controller; it is prepared here, at the
# helper boundary, and the partial consumes ONLY the plain [name, id] pairs returned.
#
# This module is included into SettingsController (see init.rb) so the helper is
# available to the plugin settings partial. The single Redmine AR query (Tracker.sorted)
# lives HERE, never in the ERB — the view renders prepared presenter/form state only.
module PulseSettingsHelper
  # Plain option data for the risk_trackers multi-select: an ordered Array of
  # [display_name, id_string] pairs (the exact shape Rails' options_for_select consumes).
  # No view logic, no scoring/domain recomputation — just the tracker id+name inventory.
  def pulse_tracker_options
    Tracker.sorted.map { |tracker| [tracker.name, tracker.id.to_s] }
  end

  # Numeric issue custom fields whose name looks like an effort / story-points field.
  # Offered as a discovery HINT on the settings page (suggest-only): the admin still
  # types the id into the effort-field input to opt in — blank keeps the issue-count
  # Progress mode, so nothing is auto-applied and no score changes silently.
  # Returns an ordered Array of [display_name, id_string] pairs (empty when none match).
  # Word-bounded + separator-aware so it matches "Story Points" / "Story-Points" /
  # "story_points" / "Effort" but NOT "History Points" or "effortless".
  EFFORT_FIELD_NAME_PATTERN = /\b(?:story[\s_-]*points?|effort)\b/i

  def pulse_effort_field_candidates
    IssueCustomField
      .where(field_format: Pulse::Adapters::RedmineSettingsProvider::NUMERIC_FORMATS)
      .order(:id)
      .select { |cf| cf.name =~ EFFORT_FIELD_NAME_PATTERN }
      .map { |cf| [cf.name, cf.id.to_s] }
  end
end
