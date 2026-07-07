# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'

lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative '../../../lib/pulse/adapters/settings_sanitizer'

# Adapter-layer proportional renormalization.
#
# When the settings adapter toggles a signal's enabled state, the remaining enabled
# weights are renormalized by DETERMINISTIC PROPORTIONAL scaling:
#   w_i_new = w_i_old / Σ_{remaining} w_j_old
# Consequently Σ w_new == 1.0 (within 1e-9), and every remaining weight keeps its
# pre-toggle proportion relative to the others. This is an ADAPTER-layer write-path
# behavior distinct from the pure-domain value-object strictness.
class SettingsSanitizerRenormalizeTest < Minitest::Test
  S = Pulse::Adapters::SettingsSanitizer

  DEFAULT = {
    'staleness' => 0.25, 'progress' => 0.25, 'momentum' => 0.20,
    'risk_load' => 0.15, 'blocked_load' => 0.15
  }.freeze

  # Invoke the renormalization entry point. The exact method name is defined by this
  # test. It takes the current weights + the key being
  # disabled and returns the renormalized remaining set.
  def renormalize(weights, disable:)
    S.renormalize_on_toggle(weights, disable)
  end

  # --- proportional scaling: each remaining w_i_new == w_i_old / Σ_remaining ----
  def test_disabling_one_scales_remaining_proportionally
    result = renormalize(DEFAULT, disable: 'risk_load')
    remaining = DEFAULT.reject { |k, _| k == 'risk_load' }
    remaining_sum = remaining.values.sum # 0.85

    result = result.transform_keys(&:to_s)
    refute_includes result.keys, 'risk_load', 'the disabled signal is dropped from the weight set'
    remaining.each do |k, w_old|
      assert_in_delta w_old / remaining_sum, result[k], 1e-9,
                      "#{k}: w_new == w_old / Σ_remaining (exact proportional scaling)"
    end
  end

  def test_renormalized_set_sums_to_one
    result = renormalize(DEFAULT, disable: 'risk_load').transform_keys(&:to_s)
    assert_in_delta 1.0, result.values.sum, 1e-9, 'Σ renormalized weights == 1.0'
  end

  def test_proportions_preserved_relative_to_each_other
    # staleness/progress were equal (0.25 each); after renormalization they stay equal.
    result = renormalize(DEFAULT, disable: 'blocked_load').transform_keys(&:to_s)
    assert_in_delta result['staleness'], result['progress'], 1e-12,
                    'equal pre-toggle weights remain equal after proportional renormalization'
    # ratio staleness:momentum preserved (0.25:0.20 == result ratio).
    assert_in_delta 0.25 / 0.20, result['staleness'] / result['momentum'], 1e-9,
                    'pairwise weight ratios are preserved'
  end

  def test_disabling_a_non_always_active_signal_keeps_positive_always_active_subset
    # disabling progress (non-always-active) leaves the always-active subset intact,
    # so the renormalized set still satisfies the domain always-active-subset guard downstream.
    result = renormalize(DEFAULT, disable: 'progress').transform_keys(&:to_s)
    always_active = %w[staleness momentum blocked_load]
    assert_operator always_active.sum { |k| result[k] }, :>, 0.0
    assert_in_delta 1.0, result.values.sum, 1e-9
  end

  def test_symbol_keyed_input_supported
    sym_weights = DEFAULT.transform_keys(&:to_sym)
    result = renormalize(sym_weights, disable: :risk_load).transform_keys(&:to_s)
    assert_in_delta 1.0, result.values.sum, 1e-9
    refute_includes result.keys, 'risk_load'
  end
end
