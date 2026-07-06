# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'

# IT-C4-03 (domain slice) — FR-C4-01 / FR-C4-07 / FC-C4-01, FC-C4-02, FC-C4-03,
# FC-C4-04, FC-C4-16. The Pulse::Domain::ScoringProfile frozen value object:
#   {id: String, name: String, config: ScoringConfig}
#   * frozen at construction (FrozenError on mutation);
#   * id/name stored as dup.freeze'd copies (THE immutability-hole lesson from
#     timeline-engine — mutating the ORIGINAL String argument must NOT change p.id/p.name);
#   * invalid id / name / config => ArgumentError (no partial build);
#   * config is a full, independently-validated ScoringConfig (two profiles MAY carry
#     different enabled sets — one enables coverage_gap, another does not).
#
# RED NOW: Pulse::Domain::ScoringProfile is unimplemented -> `require` raises LoadError
# (NameError on first reference). GREEN after A9 creates lib/pulse/domain/scoring_profile.rb
# to the exact public API these tests pin. Pure-domain lane: ruby -Itest -Ilib.
class ScoringProfileTest < Minitest::Test
  SP = Pulse::Domain::ScoringProfile
  SC = Pulse::Domain::ScoringConfig
  R  = Pulse::Domain::SignalRegistry

  # A valid ScoringConfig over the 5 default_on signals (Σweights == 1.0).
  def valid_config
    SC.new
  end

  # A valid ScoringConfig that ENABLES coverage_gap (registered, default_on:false).
  def coverage_gap_config
    six = R.default_weights.merge(coverage_gap: R.fetch(:coverage_gap).default_weight)
    total = six.values.sum
    SC.new(weights: six.transform_values { |w| w / total })
  end

  # A valid ScoringConfig with reweighted (but same-signal) weights => different scoring.
  def reweighted_config
    SC.new(weights: { staleness: 0.5, progress: 0.2, momentum: 0.1,
                      risk_load: 0.1, blocked_load: 0.1 })
  end

  # === FC-C4-01: valid construction ===========================================
  def test_valid_construction_exposes_id_name_config
    c = valid_config
    p = SP.new(id: 'balanced', name: 'Balanced', config: c)
    assert_instance_of SP, p
    assert_equal 'balanced', p.id
    assert_equal 'Balanced', p.name
    assert p.id.is_a?(String), 'id is a String'
    assert p.name.is_a?(String), 'name is a String'
  end

  def test_config_is_the_supplied_scoring_config
    c = valid_config
    p = SP.new(id: 'x', name: 'X', config: c)
    assert p.config.is_a?(SC), 'config is a Pulse::Domain::ScoringConfig'
    assert_equal c.weights, p.config.weights,
                 'the profile carries the supplied config content'
    assert p.config.frozen?, 'the config is frozen (FC-C4-01)'
  end

  # === FC-C4-01 / FC-C4-03: frozen VO =========================================
  def test_profile_is_frozen
    p = SP.new(id: 'x', name: 'X', config: valid_config)
    assert p.frozen?, 'ScoringProfile must be frozen at construction (FC-C4-01/FC-C4-03)'
  end

  def test_instance_variable_mutation_raises_frozen_error
    p = SP.new(id: 'x', name: 'X', config: valid_config)
    assert_raises(FrozenError) { p.instance_variable_set(:@id, 'other') }
  end

  # === FC-C4-03: deep immutability — id/name are dup.freeze'd copies ===========
  # THE immutability-hole lesson: a frozen VO with a String field is still mutable
  # through the caller's retained reference unless the field is dup.freeze'd internally.
  def test_mutating_original_id_string_does_not_change_profile
    src = +'balanced' # unfrozen source String
    p = SP.new(id: src, name: +'Balanced', config: valid_config)
    src << '-mutated'
    assert_equal 'balanced', p.id,
                 'IMMUTABILITY HOLE: mutating the ORIGINAL id String changed p.id — ' \
                 'the VO must store a dup.freeze copy (the timeline-engine lesson)'
  end

  def test_mutating_original_name_string_does_not_change_profile
    src = +'Balanced'
    p = SP.new(id: +'x', name: src, config: valid_config)
    src << '-mutated'
    assert_equal 'Balanced', p.name,
                 'IMMUTABILITY HOLE: mutating the ORIGINAL name String changed p.name'
  end

  def test_stored_id_and_name_are_frozen
    p = SP.new(id: +'x', name: +'X', config: valid_config)
    assert p.id.frozen?, 'p.id must be a frozen String'
    assert p.name.frozen?, 'p.name must be a frozen String'
  end

  def test_mutating_returned_id_raises_frozen_error
    p = SP.new(id: +'x', name: +'X', config: valid_config)
    assert_raises(FrozenError) { p.id << 'z' }
  end

  def test_mutating_returned_name_raises_frozen_error
    p = SP.new(id: +'x', name: +'X', config: valid_config)
    assert_raises(FrozenError) { p.name << 'z' }
  end

  # === FC-C4-02: invalid construction => ArgumentError (no partial build) ======
  def test_nil_id_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: nil, name: 'X', config: valid_config) }
  end

  def test_empty_id_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: '', name: 'X', config: valid_config) }
  end

  def test_whitespace_only_id_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: '   ', name: 'X', config: valid_config) }
  end

  def test_non_string_id_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: :sym, name: 'X', config: valid_config) }
  end

  def test_nil_name_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: 'x', name: nil, config: valid_config) }
  end

  def test_empty_name_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: 'x', name: '', config: valid_config) }
  end

  def test_non_string_name_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: 'x', name: 123, config: valid_config) }
  end

  def test_nil_config_raises_argument_error
    assert_raises(ArgumentError) { SP.new(id: 'x', name: 'X', config: nil) }
  end

  def test_non_scoring_config_config_raises_argument_error
    # A leaking TypeError/NoMethodError from a downstream comparison is a FAILURE —
    # the VO must reject a non-ScoringConfig with a loud ArgumentError.
    err = assert_raises(StandardError) { SP.new(id: 'x', name: 'X', config: Object.new) }
    assert_instance_of ArgumentError, err,
                       'a non-ScoringConfig config must fail loud as ArgumentError'
  end

  # === FC-C4-04 / FC-C4-02: config validation is NOT bypassed by the profile ===
  # A ScoringConfig with Σweights != 1.0 raises at ScoringConfig.new, so no invalid
  # config can reach ScoringProfile (validation reuse, unchanged C1 behavior).
  def test_invalid_config_weights_raise_at_config_construction
    assert_raises(ArgumentError) do
      SP.new(id: 'x', name: 'X',
             config: SC.new(weights: { staleness: 0.9, progress: 0.9 })) # Σ != 1.0
    end
  end

  # === FC-C4-04: two profiles MAY carry DIFFERENT enabled sets =================
  def test_two_profiles_may_have_different_enabled_sets
    a = SP.new(id: 'cov', name: 'Coverage', config: coverage_gap_config)
    b = SP.new(id: 'base', name: 'Base', config: valid_config)
    assert_includes a.config.enabled_signals, :coverage_gap,
                    'profile A enables coverage_gap'
    refute_includes b.config.enabled_signals, :coverage_gap,
                    'profile B does not enable coverage_gap'
    refute_equal a.config.enabled_signals, b.config.enabled_signals,
                 'the two profiles carry different enabled sets (FC-C4-04)'
  end

  def test_reweighted_profile_carries_its_own_weights
    p = SP.new(id: 'heavy-stale', name: 'Heavy Staleness', config: reweighted_config)
    assert_in_delta 0.5, p.config.weights[:staleness], 1e-9,
                    'the profile carries its own (reweighted) config weights'
  end

  # === FC-C4-16: pure domain — no adapter / AR / Setting reference =============
  def test_source_is_pure_domain
    src = File.read(
      File.expand_path('../../../../lib/pulse/domain/scoring_profile.rb', __FILE__)
    )
    %w[ActiveRecord Setting Redmine Pulse::Adapters Pulse::Ports Rails].each do |tok|
      refute_match(/\b#{Regexp.escape(tok)}\b/, src,
                   "scoring_profile.rb must not reference #{tok} (FC-C4-16 pure domain)")
    end
  end
end
