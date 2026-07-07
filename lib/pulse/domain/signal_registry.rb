# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Domain
    # SignalRegistry — the canonical static catalog of the built-in health signals and
    # the SINGLE SOURCE OF TRUTH for which signals exist, in what canonical order, with
    # what default weight, which are always-active, and which enrich the at_risk lens.
    #
    # The original constants (ScoringConfig::DEFAULT_WEIGHTS / ALWAYS_ACTIVE_KEYS and
    # Scoring::CANONICAL_ORDER / AT_RISK_KEYS) are MOVED here; downstream code queries the
    # registry structurally (count derived from the catalog, never a literal 5). Pure
    # domain: standard library only, no I/O, no system-time/entropy, all data frozen at load.
    module SignalRegistry
      # Immutable per-signal record. Every field present + correctly typed
      # (default_on is a Boolean present on EVERY record).
      class Signal
        attr_reader :key, :default_weight, :canonical_order

        def initialize(key:, always_active:, default_weight:, canonical_order:, at_risk:,
                       default_on:)
          @key = key
          @always_active = always_active
          @default_weight = default_weight
          @canonical_order = canonical_order
          @at_risk = at_risk
          @default_on = default_on
          freeze
        end

        def always_active?
          @always_active
        end

        def at_risk?
          @at_risk
        end

        # Whether this signal is enabled by the DEFAULT (no-arg) ScoringConfig.
        # The 5 original built-ins are default_on:true; coverage_gap is default_on:false.
        def default_on?
          @default_on
        end
      end

      # The canonical catalog. Declaration order IS the canonical order; canonical_order
      # is assigned as the 0-based index so it is a total strict (injective) order that
      # reproduces the removed Scoring::CANONICAL_ORDER sequence exactly.
      # coverage_gap is registered AFTER blocked_load (canonical_order 5,
      # the sixth entry) but is default_on:false — registered yet NOT enabled by the
      # default (no-arg) ScoringConfig, so the default-OFF path stays the 5 original built-ins
      # and the byte-identical golden reference holds.
      SIGNALS = [
        { key: :staleness,    always_active: true,  default_weight: 0.25, at_risk: true,  default_on: true },
        { key: :progress,     always_active: false, default_weight: 0.25, at_risk: false, default_on: true },
        { key: :momentum,     always_active: true,  default_weight: 0.20, at_risk: false, default_on: true },
        { key: :risk_load,    always_active: false, default_weight: 0.15, at_risk: true,  default_on: true },
        { key: :blocked_load, always_active: true,  default_weight: 0.15, at_risk: true,  default_on: true },
        { key: :coverage_gap, always_active: false, default_weight: 0.15, at_risk: false, default_on: false }
      ].each_with_index.each_with_object({}) do |(attrs, idx), acc|
        acc[attrs[:key]] = Signal.new(canonical_order: idx, **attrs)
      end.freeze

      module_function

      # All registered signal keys, in canonical order.
      def keys
        SIGNALS.keys
      end

      # The record for a key. Raises KeyError for an unregistered key (fail loud).
      def fetch(key)
        SIGNALS.fetch(key)
      end

      # Membership predicate — is this a registered signal?
      def registered?(key)
        SIGNALS.key?(key)
      end

      # Keys in canonical order (helper; equals the removed CANONICAL_ORDER sequence).
      def canonical_order_keys
        keys.sort_by { |k| fetch(k).canonical_order }
      end

      # {key => default_weight} for the DEFAULT-ON signals only, in canonical
      # order. Scoped to default_on:true so the sum stays 1.0 (NOT 1.15) — coverage_gap
      # (default_on:false) is EXCLUDED. This is the weight map a no-arg ScoringConfig uses.
      def default_weights
        default_on_keys.map { |k| [k, fetch(k).default_weight] }.to_h
      end

      # The DEFAULT-ON signal keys (default_on:true) in canonical order — the
      # 5 original built-ins; coverage_gap (default_on:false) is absent.
      def default_on_keys
        canonical_order_keys.select { |k| fetch(k).default_on? }
      end

      # The always-active subset keys: {staleness, momentum, blocked_load}.
      def always_active_keys
        keys.select { |k| fetch(k).always_active? }
      end

      # The at_risk lens-enrichment subset keys: {risk_load, blocked_load, staleness}.
      def at_risk_keys
        keys.select { |k| fetch(k).at_risk? }
      end

      # The default enabled set == the DEFAULT-ON signals. Originally this was every
      # built-in (default-all pass-through); coverage_gap is registered as default_on:false,
      # so the default enabled set is now the 5 default_on keys (== default_on_keys). Resolved
      # programmatically from the catalog; NEVER persisted to settings (fingerprint stability).
      def default_enabled_keys
        default_on_keys
      end
    end
  end
end
