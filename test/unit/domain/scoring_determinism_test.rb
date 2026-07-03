# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# FR-31, FR-05, FR-35 / FC-04, FC-05.
# Determinism: identical (ProjectMetrics, clock value, ScoringConfig) computed
# N>=50 times yields identical HealthResult; clock injection used for `today`;
# no reliance on Time.now / hash ordering.
class ScoringDeterminismTest < Minitest::Test
  include ScoringSupport

  def field_tuple(h)
    [
      h.project_id, h.health_score, h.rag, h.dominant_signal, h.signal_completeness,
      h.lens_keys[:health], h.lens_keys[:at_risk], h.lens_keys[:stale],
      h.lens_keys[:done], h.lens_keys[:blocked], h.effort_open,
      h.breakdown.map { |s| [s.key, s.active, s.raw_value, s.n, s.effective_weight, s.contribution] }
    ]
  end

  def test_repeated_invocation_deep_equality
    m = kernel_aios_metrics
    c = fixed_clock
    cfg = config
    baseline = field_tuple(Pulse::Domain::Scoring.score(m, c, cfg))
    50.times do
      assert_equal baseline, field_tuple(Pulse::Domain::Scoring.score(m, c, cfg))
    end
  end

  def test_determinism_across_multiple_fixtures
    [kernel_aios_metrics, pdfree_metrics,
     metrics(risk_mapped: false, effort_total: 0.0, effort_open: 0.0)].each do |m|
      base = field_tuple(Pulse::Domain::Scoring.score(m, fixed_clock, config))
      60.times { assert_equal base, field_tuple(Pulse::Domain::Scoring.score(m, fixed_clock, config)) }
    end
  end

  # --- FR-05: clock injection is the sole source of `today` ---
  def test_clock_injection_used_for_today
    m = metrics(reference_date: Date.new(2026, 1, 1))
    # Two different injected clocks must produce different staleness raw_value.
    s1 = Pulse::Domain::Signals.staleness(m, fixed_clock(Date.new(2026, 1, 31)), config)
    s2 = Pulse::Domain::Signals.staleness(m, fixed_clock(Date.new(2026, 3, 2)), config)
    assert_equal 30, s1.raw_value
    assert_equal 60, s2.raw_value
    refute_equal s1.raw_value, s2.raw_value, 'staleness must track the injected clock, not system time'
  end

  def test_inputs_not_mutated
    m = kernel_aios_metrics
    cfg = config
    assert m.frozen?
    assert cfg.frozen?
    Pulse::Domain::Scoring.score(m, fixed_clock, cfg)
    assert m.frozen?, 'metrics still frozen / unmutated after scoring'
    assert cfg.frozen?
  end
end
