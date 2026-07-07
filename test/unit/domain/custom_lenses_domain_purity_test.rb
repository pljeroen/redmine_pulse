# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'

# The custom-lens domain layer uses only the standard library.
# Static source-scan of the four custom-lens domain files (weight_set.rb, custom_lens.rb,
# lens_ranking.rb, built_in_lenses.rb): stdlib-only requires (or intra pulse/domain
# siblings), no framework/ORM/IO/system-time/entropy tokens, and no DSL / eval surface.
#
# The file-existence check drives the suite: until the four pure files exist it fails;
# once they exist the scan gates become live. Mirrors the timeline domain file-existence
# idiom.
class CustomLensesDomainPurityTest < Minitest::Test
  ROOT = File.expand_path('../../../..', __FILE__)
  C3_FILES = %w[weight_set.rb custom_lens.rb lens_ranking.rb built_in_lenses.rb]
             .map { |f| File.join(ROOT, 'lib/pulse/domain', f) }.freeze

  def present_files
    C3_FILES.select { |f| File.exist?(f) }
  end

  # --- driver: the four custom-lens domain files must exist ---
  def test_c3_domain_files_exist
    missing = C3_FILES.reject { |f| File.exist?(f) }
    assert_empty missing,
                 "expected the four custom-lens domain files to exist: #{missing.map { |f| File.basename(f) }.inspect}"
  end

  # --- no forbidden framework/ORM/IO requires ---
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

  # --- requires are stdlib or intra-pulse/domain siblings only ---
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

  # --- no system-time / entropy / IO tokens ---
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

  # --- no formula/expression DSL (eval family) in ANY custom-lens file ---
  def test_no_dsl_eval_surface_in_c3_files
    banned = [/\beval\b/, /\binstance_eval\b/, /\bclass_eval\b/, /\bmodule_eval\b/, /\bbinding\b/]
    present_files.each do |f|
      src = File.read(f)
      banned.each do |pat|
        refute_match pat, src, "#{File.basename(f)} must contain no DSL/eval surface (#{pat.source})"
      end
    end
  end
end
