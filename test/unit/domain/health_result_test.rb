# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# FR-04, FR-21, FR-25, FR-30 / FC-01, FC-09, FC-22, FC-23, FC-31.
# HealthResult VO field set; dominant_signal NON-NIL (CR-01); effort_open
# passthrough (CR-03); breakdown length 5 canonical order; lens_keys 5 keys;
# NO computed_at / Date field.
class HealthResultTest < Minitest::Test
  include ScoringSupport

  def result
    Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
  end

  def test_field_set_dominant_non_nil_effort_open_no_date
    h = result
    assert_kind_of Integer, h.project_id
    assert_kind_of Integer, h.health_score
    assert_includes %i[green amber red], h.rag
    assert_kind_of Symbol, h.dominant_signal
    refute_nil h.dominant_signal, 'dominant_signal is NEVER nil (CR-01)'
    assert_includes ScoringSupport::CANONICAL_ORDER, h.dominant_signal
    assert_kind_of Float, h.signal_completeness
    assert_kind_of Array, h.breakdown
    assert_kind_of Hash, h.lens_keys
    assert h.frozen?, 'HealthResult must be frozen (FC-31)'
  end

  def test_project_id_passthrough
    h = Pulse::Domain::Scoring.score(metrics(project_id: 42), fixed_clock, config)
    assert_equal 42, h.project_id
  end

  def test_breakdown_length_and_canonical_order
    h = result
    assert_equal 5, h.breakdown.length, 'breakdown is exactly 5 (FC-09)'
    assert_equal ScoringSupport::CANONICAL_ORDER, h.breakdown.map(&:key)
  end

  def test_lens_keys_exact_key_set
    h = result
    assert_equal %i[at_risk blocked done health stale], h.lens_keys.keys.sort
  end

  def test_health_score_integer_in_range
    h = result
    assert_kind_of Integer, h.health_score
    assert_operator h.health_score, :>=, 0
    assert_operator h.health_score, :<=, 100
  end

  # --- CR-03: effort_open passthrough exposed for done-lens secondary sort ---
  def test_exposes_effort_open_passthrough
    h = Pulse::Domain::Scoring.score(metrics(effort_open: 3.5, effort_total: 10.0), fixed_clock, config)
    assert_respond_to h, :effort_open
    assert_in_delta 3.5, h.effort_open, 1e-12
  end

  # --- FC-31: no computed_at / Date field on HealthResult ---
  def test_no_computed_at_or_date_field
    h = result
    refute_respond_to h, :computed_at, 'HealthResult must not carry computed_at (OSD-08/FC-31)'
    refute_respond_to h, :reference_date
    refute_respond_to h, :date
    # No instance variable holding a Date object.
    h.instance_variables.each do |ivar|
      val = h.instance_variable_get(ivar)
      refute_kind_of Date, val, "HealthResult must hold no Date field (#{ivar})"
    end
  end

  def test_mutation_raises_frozen_error
    h = result
    assert_raises(FrozenError) { h.instance_variable_set(:@health_score, 0) } if h.frozen?
  end
end
