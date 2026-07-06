# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# FC-C2-15 (i18n) — the coverage_gap presentation + settings labels exist in BOTH en.yml
# AND nl.yml (the documented locale gotcha: a key present in only one locale raises
# translation-missing at render). Any "N% covered" unit key must appear in BOTH singular
# and plural in BOTH locales. Discharges FR-C2-07.
#
# Pure test (reads the locale YAML directly — no Redmine). RED until A9 adds the keys.
class LocalesCoverageGapTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)
  EN = File.join(ROOT, 'config/locales/en.yml')
  NL = File.join(ROOT, 'config/locales/nl.yml')

  # The coverage_gap keys REQUIRED in both locales (weight label + help, enable label + help,
  # and the planning-coverage display label).
  REQUIRED_KEYS = %w[
    label_pulse_weight_coverage_gap
    label_pulse_help_weight_coverage_gap
    label_pulse_enable_coverage_gap
    label_pulse_help_enable_coverage_gap
    label_pulse_planning_coverage
  ].freeze

  def locale_hash(path, lang)
    YAML.safe_load_file(path)[lang] || {}
  end

  def en
    @en ||= locale_hash(EN, 'en')
  end

  def nl
    @nl ||= locale_hash(NL, 'nl')
  end

  # --- the coverage_gap labels exist in BOTH locales ----------------------------------
  def test_required_coverage_gap_keys_present_in_english
    REQUIRED_KEYS.each do |k|
      assert en.key?(k), "en.yml missing coverage_gap key #{k} (FC-C2-15 i18n)"
      refute_nil en[k], "en.yml #{k} must have a value"
    end
  end

  def test_required_coverage_gap_keys_present_in_dutch
    REQUIRED_KEYS.each do |k|
      assert nl.key?(k), "nl.yml missing coverage_gap key #{k} (FC-C2-15 i18n — locale gotcha)"
      refute_nil nl[k], "nl.yml #{k} must have a value"
    end
  end

  # --- if a "covered" unit key is used, BOTH singular AND plural in BOTH locales -------
  # The presenter renders "planning coverage N%". If a unit noun ("N issue(s) covered") is
  # introduced under the pulse.* namespace, both forms must exist in both locales (mirrors
  # the existing pulse.unit_* singular+plural rule at en.yml:62-73 / nl.yml:50-57).
  def test_covered_unit_singular_and_plural_parity_across_locales
    en_pulse = en['pulse'] || {}
    nl_pulse = nl['pulse'] || {}
    covered_keys = (en_pulse.keys + nl_pulse.keys).uniq.select { |k| k.to_s =~ /cover/ }
    covered_keys.each do |k|
      assert en_pulse.key?(k), "pulse.#{k} present in en.yml (both locales must carry it)"
      assert nl_pulse.key?(k), "pulse.#{k} present in nl.yml (both locales must carry it)"
      # If a plural form exists (ends in 's'), the singular must too, and vice-versa.
      base = k.to_s.sub(/s\z/, '')
      next if base == k.to_s

      singular = base
      plural = "#{base}s"
      %w[en nl].each do |loc|
        h = loc == 'en' ? en_pulse : nl_pulse
        if h.key?(plural) || h.key?(singular)
          assert h.key?(singular), "#{loc}.yml pulse.#{singular} (singular) must accompany the plural (FC-C2-15)"
          assert h.key?(plural), "#{loc}.yml pulse.#{plural} (plural) must accompany the singular (FC-C2-15)"
        end
      end
    end
  end
end
