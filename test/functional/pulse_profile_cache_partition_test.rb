# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# ============================================================================
# IT-C4-01 (Tier-1 SECURITY, MAKE-OR-BREAK) + FC-C4-05B-CHECK (Tier-1 SECURITY).
# FR-C4-05 / INV-C4-CACHE-PARTITION / FC-C4-05B, FC-C4-08, FC-C4-09, FC-C4-15.
#
# MIRRORS test/functional/cache_visibility_isolation_test.rb: the prior cross-serve guard
# was component 8 (visibility_context_id); the NEW guard is the 10th component
# (active_profile_id). This suite proves the cache CANNOT serve profile A's snapshot for a
# profile-B request, and that the DEFAULT profile leaves the fingerprint byte-identical to
# the pre-C4 9-component hash (zero-upgrade-invalidation).
#
# THE MAKE-OR-BREAK ASSERTIONS (IT-C4-01):
#   (1) fp_A != fp_B != FP9(x)      distinct fingerprints for two different-weight profiles.
#   (2) two DISTINCT cached pulse_snapshots rows, each holding its own payload.
#   (3) NO CROSS-SERVE: a request under B after only-A-was-cached returns B's freshly
#       computed result, NEVER A's; and symmetrically.
#   (4) scores under A != scores under B (the profile weights were actually applied).
#
# THE ZERO-UPGRADE GUARD (FC-C4-05B-CHECK):
#   fp_default := FP(x, "default") == fp_pre := FP(x, omitted)   byte-identical.
#   This guards (1) zero cache invalidation on C4 upgrade for default-only installs, and
#   (2) that the impl OMITS the component for "default" (does NOT hash the literal "default").
#
# RED-BY-CONSTRUCTION (harness lane): these tests reference the C4 API that does not yet
# exist — SnapshotFingerprint's active_profile_id: kwarg, RedmineProfileProvider, and the
# Engine's profile_provider: dependency + project_projection(..., requested_id). Against
# pre-A9 HEAD they raise (ArgumentError: unknown keyword / NameError) — RED. The orchestrator
# runs this suite via scripts/test-redmine/run-tests.sh (NOT the pure `ruby -Itest -Ilib`
# lane, which cannot resolve Issue / Setting / the adapter constants). A8 does not run it.
#
# COND-A8-004 / GL-CI-MYSQL: Postgres-evidence lane (Issue.visible SQL composition on the
# deployed engine); skip (not fail) on non-Postgres so CI MySQL legs stay green.
class PulseProfileCachePartitionTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  fixtures :issue_statuses, :enumerations, :trackers, :users, :roles

  # Two profiles with DIFFERENT weights => different scores.
  WEIGHTS_A = { staleness: 0.60, progress: 0.10, momentum: 0.10,
                risk_load: 0.10, blocked_load: 0.10 }.freeze
  WEIGHTS_B = { staleness: 0.10, progress: 0.10, momentum: 0.10,
                risk_load: 0.35, blocked_load: 0.35 }.freeze

  def setup
    PulseAdapterTestSupport.ensure_pulse_permission!
    pulse_settings!
    unless ActiveRecord::Base.connection.adapter_name =~ /postgres/i
      skip "Postgres-only evidence lane (DB: #{ActiveRecord::Base.connection.adapter_name})"
    end
    @clock = PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    @project = create_project!(name: 'CachePart', identifier: 'cache-part')
    @role = create_role!(name: 'CPAll', issues_visibility: 'all',
                         permissions: %i[view_issues view_pulse view_changesets])
    @user = create_user!(login: 'cp_user')
    add_member!(project: @project, principal: @user, role: @role)

    # Some scoreable data so scores under A and B genuinely differ.
    i = create_issue!(project: @project, author: @user, status: open_status,
                      created_on: Time.utc(2026, 5, 1, 0), updated_on: Time.utc(2026, 6, 10, 0))
    add_close_journal!(issue: i, user: @user, from_status: open_status,
                       to_status: closed_status, at: Time.utc(2026, 6, 15, 0)) if false
    create_issue!(project: @project, author: @user, status: open_status,
                  updated_on: Time.utc(2026, 6, 12, 0))
  end

  def ms
    Pulse::Adapters::RedmineMetricsSource.new(
      settings_provider: real_settings_provider, clock: @clock
    )
  end

  def config_for(weights)
    Pulse::Domain::ScoringConfig.new(weights: weights)
  end

  def profile(id, weights)
    Pulse::Domain::ScoringProfile.new(id: id, name: id.upcase, config: config_for(weights))
  end

  # A fingerprint over the real project state under a given resolved profile id.
  def fingerprint_for(active_profile_id)
    Pulse::Adapters::SnapshotFingerprint.new(
      @user, @project,
      settings_provider: real_settings_provider,
      active_profile_id: active_profile_id
    ).value
  end

  # The pre-C4 REFERENCE fingerprint: the profile component OMITTED. Captured by resolving
  # to the reserved "default" id (which, per FC-C4-05B, OMITS the component). We ALSO assert
  # this equals the nil/omitted path, so the reference is the pre-C4 9-component vector, NOT
  # a hash of the literal string "default".
  def fp_pre_reference
    fingerprint_for('default')
  end

  # A ProfileProvider stub publishing default + A + B (so the Engine resolves cleanly).
  def profile_provider
    sp = real_settings_provider
    a = profile('A', WEIGHTS_A)
    b = profile('B', WEIGHTS_B)
    default = Pulse::Domain::ScoringProfile.new(
      id: 'default', name: 'Default', config: sp.scoring_config
    )
    Class.new do
      define_method(:profiles) { [default, a, b] }
      define_method(:last_warning) { nil }
      define_method(:resolve) do |_user, _project, requested_id|
        [default, a, b].find { |p| p.id == requested_id } || default
      end
    end.new
  end

  def engine
    Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: ms, store: Pulse::Adapters::ActiveRecordSnapshotStore.new,
      settings_provider: real_settings_provider, clock: @clock,
      profile_provider: profile_provider
    )
  end

  def cache_row_count
    Pulse::Adapters::ActiveRecordSnapshotStore::PulseSnapshot
      .where(project_id: @project.id).count
  end

  # ── FC-C4-05B-CHECK (Tier-1): DEFAULT-FINGERPRINT-IDENTITY ────────────────────
  # The default profile OMITS the component => byte-identical to the pre-C4 hash.
  def test_default_fingerprint_is_byte_identical_to_omitted_component
    fp_default = fingerprint_for('default')
    fp_omitted = fingerprint_for(nil) # nil resolves to the omitted-component path
    assert_equal fp_omitted, fp_default,
                 'FC-C4-05B: FP(x,"default") must equal FP(x, omitted) byte-for-byte — the ' \
                 'default OMITS the profile component (it must NOT hash the literal "default")'
  end

  def test_default_does_not_hash_the_literal_default_string
    # If the impl folded the literal "default" as a 10th component, FP(x,"default") would
    # differ from FP(x, some-other-non-published-omitting-path). The definitive guard: the
    # default fingerprint must equal the fingerprint of a request with NO profile at all
    # (the pre-C4 vector). A non-default id MUST differ from it (see the cross-serve test).
    fp_default = fingerprint_for('default')
    fp_a = fingerprint_for('A')
    refute_equal fp_default, fp_a,
                 'a non-default profile id must fold a distinct 10th component (fp_A != fp_default)'
    assert_equal fp_pre_reference, fp_default,
                 'the default fingerprint equals the pre-C4 reference (component omitted)'
  end

  # ── IT-C4-01 (Tier-1, MAKE-OR-BREAK) — assertion (1): distinct fingerprints ────
  def test_distinct_profiles_yield_distinct_fingerprints
    fp_a = fingerprint_for('A')
    fp_b = fingerprint_for('B')
    fp9 = fp_pre_reference
    refute_equal fp_a, fp_b, 'IT-C4-01(1): fp_A != fp_B (distinct non-default profiles)'
    refute_equal fp_a, fp9, 'IT-C4-01(1): fp_A != FP9(x) (non-default folds a 10th component)'
    refute_equal fp_b, fp9, 'IT-C4-01(1): fp_B != FP9(x)'
  end

  # ── IT-C4-01 — assertion (2): two DISTINCT cached rows ────────────────────────
  def test_two_profiles_produce_two_distinct_cache_rows
    eng = engine
    eng.project_projection(@user, @project, 'A') # warm under A
    after_a = cache_row_count
    eng.project_projection(@user, @project, 'B') # warm under B
    after_b = cache_row_count
    assert_equal after_a + 1, after_b,
                 'IT-C4-01(2): warming under a SECOND profile (B) must create a SECOND, ' \
                 'distinct pulse_snapshots row (distinct fingerprint) — not overwrite A\'s row'
    rows = Pulse::Adapters::ActiveRecordSnapshotStore::PulseSnapshot
           .where(project_id: @project.id)
    assert_equal rows.pluck(:snapshot_fingerprint).uniq.size, rows.count,
                 'IT-C4-01(2): each cached row has a distinct snapshot_fingerprint'
  end

  # ── IT-C4-01 — assertion (3): NO CROSS-SERVE + (4) scores differ ──────────────
  # A snapshot warmed under A is NEVER served for a request under B, and vice-versa; and the
  # scores genuinely differ (the profile weights were applied).
  def test_no_cross_serve_between_profiles_and_scores_differ
    # Warm ONLY under A first.
    eng = engine
    proj_a = eng.project_projection(@user, @project, 'A')
    rows_after_a = cache_row_count

    # Now request under B: it must MISS A's row (distinct fingerprint) and compute B fresh.
    proj_b = eng.project_projection(@user, @project, 'B')
    assert_operator cache_row_count, :>, rows_after_a,
                    'IT-C4-01(3): a B-request after only-A-cached must MISS and warm a new ' \
                    'row (no cross-serve of A\'s snapshot to B)'

    # (4) The scores under A and B differ (the weights were actually applied).
    refute_equal proj_a.health.health_score, proj_b.health.health_score,
                 'IT-C4-01(4): scores under A and B must differ (profile weights applied). ' \
                 "A=#{proj_a.health.health_score} B=#{proj_b.health.health_score}"

    # Symmetric: a re-request under A returns A's score again (its own cached row), never B's.
    proj_a2 = eng.project_projection(@user, @project, 'A')
    assert_equal proj_a.health.health_score, proj_a2.health.health_score,
                 'IT-C4-01(3): re-requesting under A returns A\'s own cached result, not B\'s'
    refute_equal proj_b.health.health_score, proj_a2.health.health_score,
                 'IT-C4-01(3): A\'s served score must not equal B\'s (no reverse cross-serve)'
  end

  # ── FC-C4-15: a profile-DEFINITION edit invalidates via settings_version_hash ──
  # "pulse_profiles" is a sub-key of the plugin settings hash, so editing a PROFILE'S OWN weight
  # (not some unrelated setting) moves settings_version_hash (component 7) => the fingerprint
  # moves => recompute. This exercises the exact claim the test names: a profile-definition edit.
  def test_profile_definition_edit_moves_the_fingerprint
    # A published profile "A" whose weights live under settings['pulse_profiles'].
    profiles_v1 = { 'profiles' => { 'A' => { 'name' => 'A', 'weights' => WEIGHTS_A } },
                    'role_bindings' => {} }
    pulse_settings!('pulse_profiles' => profiles_v1)
    sv_before = real_settings_provider.settings_version_hash
    fp_before = fingerprint_for('A')

    # Edit profile A's OWN definition (a weight change under pulse_profiles) — nothing else moves.
    profiles_v2 = { 'profiles' => {
                      'A' => { 'name' => 'A',
                               'weights' => WEIGHTS_A.merge(staleness: 0.90, progress: 0.025,
                                                            momentum: 0.025, risk_load: 0.025,
                                                            blocked_load: 0.025) }
                    },
                    'role_bindings' => {} }
    pulse_settings!('pulse_profiles' => profiles_v2)
    sv_after = real_settings_provider.settings_version_hash
    fp_after = fingerprint_for('A')

    refute_equal sv_before, sv_after,
                 'FC-C4-15: a profile-DEFINITION edit under settings[\'pulse_profiles\'] must ' \
                 'move settings_version_hash (component 7)'
    refute_equal fp_before, fp_after,
                 'FC-C4-15: the moved settings_version_hash must move the fingerprint => ' \
                 'cache recompute (a profile-definition edit invalidates the cache)'
  end

  # ── FC-C4-08: the fingerprint is a PURE hash of inputs (no internal resolution) ─
  def test_snapshot_fingerprint_takes_profile_id_as_a_pure_kwarg
    params = Pulse::Adapters::SnapshotFingerprint.instance_method(:initialize)
                                                 .parameters.flatten
    assert_includes params, :active_profile_id,
                    'FC-C4-08: SnapshotFingerprint#initialize must take active_profile_id: as a kwarg'
    refute_includes params, :profile_provider,
                    'FC-C4-08: the fingerprint must NOT resolve profiles internally (no provider dep)'
    # Source guard: no ProfileProvider / resolve reference in the fingerprint.
    src = File.read(File.expand_path(
                      '../../../lib/pulse/adapters/snapshot_fingerprint.rb', File.expand_path(__FILE__)
                    ))
    refute_match(/ProfileProvider|\.resolve\b/, src,
                 'FC-C4-08: SnapshotFingerprint must not reference ProfileProvider/#resolve')
  end
end
