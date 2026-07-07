# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/signal_registry'

# Pulse::Domain::SignalRegistry — the canonical static catalog: the single source of
# truth for which signals exist, in what order, with what default weight, and which
# are always-active (and which are at_risk lens-enrichment signals). Pinned values below.
class SignalRegistryTest < Minitest::Test
  R = Pulse::Domain::SignalRegistry

  # coverage_gap is a registered (but default_on:false) signal, so the registry enumerates
  # 6 keys. The 5 DEFAULT-ON built-ins are the original set; the default_weights map still
  # scopes to those 5. BUILTINS = the 5 default_on.
  BUILTINS = %i[staleness progress momentum risk_load blocked_load].freeze
  REGISTERED = %i[staleness progress momentum risk_load blocked_load coverage_gap].freeze
  CANONICAL = %i[staleness progress momentum risk_load blocked_load coverage_gap].freeze
  ALWAYS_ACTIVE = %i[staleness momentum blocked_load].freeze
  AT_RISK = %i[risk_load blocked_load staleness].freeze
  DEFAULT_WEIGHTS = {
    staleness: 0.25, progress: 0.25, momentum: 0.20, risk_load: 0.15, blocked_load: 0.15
  }.freeze

  # --- record totality (every field present + correctly typed) ---
  def test_enumerates_the_registered_signals
    assert_equal REGISTERED.sort, R.keys.sort,
                 'registry enumerates the 5 built-ins + coverage_gap'
  end

  def test_every_record_has_complete_typed_metadata
    R.keys.each do |key|
      s = R.fetch(key)
      assert_kind_of Symbol, s.key, "#{key}: key is a Symbol"
      assert_equal key, s.key, "#{key}: fetched record's key matches"
      assert_includes [true, false], s.always_active?, "#{key}: always_active? is Boolean"
      assert_kind_of Float, s.default_weight, "#{key}: default_weight is a Float"
      assert_kind_of Integer, s.canonical_order, "#{key}: canonical_order is an Integer"
      assert_includes [true, false], s.at_risk?, "#{key}: at_risk? is Boolean"
    end
  end

  # --- built-in EXACT values pinned to today's constants ------------
  def test_default_weights_pinned_exactly
    assert_equal DEFAULT_WEIGHTS, R.default_weights,
                 'default_weights reproduce ScoringConfig::DEFAULT_WEIGHTS verbatim'
  end

  def test_default_weights_sum_to_one_exactly
    assert_equal 1.0, R.default_weights.values.sum, 'Σ default_weight == 1.0 exactly'
  end

  def test_per_signal_default_weight_pinned
    DEFAULT_WEIGHTS.each do |key, w|
      assert_equal w, R.fetch(key).default_weight, "#{key}: default_weight == #{w}"
    end
  end

  def test_always_active_keys_pinned
    assert_equal ALWAYS_ACTIVE.sort, R.always_active_keys.sort,
                 'always_active_keys == {staleness, momentum, blocked_load}'
    R.keys.each do |key|
      expected = ALWAYS_ACTIVE.include?(key)
      assert_equal expected, R.fetch(key).always_active?, "#{key}: always_active? == #{expected}"
    end
  end

  def test_at_risk_keys_pinned
    assert_equal AT_RISK.sort, R.at_risk_keys.sort,
                 'at_risk_keys == {risk_load, blocked_load, staleness} (AT_RISK_KEYS moved into registry)'
    R.keys.each do |key|
      assert_equal AT_RISK.include?(key), R.fetch(key).at_risk?, "#{key}: at_risk? pinned"
    end
  end

  # The DEFAULT-ON set (what a no-arg ScoringConfig enables) is sourced from
  # default_on_keys, which is exactly the 5 built-ins — coverage_gap is registered but
  # default_on:false, so it is NOT in the default-enabled set.
  def test_default_on_keys_are_the_five_builtins
    assert_equal BUILTINS.sort, R.default_on_keys.sort,
                 'default_on_keys == the 5 built-ins (coverage_gap default_on:false excluded)'
  end

  # --- canonical_order is a TOTAL STRICT order ----------------------
  def test_canonical_order_indices_injective
    orders = R.keys.map { |k| R.fetch(k).canonical_order }
    assert_equal orders.size, orders.uniq.size,
                 'canonical_order indices are pairwise distinct (injective => no ties, total strict order)'
  end

  def test_canonical_order_reproduces_pre_c1_sequence
    ordered = R.keys.sort_by { |k| R.fetch(k).canonical_order }
    assert_equal CANONICAL, ordered,
                 'sorting by canonical_order yields the built-in sequence + coverage_gap LAST'
  end

  # canonical_order_keys is a REQUIRED public helper (production reads it in
  # scoring.rb:53/118/154 for the no-data breakdown, enabled order, and dominant tie order),
  # so it must exist and yield the exact ordered keys.
  def test_canonical_order_keys_exists_and_yields_exact_sequence
    assert_respond_to R, :canonical_order_keys,
                      'canonical_order_keys is a required public helper (production reads it)'
    assert_equal CANONICAL, R.canonical_order_keys,
                 'canonical_order_keys == the ordered 6 keys (built-in sequence + coverage_gap last)'
  end

  # --- N-generality: the catalog does not hardcode "5" ------------------------
  # Prove the count is DERIVED from the catalog AND that canonical_order is the injective,
  # total 0-based POSITION of each key — the structural invariant a hardcoded five-element
  # impl cannot fake. The non-5 (enabled_count 3/4) behavior itself is proven by the
  # enabled-subset scoring tests (scoring_completeness_test / scoring_enabled_set_test);
  # here we pin the ordering shape.
  def test_registry_count_is_derived_not_literal
    # default_weights scopes to default_on:true, so it covers the DEFAULT-ON subset (5),
    # while keys covers all REGISTERED signals (6). The catalog count is still DERIVED (not
    # a literal), proven by canonical_order being the [0,N) index.
    assert_equal R.default_on_keys.size, R.default_weights.size,
                 'default_weights covers exactly the default_on keys (count derived)'
    assert_operator R.keys.size, :>, R.default_on_keys.size,
                    'registered keys (incl. coverage_gap) exceed the default_on subset'

    # canonical_order values are the 0-based positions of the keys: injective, total,
    # and exactly the contiguous range [0, N). This is stronger than size-equality — it
    # forces the order to be a genuine index over the enumerated catalog (N-general).
    orders = R.canonical_order_keys.map { |k| R.fetch(k).canonical_order }
    assert_equal orders.uniq, orders, 'canonical_order values are injective (no duplicate positions)'
    assert_equal (0...R.keys.size).to_a, orders,
                 'canonical_order values are the contiguous 0-based positions [0, N)'
    # And the ordered-keys helper sorts by exactly those positions (total order).
    assert_equal R.canonical_order_keys,
                 R.keys.sort_by { |k| R.fetch(k).canonical_order },
                 'canonical_order_keys is the keys sorted by their canonical_order position'
  end
end
