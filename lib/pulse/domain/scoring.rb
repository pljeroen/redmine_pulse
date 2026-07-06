# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/signals'
require 'pulse/domain/signal_result'
require 'pulse/domain/health_result'
require 'pulse/domain/signal_registry'

module Pulse
  module Domain
    # Pure composite scoring + lens computation. Reads `today` ONLY via clock.today.
    module Scoring
      # Distinct RAG band for a project with zero scoreable data (THAW-RA-001).
      NO_DATA_RAG = :no_data

      module_function

      # round_half_up applied ONCE to score_raw (FC-06). NOT Float#round (no banker's).
      def round_half_up(x)
        (x + 0.5).floor
      end

      # A project with ZERO scoreable data renders a DISTINCT no-data state rather than a
      # spurious freshness score (THAW-RA-001). Trigger (pure-domain), all four conjuncts
      # PER-PROJECT DATA: no mapped/issue effort, no created/closed activity, no blockers,
      # and no risk issues. risk_raw == 0 (this project has no risk issues) is used instead
      # of risk_mapped, because risk_mapped is GLOBAL config (whether a risk tracker is
      # configured), not per-project data — keying no-data on it never fires for a genuinely
      # empty project in any instance with a risk tracker configured (aieyes-found escape).
      def no_data?(metrics)
        metrics.effort_total == 0 &&
          metrics.event_series.empty? &&
          metrics.blocked_count == 0 &&
          metrics.risk_raw == 0
      end

      # No-data HealthResult: rag :no_data, nil health_score/dominant_signal, completeness
      # 0.0, one inactive SignalResult per ENABLED signal in canonical order, the 5 lens
      # keys all nil, and the effort_open passthrough (THAW-RA-001). Carries no Date field
      # (FC-31). The breakdown key-set/length tracks the config's enabled set (default 5);
      # on the default config this reproduces the pre-C1 five-row canonical sequence exactly.
      def no_data_result(metrics, config)
        HealthResult.new(
          project_id: metrics.project_id,
          health_score: nil,
          rag: NO_DATA_RAG,
          dominant_signal: nil,
          signal_completeness: 0.0,
          breakdown: enabled_in_canonical_order(config).map do |key|
            SignalResult.new(key: key, active: false, raw_value: nil, n: nil,
                             effective_weight: nil, contribution: nil)
          end,
          lens_keys: { health: nil, at_risk: nil, stale: nil, done: nil, blocked: nil },
          effort_open: metrics.effort_open
        )
      end

      def score(metrics, clock, config)
        return no_data_result(metrics, config) if no_data?(metrics)

        data = collect_data(metrics, clock, config)

        active = data.select(&:active)
        active_weight_sum = active.sum { |d| config.weights[d.key] }

        # effective_weight_i = w_i / Σ_{A} w_j ; contribution_i = 100 * eff * n_i.
        eff = {}
        contrib = {}
        active.each do |d|
          w = config.weights[d.key] / active_weight_sum
          eff[d.key] = w
          contrib[d.key] = 100.0 * w * d.n
        end

        score_raw = active.sum { |d| contrib[d.key] }
        health_score = [[round_half_up(score_raw), 0].max, 100].min

        breakdown = data.map do |d|
          if d.active
            SignalResult.new(key: d.key, active: true, raw_value: d.raw_value, n: d.n,
                             effective_weight: eff[d.key], contribution: contrib[d.key])
          else
            SignalResult.new(key: d.key, active: false, raw_value: nil, n: nil,
                             effective_weight: nil, contribution: nil)
          end
        end

        HealthResult.new(
          project_id: metrics.project_id,
          health_score: health_score,
          rag: rag_band(health_score, config),
          dominant_signal: dominant_signal(active, config),
          signal_completeness: active.size / config.enabled_signals.size.to_f,
          breakdown: breakdown,
          lens_keys: lens_keys(health_score, data, eff, metrics),
          effort_open: metrics.effort_open
        )
      end

      # --- helpers -------------------------------------------------------------

      # Compute ONLY the enabled signals, emitted in the registry's canonical order
      # restricted to the enabled set. On the default 5-signal set this reproduces the
      # pre-C1 fixed sequence [staleness, progress, momentum, risk_load, blocked_load]
      # exactly (same methods, same order) so the byte-identical golden gate holds.
      def collect_data(metrics, clock, config)
        enabled = enabled_in_canonical_order(config)
        enabled.map { |key| compute_signal(key, metrics, clock, config) }
      end

      # The config's enabled set (dom of weights) in the registry's canonical order.
      def enabled_in_canonical_order(config)
        enabled = config.enabled_signals
        SignalRegistry.canonical_order_keys.select { |k| enabled.include?(k) }
      end

      # Dispatch a single signal computation by key. Isolates the per-signal argument
      # shape (some take the clock) behind one call site keyed off the registry.
      def compute_signal(key, metrics, clock, config)
        case key
        when :staleness    then Signals.staleness(metrics, clock, config)
        when :progress     then Signals.progress(metrics, config)
        when :momentum     then Signals.momentum(metrics, clock, config)
        when :risk_load    then Signals.risk_load(metrics, config)
        when :blocked_load then Signals.blocked_load(metrics, config)
        else
          raise ArgumentError, "unknown signal #{key.inspect}"
        end
      end

      def rag_band(score, config)
        if score >= config.rag_green_min
          :green
        elsif score >= config.rag_amber_min
          :amber
        else
          :red
        end
      end

      # SEVERITY-FIRST (THAW-RA-001): the active signal with the LOWEST normalized health
      # n (most broken) — argmin_{A} n_i, WEIGHT-INDEPENDENT. Tie -> earlier CANONICAL_ORDER.
      # Never nil on the normal path (the always-active subset guarantees a non-empty active
      # set; CR-01); nil appears ONLY in the no-data state, handled before scoring.
      def dominant_signal(active, config)
        best_key = nil
        best_n = nil
        # iterate in the registry's canonical order (restricted to active, i.e. the
        # enabled ∩ active set) so equal-n ties resolve to the earliest canonical signal.
        SignalRegistry.canonical_order_keys.each do |key|
          d = active.find { |x| x.key == key }
          next unless d

          if best_n.nil? || d.n < best_n
            best_n = d.n
            best_key = key
          end
        end
        # momentum-broaden D2: if the worst active signal is itself healthy (n >= the
        # inclusive on_track_threshold), there is no concern worth naming — show :on_track.
        return :on_track if best_key && best_n >= config.on_track_threshold

        best_key
      end

      def lens_keys(health_score, data, eff, metrics)
        staleness = data.find { |d| d.key == :staleness }
        progress = data.find { |d| d.key == :progress }

        # at_risk lens enrichment (FR-26): sum eff*(1-n) over the at_risk signals that
        # are ENABLED (present in data) AND active. The at_risk subset is sourced from
        # the registry; iterated in the pinned pre-C1 sequence [risk_load, blocked_load,
        # staleness] so the Float summation order (hence the byte-identical golden gate)
        # is preserved exactly.
        at_risk = at_risk_sum_keys.sum do |key|
          d = data.find { |x| x.key == key }
          d&.active ? eff[key] * (1.0 - d.n) : 0.0
        end

        # staleness/progress may be DISABLED (absent from data) under a non-default
        # enabled set — a disabled signal contributes nil to its lens (no data to show).
        {
          health: health_score,
          at_risk: 100.0 * at_risk,
          stale: staleness&.raw_value,
          done: progress&.active ? progress.raw_value * 100.0 : nil,
          blocked: metrics.blocked_count
        }
      end

      # The at_risk subset (from the registry) in the FIXED pre-C1 summation order.
      # SignalRegistry.at_risk_keys is the source of truth for MEMBERSHIP; this pins the
      # ORDER of accumulation to the historical sequence so the golden gate stays exact.
      PRE_C1_AT_RISK_ORDER = %i[risk_load blocked_load staleness].freeze

      def at_risk_sum_keys
        members = SignalRegistry.at_risk_keys
        PRE_C1_AT_RISK_ORDER.select { |k| members.include?(k) } +
          members.reject { |k| PRE_C1_AT_RISK_ORDER.include?(k) }
      end
    end
  end
end
