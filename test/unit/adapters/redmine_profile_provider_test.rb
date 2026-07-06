# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# C1 lesson: a bare `require 'pulse/...'` fails under the harness without -Ilib. This is a
# pure-adapter unit test, so add lib/ to $LOAD_PATH before requiring the adapter.
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'
require 'pulse/adapters/redmine_profile_provider'

# IT-C4-02 / IT-C4-05 / IT-C4-08 (unit slice) — RedmineProfileProvider resolution logic.
# FR-C4-02/03/04/09 / FC-C4-05, FC-C4-06, FC-C4-07, FC-C4-12.
#
# The provider is exercised over a PLAIN settings hash (the shape RedmineSettingsProvider
# exposes for pulse_profiles) + LIGHTWEIGHT viewer/project/role fakes (duck-typed:
# user#roles_for_project(project) -> [role], role#id). This keeps the resolution logic —
# precedence, multi-role tie-break, dangling fallback+warning, synthetic default — in the
# pure-adapter lane without a live Redmine. The full settings->resolve chain over the REAL
# Setting/Role stack is exercised by the harness end-to-end chain test (IT-C4-07).
#
# The provider factory shape these tests pin (A9 implements to match):
#   Pulse::Adapters::RedmineProfileProvider.new(
#     settings_provider: <duck with #scoring_config + #pulse_profiles>)
#   provider.profiles                              -> [ScoringProfile, ...] incl. "default"
#   provider.resolve(viewer, project, requested_id) -> ScoringProfile (precedence chain)
#     ... AND surfaces a warning for a dangling id via provider.last_warning (or resolve
#         returning [profile, warning] — the tests read #resolve's profile via #id and the
#         warning via #last_warning, both pinned below).
#
# RED NOW: Pulse::Adapters::RedmineProfileProvider is unimplemented -> `require` raises
# LoadError. GREEN after A9 creates lib/pulse/adapters/redmine_profile_provider.rb.
class RedmineProfileProviderTest < Minitest::Test
  RPP = Pulse::Adapters::RedmineProfileProvider
  SC  = Pulse::Domain::ScoringConfig
  R   = Pulse::Domain::SignalRegistry

  FakeRole = Struct.new(:id)
  FakeProject = Struct.new(:id)

  # A viewer duck: #roles_for_project(project) -> the fixed role list (in ANY order —
  # the provider must sort by role.id ascending itself, FC-C4-07).
  FakeUser = Struct.new(:roles) do
    def roles_for_project(_project)
      roles
    end
  end

  # The global ScoringConfig the synthetic default mirrors.
  def global_config
    SC.new
  end

  # A reweighted config (different weights => the profile is distinguishable).
  def profile_config(staleness)
    rest = (1.0 - staleness) / 4.0
    SC.new(weights: { staleness: staleness, progress: rest, momentum: rest,
                      risk_load: rest, blocked_load: rest })
  end

  # A settings-provider duck exposing #scoring_config (for the synthetic default) and
  # #pulse_profiles (the admin-defined profiles + role bindings, in the shape the real
  # RedmineSettingsProvider exposes: string-keyed profiles + role_bindings).
  def settings_provider(profiles: {}, role_bindings: {})
    cfg = global_config
    Class.new do
      define_method(:scoring_config) { cfg }
      define_method(:pulse_profiles) do
        { 'profiles' => profiles, 'role_bindings' => role_bindings }
      end
    end.new
  end

  # Two published profiles P1 (id 'p1') and P2 (id 'p2') with DIFFERENT weights, plus the
  # synthetic default. `role_bindings` maps role_id => profile_id.
  def provider(role_bindings: {})
    sp = settings_provider(
      profiles: {
        'p1' => { 'name' => 'Profile One', 'config' => profile_config(0.6) },
        'p2' => { 'name' => 'Profile Two', 'config' => profile_config(0.2) }
      },
      role_bindings: role_bindings
    )
    RPP.new(settings_provider: sp)
  end

  def user_with_roles(*ids)
    FakeUser.new(ids.map { |i| FakeRole.new(i) })
  end

  def project
    FakeProject.new(1)
  end

  # === FC-C4-05: the synthetic system default (id "default") always exists ======
  def test_profiles_always_include_the_system_default
    ids = provider.profiles.map(&:id)
    assert_includes ids, 'default',
                    'ProfileProvider#profiles must always include the synthetic id "default"'
  end

  def test_default_profile_config_mirrors_the_global_config
    default = provider.profiles.find { |p| p.id == 'default' }
    refute_nil default, 'the default profile is published'
    assert_equal global_config.weights, default.config.weights,
                 'the default profile config mirrors the global scoring_config (FC-C4-05)'
  end

  def test_default_is_present_even_with_admin_profiles_configured
    ids = provider.profiles.map(&:id)
    assert_includes ids, 'p1'
    assert_includes ids, 'p2'
    assert_includes ids, 'default',
                    '"default" is still present alongside admin-defined profiles'
  end

  def test_published_profiles_are_scoring_profile_instances
    provider.profiles.each do |p|
      assert p.is_a?(Pulse::Domain::ScoringProfile),
             'every published profile is a Pulse::Domain::ScoringProfile'
    end
  end

  # === FC-C4-06: resolution precedence — viewer > role-binding > default =========
  # AC-C4-02 table.

  # (a) explicit selection beats an applicable role-binding.
  def test_explicit_selection_beats_role_binding
    prov = provider(role_bindings: { 10 => 'p1' })
    viewer = user_with_roles(10) # role 10 is bound to p1
    active = prov.resolve(viewer, project, 'p2') # but the viewer explicitly selects p2
    assert_equal 'p2', active.id,
                 'explicit viewer selection (p2) must beat the role-binding (p1)'
  end

  # (b) role-binding beats the system default when no explicit selection.
  def test_role_binding_beats_default
    prov = provider(role_bindings: { 10 => 'p1' })
    viewer = user_with_roles(10)
    active = prov.resolve(viewer, project, nil)
    assert_equal 'p1', active.id,
                 'the role-default binding (p1) must beat the system default'
  end

  # (c) no explicit selection, no role binding => system default.
  def test_no_selection_no_binding_resolves_to_default
    prov = provider(role_bindings: {})
    viewer = user_with_roles(10)
    active = prov.resolve(viewer, project, nil)
    assert_equal 'default', active.id,
                 'with no selection and no binding, resolve must return the system default'
  end

  # (d) each level overrides the one below (selection present AND binding present).
  def test_selection_overrides_every_lower_level
    prov = provider(role_bindings: { 10 => 'p1' })
    viewer = user_with_roles(10)
    active = prov.resolve(viewer, project, 'p2')
    assert_equal 'p2', active.id, 'the explicit selection overrides both binding and default'
  end

  def test_viewer_with_no_roles_resolves_to_default
    prov = provider(role_bindings: { 10 => 'p1' })
    viewer = user_with_roles # no roles on the project
    active = prov.resolve(viewer, project, nil)
    assert_equal 'default', active.id,
                 'a viewer holding none of the bound roles resolves to the default'
  end

  # === FC-C4-07: multi-role tie-break — first match by role.id ASCENDING ========
  def test_multi_role_binding_resolves_to_lowest_role_id
    # role 20 -> p2, role 10 -> p1 ; ascending role.id => role 10 wins => p1.
    prov = provider(role_bindings: { 20 => 'p2', 10 => 'p1' })
    viewer = user_with_roles(20, 10) # deliberately NOT ascending order
    active = prov.resolve(viewer, project, nil)
    assert_equal 'p1', active.id,
                 'multi-role tie-break: FIRST match by role.id ASCENDING (role 10 -> p1)'
  end

  def test_multi_role_tiebreak_is_invariant_across_role_order
    prov = provider(role_bindings: { 20 => 'p2', 10 => 'p1' })
    ascending  = prov.resolve(user_with_roles(10, 20), project, nil).id
    descending = prov.resolve(user_with_roles(20, 10), project, nil).id
    assert_equal ascending, descending,
                 'resolution is invariant to the viewer role-list order (deterministic, FC-C4-07)'
    assert_equal 'p1', ascending, 'the ascending-role.id first match is p1'
  end

  def test_multi_role_tiebreak_is_deterministic_across_binding_insertion_order
    a = provider(role_bindings: { 10 => 'p1', 20 => 'p2' })
        .resolve(user_with_roles(10, 20), project, nil).id
    b = provider(role_bindings: { 20 => 'p2', 10 => 'p1' })
        .resolve(user_with_roles(10, 20), project, nil).id
    assert_equal a, b,
                 'resolution is invariant to the settings binding insertion order (FC-C4-07)'
    assert_equal 'p1', a
  end

  # === FC-C4-12: dangling profile reference degrades to default + warning ========
  # A role-binding / selection referencing a removed/renamed profile resolves to the
  # system default AND surfaces a human-readable warning; NO exception is raised.
  def test_dangling_role_binding_degrades_to_default_with_warning
    prov = provider(role_bindings: { 10 => 'gone' }) # 'gone' is not a published profile
    viewer = user_with_roles(10)
    active = nil
    assert_silent do
      active = prov.resolve(viewer, project, nil)
    end
    assert_equal 'default', active.id,
                 'a dangling role-binding must fall back to the system default (no crash)'
    refute_nil prov.last_warning,
               'a dangling reference must surface a non-empty warning (FC-C4-12)'
    refute_empty prov.last_warning.to_s,
                 'the surfaced warning must be human-readable (non-empty)'
  end

  def test_dangling_explicit_selection_degrades_to_default_with_warning
    prov = provider(role_bindings: {})
    viewer = user_with_roles(10)
    active = prov.resolve(viewer, project, 'gone') # transient selection of a removed id
    assert_equal 'default', active.id,
                 'a dangling explicit selection falls back to the default (FC-C4-12)'
    refute_nil prov.last_warning, 'a dangling selection surfaces a warning'
  end

  def test_dangling_reference_does_not_raise
    prov = provider(role_bindings: { 10 => 'gone' })
    viewer = user_with_roles(10)
    begin
      prov.resolve(viewer, project, 'also-gone')
    rescue StandardError => e
      flunk "a dangling reference must not raise (#{e.class}: #{e.message})"
    end
  end

  # A successful resolution must NOT leave a stale warning set (no false positives).
  def test_successful_resolution_has_no_warning
    prov = provider(role_bindings: { 10 => 'p1' })
    active = prov.resolve(user_with_roles(10), project, nil)
    assert_equal 'p1', active.id
    assert_nil prov.last_warning,
               'a clean resolution must not surface a warning (no false dangling report)'
  end
end
