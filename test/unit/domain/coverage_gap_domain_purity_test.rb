# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'

# The domain layer uses only the standard library (or intra-pulse-domain requires):
# the coverage-gap domain files import ZERO external deps — no Rails/ActiveRecord/Redmine,
# no I/O, no adapter require (adapter->domain only). The adapter (RedmineMetricsSource)
# does ALL AR I/O.
#
# Structural source-scan of the four coverage-gap domain files (signals.rb gains
# coverage_gap; signal_registry.rb gains default_on + coverage_gap; scoring.rb gains the
# compute_signal branch; project_metrics.rb gains the two coverage fields). If a file is
# missing the test flags it; the scan passes as long as the files stay pure (no external
# dep introduced in the coverage-gap edits).
class CoverageGapDomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  FILES = %w[
    lib/pulse/domain/signals.rb
    lib/pulse/domain/signal_registry.rb
    lib/pulse/domain/scoring.rb
    lib/pulse/domain/project_metrics.rb
  ].map { |p| File.join(ROOT, p) }.freeze

  def test_all_c2_domain_files_exist
    FILES.each { |f| assert File.exist?(f), "coverage-gap domain file must exist: #{f}" }
  end

  def test_no_external_or_adapter_requires
    forbidden = [
      %r{require(_relative)?\s+['"]rails['"]},
      %r{require(_relative)?\s+['"]active_record},
      %r{require(_relative)?\s+['"]active_support},
      %r{require(_relative)?\s+['"]action_},
      %r{require(_relative)?\s+['"]redmine},
      %r{require(_relative)?\s+['"]net/},
      %r{require(_relative)?\s+['"]open-uri['"]},
      %r{require\s+['"]pulse/adapters}, # domain must NEVER require an adapter
      %r{\bautoload\b},
      %r{\brequire_dependency\b}
    ]
    FILES.select { |f| File.exist?(f) }.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src,
                     "#{File.basename(f)}: forbidden external/adapter require (#{pat.source})"
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

  def test_no_ar_or_redmine_constants_in_c2_domain_files
    banned = [
      /\bActiveRecord\b/, /\bApplicationRecord\b/, /\bIssue\b/, /\bProject\b/,
      /\bTime\.now\b/, /\bDate\.today\b/, /\bSecureRandom\b/, /\bENV\b/,
      /\bFile\.(read|open|write)\b/
    ]
    FILES.select { |f| File.exist?(f) }.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src,
                     "#{File.basename(f)}: banned AR/Redmine/system token #{pat.source}"
      end
    end
  end
end
