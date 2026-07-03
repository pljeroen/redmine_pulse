# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/signal_result'

module Pulse
  module Domain
    # Pure per-signal computations. Each method returns a SignalDatum (key/active/
    # raw_value/n). Scoring later derives effective_weight + contribution over the
    # active set and emits the final SignalResult. The current day is read ONLY via
    # the injected clock; the domain never reads the system calendar directly.
    module Signals
      # Intermediate, pre-weight datum produced by each signal method. Carries the
      # per-signal facts (active, raw_value, normalised n) before the active set —
      # and thus effective_weight / contribution — is known. effective_weight and
      # contribution are always nil at this stage (filled in by Scoring). Immutable.
      class SignalDatum
        attr_reader :key, :active, :raw_value, :n, :effective_weight, :contribution

        def initialize(key:, active:, raw_value:, n:)
          @key = key
          @active = active
          @raw_value = raw_value
          @n = n
          @effective_weight = nil
          @contribution = nil
          freeze
        end
      end

      module_function

      def clamp(x, lo, hi)
        return lo if x < lo
        return hi if x > hi

        x
      end

      # Staleness — always active. raw = days since reference (may be negative).
      # n = clamp(1 - days/H_stale, 0, 1).  (FR-06, FR-07, FC-13)
      def staleness(metrics, clock, config)
        days = (clock.today - metrics.reference_date).to_i
        n = clamp(1.0 - days / config.h_stale.to_f, 0.0, 1.0)
        SignalDatum.new(key: :staleness, active: true, raw_value: days, n: n)
      end

      # Progress — active iff effort_total > 0 (CR-04, no nil branch).
      # raw = 1 - open/total (progress_ratio, stored raw); n = clamp(raw, 0, 1).
      def progress(metrics, _config)
        if metrics.effort_total > 0
          ratio = 1.0 - metrics.effort_open / metrics.effort_total.to_f
          n = clamp(ratio, 0.0, 1.0)
          SignalDatum.new(key: :progress, active: true, raw_value: ratio, n: n)
        else
          SignalDatum.new(key: :progress, active: false, raw_value: nil, n: nil)
        end
      end

      # Momentum — always active ("Active = healthy", momentum-broaden D1). Half-open
      # window [today-W, today): today-W IS in, today is OUT. Tally all four activity
      # types in-window; recent activity LIFTS momentum, net open/close direction is only
      # a small ± bias.
      #   activity  = opened + closed + comments + commits
      #   base      = activity / (activity + config.momentum_activity_half)  # 0 -> 0.5 -> ->1
      #   direction = (closed - opened) / max(closed + opened, 1)            # ∈ [-1, 1]
      #   n         = clamp(base + config.momentum_direction_bias * direction, 0, 1)
      # raw_value = activity (Integer total) — informational.
      def momentum(metrics, clock, config)
        today = clock.today
        window_start = today - config.activity_window_days
        opened = 0
        closed = 0
        comments = 0
        commits = 0
        metrics.event_series.each do |e|
          d = e[:date]
          next unless d >= window_start && d < today

          case e[:type]
          when :issue_created   then opened += 1
          when :issue_closed    then closed += 1
          when :issue_commented then comments += 1
          when :commit          then commits += 1
          end
        end
        activity = opened + closed + comments + commits
        base = activity.to_f / (activity + config.momentum_activity_half)
        direction = (closed - opened).to_f / [closed + opened, 1].max
        n = clamp(base + config.momentum_direction_bias * direction, 0.0, 1.0)
        SignalDatum.new(key: :momentum, active: true, raw_value: activity, n: n)
      end

      # Risk load — active iff risk_mapped. raw = risk_raw; n = clamp(1 - risk_raw/H_risk,0,1).
      def risk_load(metrics, config)
        if metrics.risk_mapped
          n = clamp(1.0 - metrics.risk_raw / config.h_risk.to_f, 0.0, 1.0)
          SignalDatum.new(key: :risk_load, active: true, raw_value: metrics.risk_raw, n: n)
        else
          SignalDatum.new(key: :risk_load, active: false, raw_value: nil, n: nil)
        end
      end

      # Blocked load — always active. raw = blocked_count; n = clamp(1 - count/H_blocked,0,1).
      def blocked_load(metrics, config)
        n = clamp(1.0 - metrics.blocked_count / config.h_blocked.to_f, 0.0, 1.0)
        SignalDatum.new(key: :blocked_load, active: true, raw_value: metrics.blocked_count, n: n)
      end
    end
  end
end
