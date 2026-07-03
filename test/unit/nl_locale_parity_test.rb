# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'yaml'

# The Dutch locale (config/locales/nl.yml) MUST cover exactly the same key set as the
# English source (config/locales/en.yml) — no missing keys (which would silently fall
# back to English) and no stray keys — and MUST preserve every %{...} interpolation
# placeholder per key (dropping %{n}/%{unit}/%{state}/%{fields} would break rendering).
# This is the mechanical completeness guard for the translation; it runs standalone.
class NlLocaleParityTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)
  EN = File.join(ROOT, 'config/locales/en.yml')
  NL = File.join(ROOT, 'config/locales/nl.yml')

  def flatten(node, prefix = nil, acc = {})
    node.each do |k, v|
      key = prefix ? "#{prefix}.#{k}" : k.to_s
      v.is_a?(Hash) ? flatten(v, key, acc) : (acc[key] = v)
    end
    acc
  end

  def en_flat
    flatten(YAML.load_file(EN)['en'])
  end

  def nl_flat
    flatten(YAML.load_file(NL)['nl'])
  end

  def placeholders(str)
    str.to_s.scan(/%\{[^}]+\}/).sort
  end

  def test_nl_locale_file_exists_with_nl_root
    assert File.exist?(NL), 'config/locales/nl.yml must exist'
    assert_equal ['nl'], YAML.load_file(NL).keys,
                 "nl.yml must have exactly one root key, 'nl' (no stray en:/other roots)"
  end

  def test_nl_covers_exactly_the_english_key_set
    en = en_flat.keys.sort
    nl = nl_flat.keys.sort
    assert_empty(en - nl, "nl.yml is missing keys present in en.yml: #{(en - nl).inspect}")
    assert_empty(nl - en, "nl.yml has keys not present in en.yml: #{(nl - en).inspect}")
  end

  def test_nl_preserves_interpolation_placeholders
    en = en_flat
    nl = nl_flat
    en.each_key do |k|
      next unless nl.key?(k)

      assert_equal placeholders(en[k]), placeholders(nl[k]),
                   "nl.yml key #{k} must keep the same %{...} placeholders as en.yml"
    end
  end

  def test_nl_has_no_empty_values
    empties = nl_flat.select { |_k, v| v.to_s.strip.empty? }.keys
    assert_empty empties, "nl.yml has empty translations: #{empties.inspect}"
  end
end
