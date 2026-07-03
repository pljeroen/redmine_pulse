# frozen_string_literal: true

require 'minitest/autorun'
require 'pulse/adapters/lens_ranker'

# CR-RA-1 — no-data lens-ranking consistency.
#
# A no-data project carries nil for EVERY lens value (the Scoring no-data shape:
# lens_keys = { health: nil, at_risk: nil, stale: nil, done: nil, blocked: nil }).
# It is "unscored", not the answer to any "which is most X" question, so it MUST
# sort CONSISTENTLY LAST in every one of the 5 lens orderings — never first, never
# in the middle. Scoreable projects keep their exact prior worst-first ordering.
#
# RED on the pre-fix asymmetric impl: there nil sorted FIRST (worst) under
# health/done but LAST (best, via -(nil.to_f) == -0.0) under at_risk/stale/blocked,
# so the no-data project was NOT last for health/done.
class LensRankerNoDataTest < Minitest::Test
  # Minimal duck-typed stand-ins: LensRanker.rank only reads
  # projection.health.lens_keys[sym] and projection.project.id.
  Health = Struct.new(:lens_keys, keyword_init: true)
  Project = Struct.new(:id, keyword_init: true)
  Projection = Struct.new(:project, :health, keyword_init: true)

  # Two scoreable projects with distinct values on every lens + one no-data project.
  def scoreable(id, health:, at_risk:, stale:, done:, blocked:)
    Projection.new(
      project: Project.new(id: id),
      health: Health.new(lens_keys: {
        health: health, at_risk: at_risk, stale: stale, done: done, blocked: blocked
      })
    )
  end

  def no_data(id)
    Projection.new(
      project: Project.new(id: id),
      health: Health.new(lens_keys: {
        health: nil, at_risk: nil, stale: nil, done: nil, blocked: nil
      })
    )
  end

  def portfolio
    [
      scoreable(1, health: 80, at_risk: 10.0, stale: 5,  done: 90.0, blocked: 1),
      scoreable(2, health: 20, at_risk: 90.0, stale: 99, done: 10.0, blocked: 8),
      no_data(3)
    ]
  end

  def test_no_data_project_sorts_last_under_every_lens
    Pulse::Adapters::LensRanker::LENSES.each do |lens|
      ranked = Pulse::Adapters::LensRanker.rank(portfolio, lens)
      last = ranked.last

      assert_equal 3, last.project.id,
                   "no-data project (id 3) must sort LAST under the '#{lens}' lens, " \
                   "got order #{ranked.map { |p| p.project.id }.inspect}"
    end
  end

  # The two scoreable projects keep their relative worst-first ordering with the
  # no-data project removed from the tail (no regression in scoreable ranking).
  def test_scoreable_projects_keep_worst_first_order
    expected = {
      'health'  => [2, 1], # ascending: lower health is worse (first)
      'done'    => [2, 1], # ascending: lower done is worse (first)
      'at_risk' => [2, 1], # descending: higher at_risk is worse (first)
      'stale'   => [2, 1], # descending: higher stale is worse (first)
      'blocked' => [2, 1]  # descending: higher blocked is worse (first)
    }
    expected.each do |lens, want|
      ranked = Pulse::Adapters::LensRanker.rank(portfolio, lens)
      scoreable_order = ranked.map { |p| p.project.id }.reject { |id| id == 3 }
      assert_equal want, scoreable_order,
                   "scoreable worst-first order changed under the '#{lens}' lens"
    end
  end
end
