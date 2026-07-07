# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'yaml'

# I18N COVERAGE (a hard pass/fail lint).
# Path-based (no Redmine env): scans app/views/**/*.erb + app/controllers/*.rb and
# asserts (a) every key used in a t()/I18n.t() call resolves in config/locales/en.yml,
# and (b) the 5 canonicalized keys are present. Developer-facing strings (logs,
# exception messages) are exempt.
class I18nCoverageTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)
  LOCALE = File.join(ROOT, 'config/locales/en.yml')

  NEW_KEYS = %w[
    label_pulse_visibility_note
    label_pulse_rag_red
    label_pulse_rag_amber
    label_pulse_rag_green
    label_pulse_rag_aria_label
  ].freeze

  def locale_keys
    tree = YAML.load_file(LOCALE)['en'] || {}
    flatten_keys(tree)
  end

  # Flatten nested locale hashes into dotted keys AND bare leaf keys (Redmine uses both
  # `label_x` flat keys and nested `pulse.x` namespaces).
  def flatten_keys(node, prefix = nil, acc = [])
    node.each do |k, v|
      key = prefix ? "#{prefix}.#{k}" : k.to_s
      if v.is_a?(Hash)
        flatten_keys(v, key, acc)
      else
        acc << key
        acc << k.to_s # also record the bare leaf for flat-key lookups
      end
    end
    acc
  end

  def used_keys
    files = Dir[File.join(ROOT, 'app/views/**/*.erb')] +
            Dir[File.join(ROOT, 'app/controllers/*.rb')]
    keys = []
    files.each do |f|
      src = File.read(f)
      # t('key') / t(:key) / I18n.t('key') / I18n.t(:key)
      src.scan(/\b(?:I18n\.)?t\(\s*[:'"]([a-zA-Z0-9_.]+)['"\s,)]/).each { |m| keys << m.first }
    end
    keys.uniq
  end

  # ──────────── (b) the 5 new canonicalized keys MUST be present ─────────────

  def test_new_canonicalized_keys_present
    have = locale_keys
    NEW_KEYS.each do |k|
      assert_includes have, k,
                      "config/locales/en.yml must define #{k}"
    end
  end

  # ──────────── (a) every t() key used in views/controllers resolves ─────────

  def test_every_used_key_resolves_in_en_yml
    have = locale_keys
    erbs = Dir[File.join(ROOT, 'app/views/**/*.erb')]
    flunk 'no views found' if erbs.empty?
    missing = used_keys.reject { |k| have.include?(k) || have.include?(k.split('.').last) }
    assert_empty missing,
                 "t() keys with no en.yml entry: #{missing.inspect}"
  end

  # ── snapshot-max-age-refresh: the new label + help keys ───
  # The freshness-cap setting adds a label and an inline-help i18n key; both must be
  # defined in en.yml.

  SNAPSHOT_MAX_AGE_KEYS = %w[
    label_pulse_snapshot_max_age_minutes
    label_pulse_help_snapshot_max_age_minutes
  ].freeze

  def test_snapshot_max_age_i18n_keys_present
    have = locale_keys
    SNAPSHOT_MAX_AGE_KEYS.each do |k|
      assert_includes have, k,
                      "config/locales/en.yml must define #{k} (snapshot-max-age-refresh)"
    end
  end

  # ──────────── existing keys remain (no regression) ─────────────────────────

  def test_baseline_keys_still_present
    have = locale_keys
    %w[label_pulse label_pulse_portfolio project_module_pulse].each do |k|
      assert_includes have, k, "baseline key #{k} must remain"
    end
  end
end
