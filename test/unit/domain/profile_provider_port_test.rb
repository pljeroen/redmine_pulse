# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

# Add lib/ so the port + adapter modules load in every lane (C1 harness lesson).
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'pulse/ports/profile_provider'

# FR-C4-03 / FC-C4-06 — the Pulse::Ports::ProfileProvider port contract (consumer side).
# The port is a DUCK-TYPED protocol (structural typing; stdlib only; no ABC/inheritance),
# mirroring the as-built Pulse::Ports::MetricsSource / Clock / SnapshotStore documentation
# modules. This test pins BOTH sides of the contract:
#   * PROVIDER side: the RedmineProfileProvider adapter responds to #profiles and #resolve.
#   * The port module exists, is a plain Module (not a Class / not an ABC), and introduces
#     no external dependency.
#
# RED NOW: lib/pulse/ports/profile_provider.rb does not exist -> `require` raises LoadError.
# GREEN after A9 creates it (the adapter provider-side check requires the adapter too, so it
# is guarded to skip gracefully if only the port has landed — the RedmineProfileProviderTest
# is the authoritative provider-side check).
class ProfileProviderPortTest < Minitest::Test
  # === the port is a duck-typed Module (structural typing; no ABC) ==============
  def test_profile_provider_port_is_a_plain_module
    assert defined?(Pulse::Ports::ProfileProvider),
           'Pulse::Ports::ProfileProvider must be defined'
    assert_kind_of Module, Pulse::Ports::ProfileProvider
    refute Pulse::Ports::ProfileProvider.is_a?(Class),
           'the port is a duck-typed Module, not a Class/ABC (structural typing)'
  end

  # === the port source is dependency-free (documentation module only) ===========
  def test_port_source_has_no_external_dependency
    src = File.read(
      File.expand_path('../../../../lib/pulse/ports/profile_provider.rb', __FILE__)
    )
    %w[ActiveRecord Setting Pulse::Adapters require\ 'active].each do |tok|
      refute_match(/#{Regexp.escape(tok)}/, src,
                   "the ProfileProvider port must not depend on #{tok}")
    end
  end

  # === PROVIDER side: the adapter satisfies the protocol (responds to #profiles/#resolve) =
  def test_redmine_profile_provider_satisfies_the_protocol
    begin
      require 'pulse/domain/scoring_config'
      require 'pulse/domain/scoring_profile'
      require 'pulse/adapters/redmine_profile_provider'
    rescue LoadError
      skip 'RedmineProfileProvider adapter not yet present (port-only slice)'
    end
    sp = Class.new do
      def scoring_config
        Pulse::Domain::ScoringConfig.new
      end

      def pulse_profiles
        { 'profiles' => {}, 'role_bindings' => {} }
      end
    end.new
    prov = Pulse::Adapters::RedmineProfileProvider.new(settings_provider: sp)
    assert_respond_to prov, :profiles, 'the provider must implement #profiles'
    assert_respond_to prov, :resolve, 'the provider must implement #resolve'
  end
end
