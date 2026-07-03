# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# FR-25..FR-30 / FC-23, FC-24, FC-25.
# All five lens keys + nil-when-inactive (done) + tie-break by project_id + the
# done-lens effort_open secondary sort (CR-03).
class LensesTest < Minitest::Test
  include ScoringSupport

  # ---- FR-25: health lens key == health_score ----
  def test_health_lens_key
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal h.health_score, h.lens_keys[:health]
    assert_kind_of Integer, h.lens_keys[:health]
  end

  # ---- FR-27: stale lens key == staleness raw_value (days), always present ----
  def test_stale_lens_key
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal 150, h.lens_keys[:stale]
    assert_kind_of Integer, h.lens_keys[:stale]
  end

  # ---- FR-29: blocked lens key == blocked_count, always present ----
  def test_blocked_lens_key
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal 12, h.lens_keys[:blocked]
    assert_kind_of Integer, h.lens_keys[:blocked]
  end

  # ---- FR-28: done lens key == progress_ratio*100 when active, else nil ----
  def test_done_lens_key_active
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config) # ratio 0.30
    assert_in_delta 30.0, h.lens_keys[:done], 1e-9
    assert_kind_of Float, h.lens_keys[:done]
  end

  def test_done_lens_key_nil_when_progress_inactive
    h = Pulse::Domain::Scoring.score(metrics(effort_open: 0.0, effort_total: 0.0), fixed_clock, config)
    assert_nil h.lens_keys[:done], 'done lens key is nil when progress inactive (sorts last)'
  end

  # ---- FR-26: at_risk lens key = 100*Σ over A∩{risk_load,blocked_load,staleness} eff*(1-n) ----
  def test_at_risk_lens_key_full_enrichment
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    # staleness 0.25*(1-1/6) + risk 0.15*(1-0.20) + blocked 0.15*(1-0.40) = 0.41833 *100
    assert_in_delta 41.83, h.lens_keys[:at_risk], 0.01
  end

  def test_at_risk_lens_key_standard_fields
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    # risk_load inactive -> excluded; eff weights renormalized over active set.
    assert_in_delta 4.15, h.lens_keys[:at_risk], 0.01
  end

  def test_at_risk_zero_when_none_of_subset_drags
    # staleness/blocked n==1 and risk inactive -> at_risk == 0.0.
    h = Pulse::Domain::Scoring.score(
      metrics(reference_date: ScoringSupport::TODAY, blocked_count: 0, risk_mapped: false,
              effort_total: 10.0, effort_open: 1.0, event_series: []),
      fixed_clock, config
    )
    assert_in_delta 0.0, h.lens_keys[:at_risk], 1e-9
  end

  # ---- FR-30 / FC-25: lens tie-break by project_id ascending ----
  def test_lens_tiebreak_project_id_ascending
    # Three projects with IDENTICAL health_score -> sort must order by project_id asc.
    base = { reference_date: ScoringSupport::TODAY - 150, effort_open: 7.0, effort_total: 10.0,
             risk_raw: 40.0, blocked_count: 12, risk_mapped: true,
             event_series: events_for(opened: 6, closed: 2) }
    results = [30, 10, 20].map do |pid|
      Pulse::Domain::Scoring.score(metrics(project_id: pid, **base), fixed_clock, config)
    end
    # all equal health_score; health lens ascending then project_id asc.
    sorted = sort_by_lens(results, :health)
    assert_equal [10, 20, 30], sorted.map(&:project_id)
  end

  # ---- CR-03: done-lens secondary sort uses HealthResult.effort_open ----
  def test_done_lens_secondary_sort_effort_open_then_project_id
    # Same done key (progress_ratio) but different effort_open -> effort_open asc.
    # ratio 0.5 for all (open/total=0.5) but vary effort_open via different total scale.
    a = Pulse::Domain::Scoring.score(metrics(project_id: 5, effort_open: 10.0, effort_total: 20.0), fixed_clock, config)
    b = Pulse::Domain::Scoring.score(metrics(project_id: 7, effort_open: 2.0,  effort_total: 4.0),  fixed_clock, config)
    c = Pulse::Domain::Scoring.score(metrics(project_id: 9, effort_open: 50.0, effort_total: 100.0), fixed_clock, config)
    # all ratio 0.5 -> done key 50.0; secondary effort_open asc: b(2), a(10), c(50).
    sorted = sort_done([a, b, c])
    assert_equal [7, 5, 9], sorted.map(&:project_id)
  end

  def test_done_lens_inactive_sorts_last
    active = Pulse::Domain::Scoring.score(metrics(project_id: 1, effort_open: 2.0, effort_total: 10.0), fixed_clock, config)
    inactive = Pulse::Domain::Scoring.score(metrics(project_id: 2, effort_open: 0.0, effort_total: 0.0), fixed_clock, config)
    sorted = sort_done([inactive, active])
    assert_equal [1, 2], sorted.map(&:project_id), 'progress-inactive (nil done key) sorts last'
  end

  def test_effort_open_exposed_on_result
    h = Pulse::Domain::Scoring.score(metrics(effort_open: 4.0, effort_total: 10.0), fixed_clock, config)
    assert_respond_to h, :effort_open
    assert_in_delta 4.0, h.effort_open, 1e-12
  end

  private

  # Reference ranking helpers (the domain exposes lens_keys + effort_open; the
  # ranking itself is a consumer concern but we assert the keys support it).
  def sort_by_lens(results, lens)
    desc = %i[at_risk stale blocked done].include?(lens)
    results.sort_by do |h|
      key = h.lens_keys[lens]
      primary = desc ? -(key || -Float::INFINITY) : key
      [primary, h.project_id]
    end
  end

  def sort_done(results)
    results.sort_by do |h|
      done = h.lens_keys[:done]
      # nil done sorts last (descending primary): give it -inf so it lands last.
      primary = done.nil? ? Float::INFINITY : -done
      [primary, h.effort_open, h.project_id]
    end
  end
end
