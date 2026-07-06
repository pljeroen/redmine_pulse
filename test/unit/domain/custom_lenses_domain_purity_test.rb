# frozen_string_literal: true

require_relative '../../domain_test_helper'

# FR-C3-04, INV-PURE-DOMAIN / FC-C3-14, FC-C3-18.
# Static source-scan of the four NEW C3 domain files (weight_set.rb, custom_lens.rb,
# lens_ranking.rb, built_in_lenses.rb): stdlib-only requires (or intra pulse/domain
# siblings), no framework/ORM/IO/system-time/entropy tokens, and no DSL / eval surface.
#
# RED NOW: test_c3_domain_files_exist FAILS (the four files are unimplemented). Once A9
# creates the pure files, the file-existence driver goes GREEN and the scan gates become
# live. This mirrors the timeline_domain_purity_test file-existence RED idiom.
class CustomLensesDomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  C3_FILES = %w[weight_set.rb custom_lens.rb lens_ranking.rb built_in_lenses.rb]
             .map { |f| File.join(ROOT, 'lib/pulse/domain', f) }.freeze

  def present_files
    C3_FILES.select { |f| File.exist?(f) }
  end

  # --- RED driver: the four C3 domain files must exist ---
  def test_c3_domain_files_exist
    missing = C3_FILES.reject { |f| File.exist?(f) }
    assert_empty missing,
                 "expected the four C3 domain files to exist (drives RED before GREEN): #{missing.map { |f| File.basename(f) }.inspect}"
  end

  # --- FC-C3-18: no forbidden framework/ORM/IO requires ---
  def test_no_forbidden_requires_in_c3_files
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
    present_files.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a forbidden require/autoload (#{pat.source})"
      end
    end
  end

  # --- FC-C3-18: requires are stdlib or intra-pulse/domain siblings only ---
  def test_requires_are_stdlib_or_intra_domain_only
    allow_stdlib = %w[date set time bigdecimal forwardable]
    present_files.each do |f|
      File.read(f).each_line do |line|
        next unless line =~ /^\s*require(_relative)?\s+['"]([^'"]+)['"]/

        target = Regexp.last_match(2)
        ok = allow_stdlib.include?(target) ||
             target.start_with?('pulse/domain/', 'pulse/ports/') ||
             (target.start_with?('./', '../') && (target.include?('pulse/domain') || !target.include?('/')))
        assert ok, "#{File.basename(f)}: require '#{target}' not on stdlib/intra-domain allowlist"
      end
    end
  end

  # --- FC-C3-18: no system-time / entropy / IO tokens ---
  def test_no_system_time_or_entropy_tokens
    banned = [
      /\bTime\.now\b/, /\bTime\.current\b/, /\bDate\.today\b/, /\bDateTime\.now\b/,
      /\bProcess\.clock_gettime\b/, /(^|[^.])\bsleep\b/,
      /\bSecureRandom\b/, /\bsrand\b/, /(^|[^.\w])\brand\b/, /\bRandom\b/,
      /\bENV\b/, /\$stdin\b/, /\$stdout\b/, /\bFile\.(read|open|write)\b/, /\bIO\.\w/
    ]
    present_files.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src, "#{File.basename(f)} contains a banned system-time/entropy/IO token (#{pat.source})"
      end
    end
  end

  # --- FC-C3-14: no formula/expression DSL (eval family) in ANY C3 file ---
  def test_no_dsl_eval_surface_in_c3_files
    banned = [/\beval\b/, /\binstance_eval\b/, /\bclass_eval\b/, /\bmodule_eval\b/, /\bbinding\b/]
    present_files.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src, "#{File.basename(f)} must contain no DSL/eval surface (#{pat.source}) — FC-C3-14"
      end
    end
  end
end
