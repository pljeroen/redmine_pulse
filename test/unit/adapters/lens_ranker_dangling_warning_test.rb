# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
require 'pulse/adapters/lens_ranker'

# ═══════════════════════════════════════════════════════════════════════════════
# dangling lens_ref surfaces a WARNING
# ═══════════════════════════════════════════════════════════════════════════════
# LensRanker.normalize_lens returns DEFAULT_LENS ('health') for an unknown key. A dangling
# lens_ref must degrade to the default lens WITH a surfaced warning — a silent default is
# NOT sufficient.
#
# This is the PURE-ADAPTER lane test — it requires only lib/pulse/adapters/lens_ranker.rb
# (no Redmine harness).
#
# The contract this test pins:
#   * a KNOWN lens key         -> normalized lens, NO warning (nil)
#   * an UNKNOWN (dangling) key -> DEFAULT_LENS ('health'), a NON-EMPTY human-readable
#     warning String naming the dangling key
# The API surface is `normalize_lens_with_warning(raw) -> [lens, warning_or_nil]` (a pure,
# stateless companion to the existing stateless normalize_lens — no module-level mutable
# @last_warning, consistent with the no-data ranking module's purity).
class LensRankerDanglingWarningTest < Minitest::Test
  def normalize(raw)
    Pulse::Adapters::LensRanker.normalize_lens_with_warning(raw)
  end

  def test_known_lens_key_normalizes_without_warning
    Pulse::Adapters::LensRanker::LENSES.each do |lens|
      normalized, warning = normalize(lens)
      assert_equal lens, normalized, "a known lens '#{lens}' normalizes to itself"
      assert_nil warning, "a known lens '#{lens}' must NOT surface a warning"
    end
  end

  def test_dangling_lens_key_falls_back_to_health_with_warning
    normalized, warning = normalize('a-lens-that-was-removed')

    assert_equal Pulse::Adapters::LensRanker::DEFAULT_LENS, normalized,
                 'a dangling lens_ref must fall back to the default lens (health)'
    refute_nil warning, 'a dangling lens_ref MUST surface a warning'
    assert_kind_of String, warning, 'the warning is a human-readable String'
    refute warning.strip.empty?, 'the warning must be non-empty'
    assert_match(/a-lens-that-was-removed/, warning,
                 'the warning must name the dangling lens key so the operator can diagnose it')
  end

  def test_nil_lens_is_not_treated_as_dangling
    # nil / blank means "no explicit lens" -> the cockpit default, NOT a dangling ref. It
    # must NOT surface a dangling-warning (only a REMOVED user-authored key does).
    normalized, warning = normalize(nil)
    assert_equal Pulse::Adapters::LensRanker::DEFAULT_LENS, normalized,
                 'a nil lens_ref resolves to the default lens'
    assert_nil warning, 'a nil lens_ref is "no explicit lens", not a dangling ref -> no warning'
  end
end
