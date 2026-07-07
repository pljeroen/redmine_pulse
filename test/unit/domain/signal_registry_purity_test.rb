# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'

# The domain layer uses only the standard library.
# Structural source-scan: signal_registry.rb, scoring_config.rb and scoring.rb import
# ZERO external dependencies — stdlib / intra-pulse-domain only, no Rails/ActiveRecord/
# Redmine, no I/O, no adapter require (adapter->domain only).
#
# The file-existence check drives the suite: until lib/pulse/domain/signal_registry.rb
# exists, test_registry_file_exists fails; once the pure-domain file exists it passes.
class SignalRegistryPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  FILES = %w[
    lib/pulse/domain/signal_registry.rb
    lib/pulse/domain/scoring_config.rb
    lib/pulse/domain/scoring.rb
  ].map { |p| File.join(ROOT, p) }.freeze

  def test_registry_file_exists
    assert File.exist?(FILES[0]),
           'lib/pulse/domain/signal_registry.rb must exist (Zeitwerk: Pulse::Domain::SignalRegistry)'
  end

  def test_no_external_requires
    forbidden = [
      %r{require(_relative)?\s+['"]rails['"]},
      %r{require(_relative)?\s+['"]active_record},
      %r{require(_relative)?\s+['"]active_support},
      %r{require(_relative)?\s+['"]action_},
      %r{require(_relative)?\s+['"]redmine},
      %r{require(_relative)?\s+['"]net/},
      %r{require(_relative)?\s+['"]open-uri['"]},
      %r{require(_relative)?\s+['"]pulse/adapters}, # domain must never require an adapter
      %r{\bautoload\b},
      %r{\brequire_dependency\b}
    ]
    FILES.select { |f| File.exist?(f) }.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a forbidden require/autoload (#{pat.source})"
      end
    end
  end

  def test_requires_are_stdlib_or_intra_domain_only
    allow_stdlib = %w[date set time bigdecimal forwardable]
    FILES.select { |f| File.exist?(f) }.each do |f|
      File.read(f).each_line do |line|
        next unless line =~ /^\s*require(_relative)?\s+['"]([^'"]+)['"]/

        target = Regexp.last_match(2)
        ok = allow_stdlib.include?(target) ||
             target.start_with?('pulse/domain/', 'pulse/ports/')
        assert ok, "#{File.basename(f)}: require '#{target}' not on stdlib/intra-domain allowlist"
      end
    end
  end

  def test_no_system_time_or_io_tokens_in_registry
    skip 'registry file not yet present' unless File.exist?(FILES[0])

    banned = [
      /\bTime\.now\b/, /\bDate\.today\b/, /\bSecureRandom\b/, /\bENV\b/,
      /\bFile\.(read|open|write)\b/, /\bIO\.\w/
    ]
    src = File.read(FILES[0])
    banned.each do |pat|
      refute_match pat, src, "signal_registry.rb contains a banned system-time/entropy/IO token (#{pat.source})"
    end
  end
end
