# frozen_string_literal: true

require_relative '../../domain_test_helper'

# TL-09, TL-17 / TC-09, TC-17.
# Static source-scan of the NEW timeline domain files: no framework/ORM/IO requires
# (TC-09) and no system-time/entropy tokens (TC-17). The suite loads + runs in a bare
# Ruby process (no Rails/Redmine/DB). Mirrors the scoring-engine domain_purity_test
# idiom (FC-29/FC-05/FC-30) but scoped to the timeline sources.
#
# RED before GREEN: test_timeline_domain_files_exist fails until the timeline sources
# are created; the require in test_suite_loads_without_rails_or_redmine also raises
# LoadError until lib/pulse/domain/timeline.rb exists.
class TimelineDomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  TIMELINE_FILES = %w[
    lib/pulse/domain/timeline.rb
    lib/pulse/domain/retrospective_bucket.rb
    lib/pulse/domain/milestone_marker.rb
  ].map { |p| File.join(ROOT, p) }.freeze

  def existing_timeline_files
    TIMELINE_FILES.select { |f| File.exist?(f) }
  end

  # --- RED driver: the timeline domain files must exist ---
  def test_timeline_domain_files_exist
    missing = TIMELINE_FILES.reject { |f| File.exist?(f) }
    assert_empty missing,
                 "expected timeline domain files to exist (drives RED before GREEN): #{missing.map { |f| File.basename(f) }.join(', ')}"
  end

  # --- TC-09: no forbidden framework/ORM/IO requires ---
  def test_no_forbidden_requires_in_timeline_sources
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
    existing_timeline_files.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a forbidden require/autoload (#{pat.source})"
      end
    end
  end

  def test_requires_are_stdlib_or_intra_domain_only
    allow_stdlib = %w[date set time bigdecimal forwardable]
    existing_timeline_files.each do |f|
      File.read(f).each_line do |line|
        next unless line =~ /^\s*require(_relative)?\s+['"]([^'"]+)['"]/

        target = Regexp.last_match(2)
        ok = allow_stdlib.include?(target) ||
             target.start_with?('pulse/domain/', 'pulse/ports/') ||
             (target.start_with?('./', '../') &&
              (target.include?('pulse/domain') || target.include?('pulse/ports') || !target.include?('/')))
        assert ok, "#{File.basename(f)}: require '#{target}' not on stdlib/intra-domain allowlist"
      end
    end
  end

  # --- TC-17: no system-time / randomness / entropy / IO tokens ---
  def test_no_system_time_or_entropy_tokens
    banned = [
      /\bTime\.now\b/, /\bTime\.current\b/, /\bDate\.today\b/, /\bDateTime\.now\b/,
      /\bDateTime\.current\b/, /\bProcess\.clock_gettime\b/, /\bKernel#?sleep\b/,
      /(^|[^.])\bsleep\b/, /\bSecureRandom\b/, /\bsrand\b/, /(^|[^.\w])\brand\b/,
      /\bRandom\b/, /\bENV\[/, /\$stdin\b/, /\$stdout\b/,
      /\bFile\.(read|open|write)\b/, /\bIO\.\w/
    ]
    existing_timeline_files.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a banned system-time/entropy/IO token (#{pat.source})"
      end
    end
  end

  # --- TC-09: the timeline domain loads in a bare process (no Rails/Redmine/DB) ---
  def test_suite_loads_without_rails_or_redmine
    # Bare-process purity guard (FC-30 / TC-09): only meaningful in the pure-domain
    # lane, where Rails/Redmine are genuinely absent. Under the Redmine rake harness
    # the whole app is booted first, so Rails is present regardless of the domain --
    # the assertion would test the harness, not the domain. Skip there; the domain
    # lane is where this guard is verified.
    skip 'bare-process purity guard verified in the pure-domain lane' if defined?(Rails)
    require 'pulse/domain/timeline'
    refute defined?(Rails), 'Rails must not be loaded by the timeline domain'
    refute defined?(ActiveRecord), 'ActiveRecord must not be loaded by the timeline domain'
    refute defined?(Redmine), 'Redmine must not be loaded by the timeline domain'
  end
end
