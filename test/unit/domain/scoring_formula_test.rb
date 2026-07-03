# frozen_string_literal: true

require_relative '../../domain_test_helper'
require_relative 'scoring_support'

# FR-06..FR-24 / FC-12..FC-27.
# Golden-formula tests for the five signals plus composite assembly.
class ScoringFormulaTest < Minitest::Test
  include ScoringSupport

  S = Pulse::Domain::Signals

  # ============ STALENESS (FR-06, FR-07 / FC-12, FC-13, FC-14) ============
  def test_staleness_formula
    m = metrics(reference_date: ScoringSupport::TODAY - 90)
    s = S.staleness(m, fixed_clock, config)
    assert s.active, 'staleness is always active'
    assert_equal 90, s.raw_value
    assert_kind_of Integer, s.raw_value
    assert_in_delta(1.0 - 90.0 / 180.0, s.n, 1e-9) # 0.5
  end

  def test_staleness_zero_elapsed
    m = metrics(reference_date: ScoringSupport::TODAY)
    s = S.staleness(m, fixed_clock, config)
    assert s.active
    assert_equal 0, s.raw_value
    assert_in_delta 1.0, s.n, 1e-12
  end

  def test_staleness_clamped_high_days
    m = metrics(reference_date: ScoringSupport::TODAY - 365) # days 365 > H_stale
    s = S.staleness(m, fixed_clock, config)
    assert_equal 365, s.raw_value
    assert_in_delta 0.0, s.n, 1e-12, 'n clamps at 0 when days > H_stale'
  end

  def test_staleness_clamp_when_clock_before_reference
    # FC-13: days negative => n clamps to 1.0 (never > 1); raw_value reported as-is.
    m = metrics(reference_date: ScoringSupport::TODAY + 10)
    s = S.staleness(m, fixed_clock, config)
    assert_equal(-10, s.raw_value)
    assert_in_delta 1.0, s.n, 1e-12
  end

  # ============ PROGRESS (FR-08, FR-09, FR-10 / FC-15, FC-16) ============
  def test_progress_activation
    active = S.progress(metrics(effort_open: 2.0, effort_total: 10.0), config)
    assert active.active, 'progress active when effort_total > 0'

    inactive = S.progress(metrics(effort_open: 0.0, effort_total: 0.0), config)
    refute inactive.active, 'progress inactive when effort_total == 0'
  end

  def test_progress_ratio_and_n
    s = S.progress(metrics(effort_open: 2.0, effort_total: 10.0), config)
    assert_in_delta 0.80, s.raw_value, 1e-9, 'raw_value == progress_ratio == 1 - open/total'
    assert_in_delta 0.80, s.n, 1e-9
  end

  def test_progress_zero_denominator_inactive_all_nil
    # CR-04: NO nil branch — effort_total is a non-nil Numeric; ==0 => inactive.
    s = S.progress(metrics(effort_open: 0.0, effort_total: 0.0), config)
    refute s.active
    assert_nil s.raw_value
    assert_nil s.n
    assert_nil s.effective_weight
    assert_nil s.contribution
  end

  def test_progress_ratio_clamped_when_open_exceeds_total
    # progress_ratio negative => clamp n to 0; raw_value stores raw ratio.
    s = S.progress(metrics(effort_open: 15.0, effort_total: 10.0), config)
    assert s.active
    assert_in_delta(-0.5, s.raw_value, 1e-9)
    assert_in_delta 0.0, s.n, 1e-12
  end

  # ============ MOMENTUM — "Active = healthy" (momentum-broaden CT-02) ============
  # NEW formula (lib/pulse/domain/signals.rb#momentum). For each in-window event:
  #   :issue_created -> opened, :issue_closed -> closed,
  #   :issue_commented -> comments, :commit -> commits.
  #   activity  = opened + closed + comments + commits
  #   base      = activity / (activity + MOMENTUM_ACTIVITY_HALF=8.0)        # 0 -> 0.5 -> ->1
  #   direction = (closed - opened) / max(closed + opened, 1)              # in [-1, 1]
  #   n         = clamp(base + MOMENTUM_DIRECTION_BIAS=0.15 * direction, 0.0, 1.0)
  #   raw_value = activity (Integer total) — informational.
  # Momentum stays ALWAYS active. Golden arithmetic shown inline per case.

  def test_momentum_raw_value_is_activity_total_integer
    # raw_value is now the activity COUNT (opened+closed+comments+commits), not closed-opened.
    m = metrics(event_series: events_for(opened: 6, closed: 2)) # activity 8
    s = S.momentum(m, fixed_clock, config)
    assert s.active, 'momentum always active'
    assert_kind_of Integer, s.raw_value
    assert_equal 8, s.raw_value, 'raw_value == activity total (6+2)'
    # base = 8/(8+8) = 0.5 ; dir = (2-6)/max(8,1) = -0.5 ; n = 0.5 + 0.15*(-0.5) = 0.425
    assert_in_delta 0.425, s.n, 1e-9
  end

  def test_momentum_idle_is_zero_not_neutral
    # NEW: idle (no in-window events) => activity 0 => base 0, dir 0 => n = 0.0 (was 0.5).
    s = S.momentum(metrics(event_series: []), fixed_clock, config)
    assert s.active
    assert_equal 0, s.raw_value, 'raw_value == activity 0'
    assert_in_delta 0.0, s.n, 1e-12, 'idle momentum reads 0.0 ("Active = healthy": idle drifts low)'
  end

  def test_momentum_balanced_light_activity_base_only
    # 5 comments, no opens/closes: activity 5 => base 5/13 ; dir 0 => n = base.
    series = Array.new(5) { { date: ScoringSupport::TODAY - 1, type: :issue_commented } }
    s = S.momentum(metrics(event_series: series), fixed_clock, config)
    assert_equal 5, s.raw_value, 'comments count as activity (raw_value == 5)'
    # base = 5/(5+8) = 0.3846153... ; dir 0 => n = base.
    assert_in_delta 5.0 / 13.0, s.n, 1e-9 # 0.384615...
  end

  def test_momentum_counts_comments_and_commits_as_activity
    # busy net-closing: opened 2, closed 8, comments 10, commits 5 => activity 25.
    series = events_for(opened: 2, closed: 8) +
             Array.new(10) { { date: ScoringSupport::TODAY - 1, type: :issue_commented } } +
             Array.new(5) { { date: ScoringSupport::TODAY - 1, type: :commit } }
    s = S.momentum(metrics(event_series: series), fixed_clock, config)
    assert_equal 25, s.raw_value, 'activity counts opens+closes+comments+commits (2+8+10+5)'
    # base = 25/(25+8) = 0.757575... ; dir = (8-2)/max(10,1) = 0.6 ; n = 0.7576 + 0.15*0.6 = 0.847576
    assert_in_delta 25.0 / 33.0 + 0.15 * 0.6, s.n, 1e-9 # 0.847576...
  end

  def test_momentum_busy_net_opening_stays_healthy
    # THE WHOLE POINT (D1): a busy net-OPENING project still reads healthy (n >= 0.5).
    # opened 10, closed 1, comments 8 => activity 19.
    series = events_for(opened: 10, closed: 1) +
             Array.new(8) { { date: ScoringSupport::TODAY - 1, type: :issue_commented } }
    s = S.momentum(metrics(event_series: series), fixed_clock, config)
    assert_equal 19, s.raw_value
    # base = 19/(19+8) = 0.703703... ; dir = (1-10)/max(11,1) = -0.818181... ;
    # n = 0.703703 + 0.15*(-0.818181) = 0.580976...
    expected = 19.0 / 27.0 + 0.15 * ((1 - 10).to_f / 11)
    assert_in_delta expected, s.n, 1e-9 # 0.580976...
    assert_operator s.n, :>=, 0.5, 'busy net-opening momentum still reads healthy (>= 0.5)'
  end

  def test_momentum_n_across_mixes_in_range
    [[0, 5], [5, 0], [1, 9], [9, 1], [10, 10], [2, 6]].each do |opened, closed|
      s = S.momentum(metrics(event_series: events_for(opened: opened, closed: closed)), fixed_clock, config)
      assert_operator s.n, :>=, 0.0
      assert_operator s.n, :<=, 1.0
      assert_equal(opened + closed, s.raw_value, 'raw_value == activity total')
    end
  end

  def test_momentum_clamp_low_high
    # Direction bias cannot push n below 0 or above 1.
    # Lots of closes (net-closing high activity): base near 1, +bias -> clamps at 1.0.
    hi = S.momentum(metrics(event_series: events_for(opened: 0, closed: 100)), fixed_clock, config)
    assert_in_delta 1.0, hi.n, 1e-12, 'n clamps at 1.0'
    # One open only: activity 1 => base 1/9=0.1111 ; dir -1 ; n = 0.1111 - 0.15 < 0 -> clamp 0.0.
    lo = S.momentum(metrics(event_series: events_for(opened: 1, closed: 0)), fixed_clock, config)
    assert_in_delta 0.0, lo.n, 1e-12, 'n clamps at 0.0'
  end

  def test_momentum_window_half_open_boundary
    # event @ (today - W) IS in-window; event @ today is NOT (FC-18).
    w = config.activity_window_days # 30
    in_window  = { date: ScoringSupport::TODAY - w, type: :issue_closed }
    excluded   = { date: ScoringSupport::TODAY,     type: :issue_closed }
    too_old    = { date: ScoringSupport::TODAY - w - 1, type: :issue_closed }
    s = S.momentum(metrics(event_series: [in_window, excluded, too_old]), fixed_clock, config)
    # Only the today-W closed event counts: activity 1 (closed=1, opened=0).
    assert_equal 1, s.raw_value
  end

  def test_momentum_consumes_supplied_event_classification
    # Domain CONSUMES already-classified entries; activity counts each in-window entry.
    series = [
      { date: ScoringSupport::TODAY - 2, type: :issue_closed }, # created-as-closed reclassified by adapter
      { date: ScoringSupport::TODAY - 3, type: :issue_closed }, # reclose
      { date: ScoringSupport::TODAY - 4, type: :issue_created }
    ]
    s = S.momentum(metrics(event_series: series), fixed_clock, config)
    assert_equal 3, s.raw_value # activity = 2 closed + 1 opened
  end

  def test_momentum_arbitrary_length_event_series
    big = events_for(opened: 40, closed: 60) + [{ date: ScoringSupport::TODAY - 100, type: :issue_closed }]
    s = S.momentum(metrics(event_series: big), fixed_clock, config)
    # the today-100 event is outside the 30-day window -> ignored => activity 100.
    assert_equal 100, s.raw_value # 60 + 40
  end

  def test_momentum_commit_events_count_as_activity_and_in_window
    # A :commit in-window counts as activity; one outside the window is ignored.
    series = [
      { date: ScoringSupport::TODAY - 1,   type: :commit },  # in-window
      { date: ScoringSupport::TODAY - 100, type: :commit }   # too old -> ignored
    ]
    s = S.momentum(metrics(event_series: series), fixed_clock, config)
    assert_equal 1, s.raw_value, 'only the in-window commit counts (activity 1)'
  end

  # ============ MOMENTUM responds to config (settings-promote-momentum CT-02) ==
  # momentum_activity_half and momentum_direction_bias are promoted from module
  # constants to ScoringConfig fields. Signals.momentum must read them off `config`
  # (config.momentum_activity_half / config.momentum_direction_bias) — NOT the (now
  # removed) constants. Same metrics/events; only the config changes. RED now:
  # ScoringConfig has no such kwargs and Signals.momentum still uses the constants.

  def test_momentum_responds_to_activity_half_lower_half_yields_higher_n
    # Same events for both: opened 2, closed 8 => activity 10 ; direction = (8-2)/10 = 0.6.
    # Default bias 0.15 in both => direction term = 0.15*0.6 = 0.09 (identical, cancels).
    #   half 8 (default): base = 10/(10+8) = 10/18 = 0.5555556 ; n = 0.5555556 + 0.09 = 0.6455556
    #   half 4          : base = 10/(10+4) = 10/14 = 0.7142857 ; n = 0.7142857 + 0.09 = 0.8042857
    # A SMALLER half makes the project read MORE active for the same traffic => higher n.
    m = metrics(event_series: events_for(opened: 2, closed: 8))

    default_half = S.momentum(m, fixed_clock, config) # half 8.0
    smaller_half = S.momentum(m, fixed_clock, config(momentum_activity_half: 4.0))

    assert_in_delta 10.0 / 18.0 + 0.15 * 0.6, default_half.n, 1e-9 # 0.6455556
    assert_in_delta 10.0 / 14.0 + 0.15 * 0.6, smaller_half.n, 1e-9 # 0.8042857
    assert_operator smaller_half.n, :>, default_half.n,
                    'a smaller momentum_activity_half => same traffic reads more active => higher n'
  end

  def test_momentum_responds_to_direction_bias_zero_removes_direction_term
    # bias 0 => the direction nudge vanishes => n == base (the activity-only curve).
    # opened 2, closed 8 => activity 10 ; base = 10/(10+8) = 10/18 = 0.5555556.
    #   default bias 0.15: n = base + 0.15*0.6 = 0.6455556 (direction LIFTS it)
    #   bias 0           : n = base + 0   *0.6 = base = 0.5555556
    m = metrics(event_series: events_for(opened: 2, closed: 8))
    base = 10.0 / (10.0 + 8.0) # 0.5555556

    with_bias = S.momentum(m, fixed_clock, config) # bias 0.15
    no_bias = S.momentum(m, fixed_clock, config(momentum_direction_bias: 0.0))

    assert_in_delta base, no_bias.n, 1e-9, 'bias 0 => n == base (direction term removed)'
    assert_in_delta base + 0.15 * 0.6, with_bias.n, 1e-9
    refute_in_delta no_bias.n, with_bias.n, 1e-6,
                    'a non-zero default bias must differ from the bias-0 (base-only) result'
  end

  def test_momentum_default_config_preserves_legacy_constants
    # Defaults (8.0 / 0.15) MUST reproduce the pre-promotion golden exactly:
    # opened 6 closed 2 => activity 8, base 8/16=0.5, dir -0.5, n 0.5+0.15*(-0.5)=0.425.
    m = metrics(event_series: events_for(opened: 6, closed: 2))
    s = S.momentum(m, fixed_clock, config)
    assert_in_delta 0.425, s.n, 1e-9,
                    'default momentum config (half 8.0 / bias 0.15) preserves the legacy n=0.425'
  end

  # ============ dominant_signal on_track threshold responds to config ==========
  # on_track_threshold is promoted from the ON_TRACK_THRESHOLD constant to a
  # ScoringConfig field. Scoring.dominant_signal must compare the worst active n
  # against config.on_track_threshold. Build a project whose worst active signal n
  # is exactly 0.6 and assert the SAME project reads :on_track at threshold 0.5
  # (default) but NAMES that signal at threshold 0.7. RED now: ScoringConfig has no
  # on_track_threshold kwarg and Scoring uses the constant.
  def worst_signal_six_tenths_metrics
    # staleness is the single worst active signal at n exactly 0.6; all others >= 0.8.
    #   staleness days 72 => n 1 - 72/180 = 0.6  (the worst)
    #   progress  ratio 0.8 (open 2 total 10) => n 0.80
    #   momentum  opened 0 closed 100 => base ~0.926, dir +1 => n clamps to 1.0
    #   risk_raw  5 => n 1 - 5/50 = 0.90
    #   blocked   2 => n 1 - 2/20 = 0.90
    metrics(reference_date: ScoringSupport::TODAY - 72,
            effort_open: 2.0, effort_total: 10.0,
            risk_mapped: true, risk_raw: 5.0, blocked_count: 2,
            event_series: events_for(opened: 0, closed: 100))
  end

  def test_dominant_signal_on_track_at_default_threshold_responds_to_config
    m = worst_signal_six_tenths_metrics
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config) # on_track_threshold 0.5
    assert_in_delta 0.6, signal(h, :staleness).n, 1e-9, 'staleness is the worst active signal at n 0.6'
    assert_equal :on_track, h.dominant_signal,
                 'worst active n 0.6 >= on_track_threshold 0.5 (default) => :on_track'
  end

  def test_dominant_signal_names_signal_when_threshold_raised_via_config
    m = worst_signal_six_tenths_metrics
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config(on_track_threshold: 0.7))
    assert_in_delta 0.6, signal(h, :staleness).n, 1e-9
    assert_equal :staleness, h.dominant_signal,
                 'same project: worst active n 0.6 < on_track_threshold 0.7 => names the worst signal'
  end

  # ============ RISK_LOAD (FR-15, FR-16 / FC-19) ============
  def test_risk_load_formula
    s = S.risk_load(metrics(risk_mapped: true, risk_raw: 40.0), config)
    assert s.active
    assert_in_delta 40.0, s.raw_value, 1e-9
    assert_in_delta(1.0 - 40.0 / 50.0, s.n, 1e-9) # 0.20
  end

  def test_risk_load_inactive_when_unmapped
    s = S.risk_load(metrics(risk_mapped: false, risk_raw: 0.0), config)
    refute s.active
    assert_nil s.raw_value
    assert_nil s.n
  end

  def test_risk_load_clamped
    s = S.risk_load(metrics(risk_mapped: true, risk_raw: 100.0), config) # > H_risk
    assert_in_delta 0.0, s.n, 1e-12
  end

  # ============ BLOCKED_LOAD (FR-17 / FC-20) ============
  def test_blocked_load_formula
    s = S.blocked_load(metrics(blocked_count: 12), config)
    assert s.active, 'blocked_load always active'
    assert_equal 12, s.raw_value
    assert_in_delta(1.0 - 12.0 / 20.0, s.n, 1e-9) # 0.40
  end

  def test_blocked_load_zero
    s = S.blocked_load(metrics(blocked_count: 0), config)
    assert s.active
    assert_equal 0, s.raw_value
    assert_in_delta 1.0, s.n, 1e-12
  end

  def test_blocked_load_clamped
    s = S.blocked_load(metrics(blocked_count: 50), config) # > H_blocked
    assert_in_delta 0.0, s.n, 1e-12
  end

  # ============ COMPOSITE: weight redistribution + contributions (FR-19) ======
  def test_weight_redistribution_and_contributions
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    active = h.breakdown.select(&:active)
    sum_eff = active.sum(&:effective_weight)
    assert_in_delta 1.0, sum_eff, 1e-9, 'effective weights sum to 1 over active set (CR-02)'

    # inactive risk_load => effective_weight nil, contribution nil (FC-11).
    risk = signal(h, :risk_load)
    refute risk.active
    assert_nil risk.effective_weight
    assert_nil risk.contribution

    # contribution_i == 100 * eff_weight * n_i and >= 0.
    active.each do |s|
      assert_in_delta(100.0 * s.effective_weight * s.n, s.contribution, 1e-9)
      assert_operator s.contribution, :>=, 0.0
    end
  end

  def test_full_active_set_effective_weights_equal_nominal
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    # all 5 active => effective == nominal.
    assert_in_delta 0.25, signal(h, :staleness).effective_weight, 1e-9
    assert_in_delta 0.15, signal(h, :blocked_load).effective_weight, 1e-9
  end

  # ============ HEALTH SCORE round_half_up (FR-20 / FC-06) ============
  def test_health_score_round_half_up_kernel_aios
    # NEW momentum: kernel_aios momentum n 0.425 (was 0.25). contributions
    #   s 100*0.25*0.166667=4.1667, p 100*0.25*0.30=7.5, m 100*0.20*0.425=8.5,
    #   r 100*0.15*0.20=3.0, b 100*0.15*0.40=6.0 => score_raw 29.1667 -> 29.
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal 29, h.health_score # round_half_up(29.1667)
  end

  def test_health_score_round_half_up_pdfree
    # NEW momentum: pdfree momentum n 0.585556 (was 0.60). active {s,p,m,b}, eff sum 1.0.
    #   s 100*0.294118*0.888889=26.1438, p 100*0.294118*0.80=23.5294,
    #   m 100*0.235294*0.585556=13.7778, b 100*0.176471*0.95=16.7647 => 80.2157 -> 80.
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    assert_equal 80, h.health_score # round_half_up(80.2157)
  end

  def test_round_half_up_is_not_bankers_rounding
    # Production-path .5 boundaries that DISTINGUISH round-half-up from banker's
    # (round-half-to-even). Each tuned config lands score_raw exactly on x.5 via the
    # real Scoring.score path; we assert the half-up integer (x+1), which differs from
    # banker's whenever x is even.

    # Case 1 — score_raw == 66.5 (even integer part 66): half-up => 67; banker's => 66.
    # Retuned for the NEW momentum formula (idle momentum now n=0.0, not 0.5): momentum is
    # idle (event_series []), so it contributes 0 regardless of its weight and never perturbs
    # the boundary. The .5 boundary is driven by staleness alone.
    # All 5 active. ns=0.5 (days 90), np=1 (open 0), nm=0.0 (idle), nr=1 (risk 0), nb=1 (blk 0).
    # score_raw = 100*(w_p + w_r + w_b + 0.5*w_s) = 100*(0.20+0.115+0.10 + 0.5*0.50) = 66.5.
    w1 = { staleness: 0.50, progress: 0.20, momentum: 0.085, risk_load: 0.115, blocked_load: 0.10 }
    h1 = Pulse::Domain::Scoring.score(
      metrics(reference_date: ScoringSupport::TODAY - 90, effort_open: 0.0, effort_total: 10.0,
              risk_mapped: true, risk_raw: 0.0, blocked_count: 0, event_series: []),
      fixed_clock, config(weights: w1)
    )
    score_raw1 = h1.breakdown.select(&:active).sum(&:contribution)
    assert_in_delta 66.5, score_raw1, 1e-9, 'production path must land score_raw exactly on .5 boundary'
    assert_equal 67, h1.health_score, 'round_half_up(66.5) == 67 (banker\'s would give 66)'

    # Case 2 — score_raw == 2.5 (even integer part 2): half-up => 3; banker's => 2.
    # Retuned for the NEW momentum formula: momentum idle (n=0.0) contributes 0; the 2.5 is
    # driven by blocked_load alone. All other signals n=0; blocked n=0.25 (count 15, H 20).
    #   w_b=0.10, nb=0.25 => 100*0.10*0.25 = 2.5.
    w2 = { staleness: 0.30, progress: 0.30, momentum: 0.15, risk_load: 0.15, blocked_load: 0.10 }
    h2 = Pulse::Domain::Scoring.score(
      metrics(reference_date: ScoringSupport::TODAY - 180, effort_open: 20.0, effort_total: 10.0,
              risk_mapped: true, risk_raw: 50.0, blocked_count: 15, event_series: []),
      fixed_clock, config(weights: w2)
    )
    score_raw2 = h2.breakdown.select(&:active).sum(&:contribution)
    assert_in_delta 2.5, score_raw2, 1e-9, 'production path must land score_raw exactly on 2.5 boundary'
    assert_equal 3, h2.health_score, 'round_half_up(2.5) == 3 (banker\'s round-half-to-even would give 2)'
  end

  # ============ RAG bands (FR-22 / FC-27) ============
  # Drives the REAL scoring path: kernel_aios yields health_score 29 deterministically
  # (NEW momentum formula); we move the RAG thresholds around 29 to exercise each band
  # boundary through the production rag computation (lower bounds inclusive).
  def test_rag_default_boundaries_through_scoring
    # kernel_aios = 29 (red under defaults 67/34), pdfree = 80 (green).
    red = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_equal :red, red.rag

    green = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    assert_equal :green, green.rag
  end

  def test_rag_band_partition_inclusive_lower_bounds
    # Fix health_score == 29 (kernel_aios, NEW momentum) and slide thresholds to land it in
    # each band.
    m = kernel_aios_metrics
    # green when green_min <= 29 (inclusive boundary at 29).
    g = Pulse::Domain::Scoring.score(m, fixed_clock, config(rag_green_min: 29, rag_amber_min: 10))
    assert_equal :green, g.rag, '29 with green_min 29 => green (inclusive lower bound)'
    # amber when amber_min <= 29 < green_min; boundary amber_min == 29.
    a = Pulse::Domain::Scoring.score(m, fixed_clock, config(rag_green_min: 67, rag_amber_min: 29))
    assert_equal :amber, a.rag, '29 with amber_min 29 => amber (inclusive lower bound)'
    # red when 29 < amber_min.
    r = Pulse::Domain::Scoring.score(m, fixed_clock, config(rag_green_min: 67, rag_amber_min: 30))
    assert_equal :red, r.rag, '29 below amber_min 30 => red'
  end

  def test_rag_pinned_boundary_scores
    # Pinned 67->green / 66->amber and 34->amber / 33->red, exercised by setting
    # default thresholds (67/34) and choosing metrics whose health_score lands on the
    # boundary. We assert the partition rule via the score+threshold relationship.
    cfg = config # green_min 67, amber_min 34
    {
      67 => :green, 66 => :amber, 34 => :amber, 33 => :red
    }.each do |score, expected|
      band = if score >= cfg.rag_green_min then :green
             elsif score >= cfg.rag_amber_min then :amber
             else :red end
      assert_equal expected, band, "pinned boundary score #{score}"
    end
    # And the actual-path boundary: a score == amber_min must be amber, == amber_min+1-over red.
    m = kernel_aios_metrics # health_score 29 (NEW momentum)
    on_boundary = Pulse::Domain::Scoring.score(m, fixed_clock, config(rag_amber_min: 29, rag_green_min: 67))
    below = Pulse::Domain::Scoring.score(m, fixed_clock, config(rag_amber_min: 30, rag_green_min: 67))
    assert_equal :amber, on_boundary.rag
    assert_equal :red, below.rag
  end

  # ============ dominant_signal — SEVERITY-FIRST (FR-23 / FC-22; THAW-RA-001) ====
  # dominant_signal := the ACTIVE signal with the LOWEST normalized health n
  # (argmin_{i∈A} n_i == argmax (1 - n_i)), WEIGHT-INDEPENDENT. Tie -> CANONICAL_ORDER
  # [staleness, progress, momentum, risk_load, blocked_load]. Never nil on a scoreable
  # project (the always-active subset guarantees a non-empty active set; CR-01 retained
  # on the normal path; nil appears ONLY in the no-data state, asserted separately).
  def test_dominant_signal_argmax_kernel_aios
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    # lowest n among the 5 active = staleness (n 0.1667), the most-broken signal.
    assert_equal :staleness, h.dominant_signal
  end

  def test_dominant_signal_argmax_pdfree
    # NEW momentum formula: pdfree active {staleness 0.889, progress 0.80, momentum 0.585556,
    # blocked 0.95}. argmin = momentum (n 0.585556). BUT 0.585556 >= ON_TRACK_THRESHOLD (0.5),
    # so dominant_signal collapses to :on_track (D2). (momentum-broaden: a project whose
    # worst active signal is still >= 0.5 is "On track", not "named".)
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    assert_in_delta 0.585556, signal(h, :momentum).n, 1e-5, 'momentum is the worst active signal'
    assert_equal :on_track, h.dominant_signal,
                 'worst active signal n 0.585556 >= 0.5 => :on_track (D2)'
  end

  # ============ dominant_signal "On track" (momentum-broaden D2 / ON_TRACK_THRESHOLD=0.5) ==
  # After the severity-first argmin, if the BEST (lowest-n) active signal n >= 0.5, return
  # :on_track instead of naming the signal. Boundary is INCLUSIVE (exactly 0.5 => :on_track).
  # The no-data path returns nil BEFORE scoring (unchanged). :on_track is a NEW value.
  def test_dominant_signal_on_track_when_worst_signal_at_least_half
    # All five active and comfortably healthy: every n well above 0.5 => :on_track.
    #   staleness days 18 => n 1-18/180 = 0.90
    #   progress  ratio 0.85 (open 1.5 total 10) => n 0.85
    #   momentum  o0 c100 => n 1.0
    #   risk_raw  5 => n 1-5/50 = 0.90
    #   blocked   2 => n 1-2/20 = 0.90
    m = metrics(reference_date: ScoringSupport::TODAY - 18,
                effort_open: 1.5, effort_total: 10.0,
                risk_mapped: true, risk_raw: 5.0, blocked_count: 2,
                event_series: events_for(opened: 0, closed: 100))
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config)
    h.breakdown.select(&:active).each { |s| assert_operator s.n, :>=, 0.5 }
    assert_equal :on_track, h.dominant_signal,
                 'all active signals >= 0.5 => :on_track (D2), not a named signal'
  end

  def test_dominant_signal_names_signal_when_worst_below_half
    # Worst active signal below 0.5 => name it (NOT on_track). kernel_aios staleness n 0.1667.
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_operator signal(h, :staleness).n, :<, 0.5
    assert_equal :staleness, h.dominant_signal,
                 'worst active signal < 0.5 => name the worst signal (D2 below-threshold path)'
  end

  def test_dominant_signal_on_track_boundary_exactly_half_inclusive
    # Worst active signal n EXACTLY 0.5 => :on_track (inclusive boundary, D2).
    #   staleness days 90 => n 1-90/180 = 0.5 (the worst; the others all healthier).
    #   progress ratio 0.8 => n 0.80 ; momentum o0 c100 => n 1.0 ; risk 0 => n 1.0 ; blocked 0 => n 1.0
    m = metrics(reference_date: ScoringSupport::TODAY - 90,
                effort_open: 2.0, effort_total: 10.0,
                risk_mapped: true, risk_raw: 0.0, blocked_count: 0,
                event_series: events_for(opened: 0, closed: 100))
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config)
    assert_in_delta 0.5, signal(h, :staleness).n, 1e-9, 'staleness is exactly at the 0.5 boundary'
    assert_equal :on_track, h.dominant_signal,
                 'worst active signal n EXACTLY 0.5 => :on_track (inclusive boundary, D2)'
  end

  # --- The load-bearing divergence: severity-first vs the OLD weighted-drag definition.
  # A LOW-WEIGHT signal (risk_load, w=0.15) has the LOWEST n (most broken) while a
  # HIGH-WEIGHT signal (progress, w=0.25) has the larger weighted drag eff*(1-n).
  # OLD weighted-drag argmax => :progress (weight-biased, the bug). NEW severity-first
  # (argmin n) => :risk_load. This test FAILS against the weighted-drag impl and pins
  # the operator-approved severity-first behaviour.
  def test_dominant_signal_severity_first_low_weight_severe_signal
    # n targets: staleness 0.70, progress 0.45, momentum 0.80, risk_load 0.10, blocked 0.90.
    #   staleness days = 0.30*180 = 54  (n 0.70, w 0.25)
    #   progress  total 20 open 11 ratio 0.45 (n 0.45, w 0.25) <- OLD weighted-drag winner
    #   momentum  closed 8 opened 2 raw 6 over N=10 => n 0.80 (w 0.20)
    #   risk_raw  45 => n 1-45/50 = 0.10 (w 0.15) <- NEW severity-first winner (lowest n)
    #   blocked   2  => n 1-2/20 = 0.90 (w 0.15)
    m = metrics(reference_date: ScoringSupport::TODAY - 54,
                effort_open: 11.0, effort_total: 20.0,
                risk_mapped: true, risk_raw: 45.0, blocked_count: 2,
                event_series: events_for(opened: 2, closed: 8))
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config)
    # Sanity: risk_load is genuinely the lowest-n (most-broken) active signal.
    assert_in_delta 0.10, signal(h, :risk_load).n, 1e-9
    assert_operator signal(h, :risk_load).n, :<, signal(h, :progress).n
    # Severity-first picks the lowest-n signal, NOT the highest weighted-drag signal.
    assert_equal :risk_load, h.dominant_signal,
                 'severity-first: lowest-n risk_load wins over higher weighted-drag progress'
  end

  # A second divergence with the OTHER low-weight signal (blocked_load, w=0.15) lowest-n
  # while a higher-weight milder signal would win weighted-drag. Weight-independence proof:
  # blocked is the most broken, so it is named regardless of its small weight.
  def test_dominant_signal_severity_first_weight_independent
    # staleness n 0.55 (days 81, w0.25, drag 0.1125)  <- OLD weighted-drag winner
    # blocked   n 0.05 (count 19, w0.15, drag 0.1425) <- also OLD winner here; use a
    # config that RE-WEIGHTS to make the divergence unambiguous: bump staleness weight so
    # its weighted drag exceeds blocked's, yet blocked remains the lowest-n signal.
    w = { staleness: 0.50, progress: 0.20, momentum: 0.15, risk_load: 0.075, blocked_load: 0.075 }
    cfg = config(weights: w)
    m = metrics(reference_date: ScoringSupport::TODAY - 81, # staleness n 1-81/180 = 0.55
                effort_open: 0.0, effort_total: 10.0,        # progress n 1.0 (healthy)
                risk_mapped: true, risk_raw: 0.0,            # risk n 1.0 (healthy)
                blocked_count: 19,                           # blocked n 1-19/20 = 0.05 (worst)
                event_series: events_for(opened: 0, closed: 100)) # momentum n 1.0
    h = Pulse::Domain::Scoring.score(m, fixed_clock, cfg)
    # OLD weighted-drag: staleness 0.50*0.45 = 0.225 > blocked 0.075*0.95 = 0.07125 => :staleness.
    # NEW severity-first: blocked n 0.05 is the lowest => :blocked_load.
    assert_operator signal(h, :blocked_load).n, :<, signal(h, :staleness).n
    assert_equal :blocked_load, h.dominant_signal,
                 'severity-first is weight-independent: lowest-n blocked_load wins despite small weight'
  end

  def test_dominant_signal_all_healthy_collapses_to_on_track_never_nil
    # All five active and fully healthy (every n == 1.0). The argmin still picks a worst
    # key (staleness, on the canonical-order tie), but its n 1.0 >= ON_TRACK_THRESHOLD (0.5),
    # so dominant_signal collapses to :on_track (momentum-broaden D2). Still NEVER nil on a
    # scoreable project — :on_track is a non-nil dominant; the no-data state is the ONLY nil
    # case, asserted separately.
    h = Pulse::Domain::Scoring.score(
      metrics(reference_date: ScoringSupport::TODAY, effort_open: 0.0, effort_total: 10.0,
              risk_mapped: true, risk_raw: 0.0, blocked_count: 0,
              event_series: events_for(opened: 0, closed: 100)),
      fixed_clock, config
    )
    h.breakdown.select(&:active).each { |s| assert_in_delta 1.0, s.n, 1e-9 }
    refute_nil h.dominant_signal
    assert_equal :on_track, h.dominant_signal
  end

  def test_dominant_signal_tiebreak_canonical_order
    # Two ACTIVE signals with EQUAL lowest n -> earlier canonical wins (severity-first tie).
    # Both tied worst are BELOW the on_track threshold (0.5), so a NAMED dominant is still
    # observed (the worst-n collapse to :on_track does NOT fire) — this keeps the canonical-
    # order tiebreak path observable under momentum-broaden D2.
    # staleness n = 1-108/180 = 0.4 ; progress ratio 0.4 => n 0.4 (equal lowest); the other
    # three are healthy (n 1.0). Tie on n=0.4 => staleness (earlier in CANONICAL_ORDER).
    m = metrics(reference_date: ScoringSupport::TODAY - 108, # n = 0.4
                effort_open: 6.0, effort_total: 10.0,        # ratio 0.4 => n 0.4
                risk_mapped: true, risk_raw: 0.0, blocked_count: 0,
                event_series: events_for(opened: 0, closed: 100)) # momentum n 1 (>=0.5)
    h = Pulse::Domain::Scoring.score(m, fixed_clock, config)
    assert_in_delta 0.4, signal(h, :staleness).n, 1e-9
    assert_in_delta 0.4, signal(h, :progress).n, 1e-9
    assert_operator signal(h, :staleness).n, :<, 0.5 # below threshold => named, not on_track
    assert_equal :staleness, h.dominant_signal

    # Sibling guard: when the SAME tie sits AT/above the threshold the worst collapses to
    # :on_track instead (D2), so the named tiebreak must not leak through above 0.5.
    healthy = metrics(reference_date: ScoringSupport::TODAY, # staleness n 1.0
                      effort_open: 0.0, effort_total: 10.0,  # progress n 1.0
                      risk_mapped: true, risk_raw: 0.0, blocked_count: 0,
                      event_series: events_for(opened: 0, closed: 100))
    h2 = Pulse::Domain::Scoring.score(healthy, fixed_clock, config)
    assert_equal :on_track, h2.dominant_signal
  end

  # ============ signal_completeness (FR-24 / FC-26) ============
  def test_signal_completeness_full
    h = Pulse::Domain::Scoring.score(kernel_aios_metrics, fixed_clock, config)
    assert_in_delta 1.0, h.signal_completeness, 1e-12
  end

  def test_signal_completeness_standard_fields
    h = Pulse::Domain::Scoring.score(pdfree_metrics, fixed_clock, config)
    assert_in_delta 0.8, h.signal_completeness, 1e-12 # 4 of 5 (risk inactive)
  end

  def test_signal_completeness_min_floor
    # risk inactive AND progress inactive => 3 of 5 = 0.6. blocked_count:1 keeps the
    # project NON-EMPTY (a real blocker) so this is a minimal-active-set project, NOT the
    # no-data state (zero scoreable data) — the 0.6 floor applies to a project that has
    # SOME data on its 3 always-active signals (THAW-RA-001 no-data boundary).
    h = Pulse::Domain::Scoring.score(
      metrics(risk_mapped: false, effort_open: 0.0, effort_total: 0.0, blocked_count: 1),
      fixed_clock, config
    )
    assert_in_delta 0.6, h.signal_completeness, 1e-12
    assert_operator h.signal_completeness, :>=, 0.6
  end

  # ============ NO-DATA state (THAW-RA-001) ============
  # A project with ZERO scoreable data must render a DISTINCT no-data state, NOT a green
  # health score off a staleness-freshness floor. No-data trigger (pure-domain):
  #   effort_total == 0 (no issues / no mapped effort)  AND
  #   event_series empty (no created/closed activity)   AND
  #   blocked_count == 0 (no blockers)                  AND
  #   risk_mapped == false (no risk enrichment)
  # No-data HealthResult shape: rag :no_data, health_score nil, dominant_signal nil,
  # signal_completeness 0.0, breakdown 5 inactive SignalResults (canonical order),
  # lens_keys exactly {health,at_risk,stale,done,blocked} all nil. These tests FAIL
  # against the current impl (which scores the empty project ~green) and pin the new state.
  def no_data_metrics
    metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
            effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0, blocked_count: 0,
            risk_mapped: false, effort_mapped: false, event_series: [])
  end

  def test_no_data_state_distinct_rag_and_nil_score
    h = Pulse::Domain::Scoring.score(no_data_metrics, fixed_clock, config)
    assert_equal :no_data, h.rag, 'zero-scoreable-data project => rag :no_data, NOT :green'
    refute_equal :green, h.rag
    assert_nil h.health_score, 'no-data => health_score nil (no spurious freshness score)'
    refute_equal 86, h.health_score
    refute_equal 83, h.health_score
  end

  def test_no_data_state_nil_dominant_signal
    # No-data path returns nil BEFORE scoring — the :on_track collapse (D2) NEVER applies to
    # a no-data project (nil unchanged by momentum-broaden).
    h = Pulse::Domain::Scoring.score(no_data_metrics, fixed_clock, config)
    assert_nil h.dominant_signal, 'no-data => no "why"; dominant_signal nil (NOT a faked signal, NOT :on_track)'
  end

  def test_no_data_state_breakdown_all_inactive_and_completeness_zero
    h = Pulse::Domain::Scoring.score(no_data_metrics, fixed_clock, config)
    assert_equal 5, h.breakdown.length
    assert_equal ScoringSupport::CANONICAL_ORDER, h.breakdown.map(&:key)
    assert h.breakdown.none?(&:active), 'no-data => every signal inactive (nothing to score)'
    assert_in_delta 0.0, h.signal_completeness, 1e-12
  end

  def test_no_data_state_lens_keys_present_but_nil
    h = Pulse::Domain::Scoring.score(no_data_metrics, fixed_clock, config)
    assert_equal %i[at_risk blocked done health stale], h.lens_keys.keys.sort, 'lens key SET preserved (FC-23)'
    h.lens_keys.each_value { |v| assert_nil v, 'no-data lens values are nil (N/A)' }
  end

  def test_no_data_boundary_one_issue_scores_normally
    # effort_total == 1 (one scoreable issue, standard-field count fallback) => NOT no-data;
    # progress becomes active and the project scores on the normal path.
    h = Pulse::Domain::Scoring.score(
      metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
              effort_open: 1.0, effort_total: 1.0, risk_raw: 0.0, blocked_count: 0,
              risk_mapped: false, effort_mapped: false, event_series: []),
      fixed_clock, config
    )
    refute_equal :no_data, h.rag, '1 issue => scores normally, not no-data'
    assert_kind_of Integer, h.health_score
    refute_nil h.dominant_signal
  end

  def test_no_data_not_triggered_by_activity_only_project
    # No effort/issues, but real momentum activity (closed issues) => scoreable => NOT no-data.
    h = Pulse::Domain::Scoring.score(
      metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
              effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0, blocked_count: 0,
              risk_mapped: false, effort_mapped: false,
              event_series: events_for(opened: 0, closed: 5)),
      fixed_clock, config
    )
    refute_equal :no_data, h.rag, 'activity (closed events) is scoreable => not no-data'
    assert_kind_of Integer, h.health_score
  end

  def test_no_data_not_triggered_by_blocked_only_project
    # No effort/issues/events, but a real blocker => scoreable blocked_load => NOT no-data.
    h = Pulse::Domain::Scoring.score(
      metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
              effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0, blocked_count: 1,
              risk_mapped: false, effort_mapped: false, event_series: []),
      fixed_clock, config
    )
    refute_equal :no_data, h.rag, 'a blocker is scoreable data => not no-data'
    assert_kind_of Integer, h.health_score
  end

  def test_no_data_not_triggered_by_risk_only_project
    # [remediation R1 / RARB-INV-01] risk-ONLY boundary.
    # A project with real risk DATA (risk_raw > 0, risk_mapped true) but zero effort, empty
    # events, and zero blockers must NOT enter the no-data branch: risk_raw > 0 breaks the
    # fourth no_data? conjunct, so the project is scoreable. risk_load is active/non-nil and
    # the project scores on the normal path. (Symmetric to the activity-only / blocked-only
    # boundary guards above — this backfills the risk_raw>0 case.)
    h = Pulse::Domain::Scoring.score(
      metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
              effort_open: 0.0, effort_total: 0.0, risk_raw: 3.0, blocked_count: 0,
              risk_mapped: true, effort_mapped: false, event_series: []),
      fixed_clock, config
    )
    refute_equal :no_data, h.rag, 'risk_raw > 0 is scoreable per-project data => NOT no-data'
    assert_kind_of Integer, h.health_score, 'a risk-only project scores a real Integer health_score'
    risk = signal(h, :risk_load)
    assert risk.active, 'risk_load must be ACTIVE for a risk-mapped project with risk_raw > 0'
    refute_nil risk.n, 'an active risk_load carries a non-nil normalized health (risk_load active/non-nil)'
    refute_nil risk.raw_value, 'an active risk_load carries a non-nil raw_value'
  end

  def test_no_data_fires_when_risk_configured_globally_but_project_empty
    # aieyes-found escape: risk_mapped is GLOBAL config (is a risk tracker configured),
    # NOT per-project data. In a real instance with a risk tracker configured,
    # risk_mapped == true for EVERY project, so an old `risk_mapped == false` conjunct
    # would NEVER fire no-data for a genuinely empty (0-issue) project. The no-data
    # trigger must depend on per-project DATA: risk_raw == 0 (this project has no risk
    # issues). This project is genuinely empty (no effort, no events, no blockers, no
    # risk issues) yet a risk tracker IS configured globally (risk_mapped: true) => the
    # distinct no-data state must STILL fire.
    h = Pulse::Domain::Scoring.score(
      metrics(project_id: 7, reference_date: ScoringSupport::TODAY,
              effort_open: 0.0, effort_total: 0.0, risk_raw: 0.0, blocked_count: 0,
              risk_mapped: true, effort_mapped: false, event_series: []),
      fixed_clock, config
    )
    assert_equal :no_data, h.rag,
                 'empty project with a globally-configured risk tracker => still no-data (per-project risk_raw==0)'
    assert_nil h.health_score, 'no-data => health_score nil even when risk_mapped true globally'
  end
end
