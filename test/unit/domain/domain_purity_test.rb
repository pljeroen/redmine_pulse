# frozen_string_literal: true

require_relative '../../domain_test_helper'

# FR-34, FR-35 / FC-05, FC-29, FC-30.
# Static source-scan: no framework/ORM/IO requires; no system-time/entropy tokens
# in lib/pulse/domain/ or lib/pulse/ports/. The suite itself runs in a bare Ruby
# process (no Rails/Redmine/DB).
class DomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  DOMAIN_GLOBS = [
    File.join(ROOT, 'lib/pulse/domain/*.rb'),
    File.join(ROOT, 'lib/pulse/ports/*.rb')
  ].freeze

  def domain_files
    DOMAIN_GLOBS.flat_map { |g| Dir[g] }.sort
  end

  def test_domain_files_exist
    refute_empty domain_files, 'expected implementation files under lib/pulse/domain (drives RED before GREEN)'
  end

  # --- FC-29: no forbidden requires ---
  def test_no_forbidden_requires_in_domain_and_ports
    forbidden = [
      %r{require(_relative)?\s+['"]rails['"]},
      %r{require(_relative)?\s+['"]active_record},
      %r{require(_relative)?\s+['"]active_support},
      %r{require(_relative)?\s+['"]action_},
      %r{require(_relative)?\s+['"]redmine},
      %r{require(_relative)?\s+['"]net/},
      %r{require(_relative)?\s+['"]open-uri['"]},
      %r{\bautoload\b},
      %r{\brequire_dependency\b}
    ]
    domain_files.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a forbidden require/autoload (#{pat.source})"
      end
    end
  end

  def test_requires_are_stdlib_or_intra_domain_only
    allow_stdlib = %w[date set time bigdecimal forwardable]
    domain_files.each do |f|
      File.read(f).each_line do |line|
        next unless line =~ /^\s*require(_relative)?\s+['"]([^'"]+)['"]/
        target = Regexp.last_match(2)
        ok = allow_stdlib.include?(target) ||
             target.start_with?('pulse/domain/', 'pulse/ports/') ||
             # require_relative within the same domain tree
             target.start_with?('./', '../') && (target.include?('pulse/domain') || target.include?('pulse/ports') || !target.include?('/'))
        assert ok, "#{File.basename(f)}: require '#{target}' not on stdlib/intra-domain allowlist"
      end
    end
  end

  # --- FC-05: no system-time / randomness / entropy / IO tokens ---
  def test_no_system_time_or_entropy_tokens
    banned = [
      /\bTime\.now\b/, /\bTime\.current\b/, /\bDate\.today\b/, /\bDateTime\.now\b/,
      /\bProcess\.clock_gettime\b/, /\bKernel#?sleep\b/, /(^|[^.])\bsleep\b/,
      /\bSecureRandom\b/, /\bsrand\b/, /(^|[^.\w])\brand\b/, /\bRandom\b/,
      /\bENV\b/, /\$stdin\b/, /\$stdout\b/, /\bFile\.(read|open|write)\b/, /\bIO\.\w/
    ]
    domain_files.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a banned system-time/entropy/IO token (#{pat.source})"
      end
    end
  end

  def test_suite_loads_without_rails_or_redmine
    # Bare-process purity guard (FC-30 / TC-09): only meaningful in the pure-domain
    # lane, where Rails/Redmine are genuinely absent. Under the Redmine rake harness
    # the whole app is booted first, so Rails is present regardless of the domain --
    # the assertion would test the harness, not the domain. Skip there; the domain
    # lane is where this guard is verified.
    skip 'bare-process purity guard verified in the pure-domain lane' if defined?(Rails)
    # Negative assertion: neither Rails nor Redmine constants are defined in this
    # bare process when the domain is loaded (FC-30).
    require 'pulse/domain/scoring'
    refute defined?(Rails), 'Rails must not be loaded by the domain'
    refute defined?(ActiveRecord), 'ActiveRecord must not be loaded by the domain'
    refute defined?(Redmine), 'Redmine must not be loaded by the domain'
  end
end
