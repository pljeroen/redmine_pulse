# frozen_string_literal: true

require_relative '../../domain_test_helper'

# FC-C2-13 / INV-PURE-DOMAIN — the C2-touched domain files import ZERO external deps
# (stdlib / intra-pulse-domain only): no Rails/ActiveRecord/Redmine, no I/O, no adapter
# require (adapter->domain only). The adapter (RedmineMetricsSource) does ALL AR I/O.
#
# Structural source-scan of the FOUR C2-touched domain files (signals.rb gains
# coverage_gap; signal_registry.rb gains default_on + coverage_gap; scoring.rb gains the
# compute_signal branch; project_metrics.rb gains the two coverage fields). RED-safe: if a
# file is missing the test flags it; the scan itself passes today (the files are pure) and
# stays GREEN through A9 provided A9 does not introduce an external dep in the C2 edits.
class CoverageGapDomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  FILES = %w[
    lib/pulse/domain/signals.rb
    lib/pulse/domain/signal_registry.rb
    lib/pulse/domain/scoring.rb
    lib/pulse/domain/project_metrics.rb
  ].map { |p| File.join(ROOT, p) }.freeze

  def test_all_c2_domain_files_exist
    FILES.each { |f| assert File.exist?(f), "C2-touched domain file must exist: #{f}" }
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
      %r{require\s+['"]pulse/adapters}, # domain must NEVER require an adapter (FC-C2-13)
      %r{\bautoload\b},
      %r{\brequire_dependency\b}
    ]
    FILES.select { |f| File.exist?(f) }.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src,
                     "#{File.basename(f)}: forbidden external/adapter require (#{pat.source}) (FC-C2-13)"
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
        assert ok, "#{File.basename(f)}: require '#{target}' not on stdlib/intra-domain allowlist (FC-C2-13)"
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
                     "#{File.basename(f)}: banned AR/Redmine/system token #{pat.source} (INV-PURE-DOMAIN)"
      end
    end
  end
end
