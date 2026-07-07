# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # LensRanker — re-RANKS (re-orders) the portfolio projections by the selected lens,
    # worst-first, with a total + stable tie-break by project_id ascending (deterministic).
    # It NEVER re-scores: every project keeps its already-computed health_score /
    # lens_keys; only the ORDER changes. A lens that re-scored would be a bug.
    module LensRanker
      LENSES = %w[health at_risk stale done blocked].freeze
      DEFAULT_LENS = 'health'

      # Each lens orders worst-first. For health/done a HIGHER value is BETTER, so
      # worst-first is ascending value. For at_risk/stale/blocked a HIGHER value is
      # WORSE, so worst-first is descending value (negated key).
      ASCENDING_WORST = %w[health done].freeze

      # A no-data project carries nil for EVERY lens value (Scoring no-data shape). It is
      # "unscored", not the answer to any "which is most X" question, so it sorts
      # CONSISTENTLY LAST in every lens-ordered portfolio. The sort is
      # ascending (worst-first), so a nil lens value gets a +infinity primary key to sit
      # at the bottom regardless of lens direction; scoreable projects keep their exact
      # prior ordering + project_id tie-break.
      NO_DATA_SORT_KEY = Float::INFINITY

      module_function

      def normalize_lens(raw)
        s = raw.to_s
        LENSES.include?(s) ? s : DEFAULT_LENS
      end

      # normalize_lens_with_warning(raw) -> [normalized_lens, warning_or_nil]
      #
      # The dangling-lens_ref case must degrade to the default lens
      # WITH a surfaced warning — the silent default alone (normalize_lens) is not sufficient
      # for a saved view whose lens_ref points at a removed user-authored lens. This is a pure,
      # stateless companion to normalize_lens (no module-level mutable state — consistent with
      # the no-data ranking module's purity):
      #   * a KNOWN lens key         -> [key, nil]
      #   * a nil / blank lens        -> [DEFAULT_LENS, nil]   ("no explicit lens", not dangling)
      #   * an UNKNOWN (dangling) key -> [DEFAULT_LENS, "<human-readable warning naming the key>"]
      def normalize_lens_with_warning(raw)
        s = raw.to_s.strip
        return [DEFAULT_LENS, nil] if s.empty?            # no explicit lens — not dangling
        return [s, nil] if LENSES.include?(s)             # a known lens — no warning

        [DEFAULT_LENS, dangling_lens_warning(s)]          # a removed/unknown key — warn
      end

      # The human-readable, LOCALIZED dangling-lens warning. Names the dangling key so
      # the operator can diagnose it; falls back to the English default when I18n is unavailable so
      # the warning is ALWAYS a non-empty readable String (the presenter renders it verbatim).
      def dangling_lens_warning(key)
        if defined?(I18n) && I18n.respond_to?(:t)
          I18n.t(:pulse_lens_dangling_warning, lens: key.inspect,
                                               default: default_lens_warning(key))
        else
          default_lens_warning(key)
        end
      end

      def default_lens_warning(key)
        "redmine_pulse: #{key.inspect} is not a known lens — " \
          'falling back to the default (health) lens'
      end

      # projections: Array<PulseProjection::Projection>. Returns a NEW ordered
      # array; inputs are not mutated and scores are untouched.
      def rank(projections, lens)
        lens = normalize_lens(lens)
        projections.sort_by do |p|
          [sort_value(p, lens), p.project.id]
        end
      end

      def sort_value(projection, lens)
        raw = projection.health.lens_keys[lens.to_sym]
        # No-data (nil lens value): always LAST, in every lens (CR-RA-1). The sort is
        # ascending, so +infinity sinks it to the bottom regardless of lens direction.
        return [NO_DATA_SORT_KEY] if raw.nil?

        if ASCENDING_WORST.include?(lens)
          # higher = better -> worst-first ascending.
          [raw.to_f]
        else
          # higher = worse -> worst-first means largest first (negate to ascending).
          [-(raw.to_f)]
        end
      end
    end
  end
end
