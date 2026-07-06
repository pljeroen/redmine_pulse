# frozen_string_literal: true

require 'date'
require 'pulse/domain/project_metrics'
require 'pulse/domain/scoring_config'
require 'pulse/domain/signal_result'
require 'pulse/domain/health_result'
require 'pulse/domain/signals'
require 'pulse/domain/scoring'

# Shared builders for the pure-domain scoring tests. A test double Clock that
# returns a FIXED Date satisfies the Pulse::Ports::Clock duck-type (#today -> Date).
module ScoringSupport
  # FixedClock: the only time source the domain may read (FR-05/FR-35).
  class FixedClock
    def initialize(date)
      @date = date
    end

    def today
      @date
    end
  end

  TODAY = Date.new(2026, 6, 20)

  def fixed_clock(date = TODAY)
    FixedClock.new(date)
  end

  def config(**overrides)
    Pulse::Domain::ScoringConfig.new(**overrides)
  end

  # A fully-enriched metrics object; override individual fields per test.
  def metrics(**overrides)
    defaults = {
      project_id: 1,
      reference_date: TODAY,
      effort_open: 0.0,
      effort_total: 0.0,
      risk_raw: 0.0,
      blocked_count: 0,
      risk_mapped: true,
      effort_mapped: true,
      event_series: [],
      version_due_dates: [],
      # C2 additive-required coverage inputs. The 0/0.0 baseline places coverage_gap on
      # the INACTIVE path (FR-C2-04) so it never affects the pre-C2 five-signal score.
      open_issue_count: 0,
      covered_sum: 0.0
    }
    Pulse::Domain::ProjectMetrics.new(**defaults.merge(overrides))
  end

  # Build an event_series producing the requested opened/closed counts INSIDE the
  # half-open window [today-W, today). All events placed at today-1 (in-window).
  def events_for(opened:, closed:, date: TODAY - 1)
    o = Array.new(opened) { { date: date, type: :issue_created } }
    c = Array.new(closed) { { date: date, type: :issue_closed } }
    o + c
  end

  # ---- Golden seed: kernel-aios (project_id 11) — all 5 active, default weights ----
  # staleness days=150 (n 1/6), progress n=0.30 (open/total=0.70),
  # momentum opened=6 closed=2 (NEW formula: activity 8, base 8/16=0.5, dir -0.5, n 0.425),
  # risk_raw=40 (n 0.20), blocked_count=12 (n 0.40). score_raw 29.1667 -> 29 (red),
  # dominant staleness (worst n 0.1667 < 0.5 => named, not on_track).
  def kernel_aios_metrics
    metrics(
      project_id: 11,
      reference_date: TODAY - 150,            # 2026-01-21
      effort_open: 7.0, effort_total: 10.0,   # ratio 0.30
      risk_raw: 40.0,
      blocked_count: 12,
      risk_mapped: true, effort_mapped: true,
      event_series: events_for(opened: 6, closed: 2)
    )
  end

  # ---- Golden seed: pdfree (project_id 16) — risk_load INACTIVE (standard fields) ----
  # active set {staleness,progress,momentum,blocked_load}, weight-sum 0.85.
  # staleness days=20 (n 0.888889), progress n=0.80, momentum opened=4 closed=6
  # (NEW formula: activity 10, base 10/18=0.555556, dir 0.2, n 0.585556), blocked_count=1
  # (n 0.95). score_raw 80.2157 -> 80 (green), dominant :on_track (worst n 0.585556 >= 0.5).
  def pdfree_metrics
    metrics(
      project_id: 16,
      reference_date: TODAY - 20,             # 2026-05-31
      effort_open: 2.0, effort_total: 10.0,   # ratio 0.80
      risk_raw: 0.0,
      blocked_count: 1,
      risk_mapped: false, effort_mapped: true,
      event_series: events_for(opened: 4, closed: 6)
    )
  end

  CANONICAL_ORDER = %i[staleness progress momentum risk_load blocked_load].freeze

  def signal(result, key)
    result.breakdown.find { |s| s.key == key }
  end
end
