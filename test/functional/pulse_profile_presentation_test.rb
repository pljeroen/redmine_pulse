# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))

# Active-profile presentation slice.
# The HtmlPresenter view-model exposes the ACTIVE PROFILE NAME for the "scored under: <name>"
# display, plus a SWITCHER listing the published profiles (each option value == profile.id).
# The view reads ONLY the presenter output — no direct AR/domain access.
#
# Checks:
#   (a) presenter given a Projection with active profile P => panel_view.active_profile_name == P.name.
#   (b) the switcher renders one option per published profile with value == profile.id.
#   (c) the view reads only the presenter output (asserted structurally: the switcher options
#       are precomputed on the view-model; no domain object is exposed to the ERB).
#
# HtmlPresenter references plugin constants resolved by Zeitwerk (I18n / MainConcernLabels /
# SignalResult), so it loads under the Redmine harness. The presenter fake Projection below
# carries the active_profile / active_profile_name / profile_options fields the PanelView
# must surface. Orchestrator runs it via run-tests.sh.
class PulseProfilePresentationTest < ActiveSupport::TestCase
  HP = Pulse::Adapters::HtmlPresenter
  SR = Pulse::Domain::SignalResult

  FakeProject = Struct.new(:id, :identifier, :name)
  FakeHealth = Struct.new(:breakdown, :health_score, :rag, :dominant_signal, :signal_completeness)
  # The Projection gains active_profile / active_profile_name + the published set for the
  # switcher (each carries #id + #name).
  FakeProfile = Struct.new(:id, :name)
  FakeProjection = Struct.new(
    :health, :project, :timeline, :snapshot_computed_at, :risk_tracker_ids,
    :active_profile, :active_profile_name, :published_profiles
  )

  PUBLISHED = [
    FakeProfile.new('default', 'Default'),
    FakeProfile.new('risk-heavy', 'Risk Heavy'),
    FakeProfile.new('balanced', 'Balanced')
  ].freeze

  def inactive_breakdown
    %i[staleness progress momentum risk_load blocked_load].map do |k|
      SR.new(key: k, active: false, raw_value: nil, n: nil,
             effective_weight: nil, contribution: nil)
    end
  end

  # A minimal EMPTY timeline: sparkline_points maps over #retrospective and milestones over
  # #forward, so two empty axes yield empty presentation arrays. panel_view needs a non-nil
  # timeline (the production Engine ALWAYS builds one via Timeline.build — it is never nil), so
  # this mirrors the real projection shape rather than passing nil into sparkline_points.
  def empty_timeline
    Pulse::Domain::TimelineResult.new(retrospective: [], forward: [])
  end

  def projection_with_active(profile)
    FakeProjection.new(
      FakeHealth.new(inactive_breakdown, 55, :amber, :staleness, 0.8),
      FakeProject.new(1, 'demo', 'Demo'),
      empty_timeline,    # non-nil timeline (empty axes) — matches the production projection shape
      Time.utc(2026, 6, 20),
      [],
      profile,
      profile.name,
      PUBLISHED
    )
  end

  # === (a): active_profile_name is surfaced ============================
  def test_panel_view_exposes_active_profile_name
    active = FakeProfile.new('risk-heavy', 'Risk Heavy')
    view = HP.panel_view(projection_with_active(active), now: Time.utc(2026, 6, 20))
    assert_respond_to view, :active_profile_name,
                      'the PanelView must expose active_profile_name'
    assert_equal 'Risk Heavy', view.active_profile_name,
                 'active_profile_name == the active profile\'s name'
  end

  # === (b): the switcher lists one option per published profile ========
  def test_panel_view_switcher_lists_published_profiles
    active = FakeProfile.new('balanced', 'Balanced')
    view = HP.panel_view(projection_with_active(active), now: Time.utc(2026, 6, 20))
    assert_respond_to view, :profile_options,
                      'the PanelView must expose the switcher options (profile_options)'
    options = view.profile_options
    assert_equal PUBLISHED.size, options.size,
                 'one switcher option per published profile'
    values = options.map { |o| o.respond_to?(:value) ? o.value : o[:value] }
    labels = options.map { |o| o.respond_to?(:label) ? o.label : o[:label] }
    assert_equal PUBLISHED.map(&:id).sort, values.sort,
                 'each option value == profile.id'
    assert_includes labels, 'Risk Heavy',
                    'each option carries the profile display name'
  end

  # === (b): the active profile is flagged selected in the switcher ======
  def test_switcher_flags_the_active_option_selected
    active = FakeProfile.new('risk-heavy', 'Risk Heavy')
    view = HP.panel_view(projection_with_active(active), now: Time.utc(2026, 6, 20))
    selected = view.profile_options.find do |o|
      val = o.respond_to?(:value) ? o.value : o[:value]
      val == 'risk-heavy'
    end
    refute_nil selected, 'the active profile option is present'
    is_selected = selected.respond_to?(:selected) ? selected.selected : selected[:selected]
    assert is_selected,
           'the active profile\'s switcher option must be flagged selected'
  end

  # === (c): the view-model exposes precomputed presentation state only ===
  # The switcher options are plain precomputed values (id + label + selected), NOT domain
  # ScoringProfile objects — so the ERB accesses no AR/domain object directly.
  def test_switcher_options_are_precomputed_presentation_values_not_domain_objects
    view = HP.panel_view(projection_with_active(FakeProfile.new('balanced', 'Balanced')),
                         now: Time.utc(2026, 6, 20))
    view.profile_options.each do |o|
      refute o.is_a?(Pulse::Domain::ScoringProfile),
             'switcher options must be precomputed view values, not domain ' \
             'ScoringProfile objects (the view reads only presenter output)'
    end
  end
end
