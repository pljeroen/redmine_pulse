# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'date'

module Pulse
  module Domain
    # Immutable value object carrying already-supplied, already-visibility-scoped
    # input aggregates for one project. Pure data — no Rails/AR types (FC-21/FC-31).
    #
    # Fails loud (ArgumentError) on any value outside the FR-01 state space, and
    # defensively deep-copies + deep-freezes its caller-owned collections so a later
    # mutation of the originals cannot affect this object (FR-01 immutable VO /
    # INV-DETERMINISTIC).
    class ProjectMetrics
      EVENT_TYPES = %i[issue_created issue_closed issue_commented commit].freeze

      attr_reader :project_id, :reference_date, :effort_open, :effort_total,
                  :risk_raw, :blocked_count, :risk_mapped, :effort_mapped,
                  :event_series, :version_due_dates

      def initialize(project_id:, reference_date:, effort_open:, effort_total:,
                     risk_raw:, blocked_count:, risk_mapped:, effort_mapped:,
                     event_series:, version_due_dates:)
        validate_integer!(:project_id, project_id)
        validate_date!(:reference_date, reference_date)
        validate_non_negative_numeric!(:effort_open, effort_open)
        validate_non_negative_numeric!(:effort_total, effort_total)
        validate_non_negative_numeric!(:risk_raw, risk_raw)
        validate_non_negative_integer!(:blocked_count, blocked_count)
        validate_boolean!(:risk_mapped, risk_mapped)
        validate_boolean!(:effort_mapped, effort_mapped)
        validate_event_series!(event_series)
        validate_version_due_dates!(version_due_dates)

        @project_id = project_id
        @reference_date = reference_date
        @effort_open = effort_open
        @effort_total = effort_total
        @risk_raw = risk_raw
        @blocked_count = blocked_count
        @risk_mapped = risk_mapped
        @effort_mapped = effort_mapped
        @event_series = deep_freeze_entries(event_series)
        @version_due_dates = deep_freeze_entries(version_due_dates)

        freeze
      end

      private

      # Defensive deep-copy + deep-freeze: dup each element hash and the array so
      # post-construction mutation of the caller's originals cannot reach us, then
      # freeze each hash and the array so the exposed collection raises FrozenError.
      # String values within each hash are dup.freeze'd so a caller-held mutable
      # String aliased to an entry value cannot mutate stored state (A10-TL-001).
      def deep_freeze_entries(entries)
        entries.map do |entry|
          frozen_entry = entry.transform_values { |v| v.is_a?(String) ? v.dup.freeze : v }
          frozen_entry.freeze
        end.freeze
      end

      def validate_integer!(name, value)
        return if value.is_a?(Integer)

        raise ArgumentError, "#{name} must be an Integer (got #{value.class})"
      end

      def validate_date!(name, value)
        # instance_of? excludes DateTime (a Date subclass) per FR-38 (plain Date only).
        return if value.instance_of?(Date)

        raise ArgumentError, "#{name} must be a Date (got #{value.class}) (CR-04)"
      end

      def validate_non_negative_numeric!(name, value)
        # Finite, real, ordered Numeric only (Integer / finite Float / Rational).
        # Type + finiteness are checked BEFORE the `< 0` comparison so an unordered
        # numeric (Complex) never reaches `<` (which would leak NoMethodError), and
        # so NaN/±Infinity (which slip past `< 0`) are rejected as ArgumentError.
        finite_real_numeric!(name, value)
        return unless value < 0

        raise ArgumentError, "#{name} must be >= 0 (got #{value})"
      end

      # Central guard: accept ONLY a finite, real, ordered Numeric — i.e. an
      # Integer, a Rational, or a Float that is neither NaN nor Infinite. Reject
      # everything else (Complex, non-Numeric, NaN, ±Infinity) with ArgumentError.
      def finite_real_numeric!(name, value)
        unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)
          raise ArgumentError,
                "#{name} must be a finite real Numeric (got #{value.class}) (CR-04)"
        end
        if value.is_a?(Float) && !value.finite?
          raise ArgumentError, "#{name} must be finite (got #{value})"
        end
      end

      def validate_non_negative_integer!(name, value)
        validate_integer!(name, value)
        return unless value < 0

        raise ArgumentError, "#{name} must be >= 0 (got #{value})"
      end

      def validate_boolean!(name, value)
        return if value == true || value == false

        raise ArgumentError, "#{name} must be true or false (got #{value.inspect})"
      end

      def validate_event_series!(event_series)
        unless event_series.is_a?(Array)
          raise ArgumentError, "event_series must be an Array (got #{event_series.class})"
        end

        event_series.each do |entry|
          unless entry.is_a?(Hash)
            raise ArgumentError, "event_series entries must be Hashes (got #{entry.class})"
          end
          unless entry[:date].instance_of?(Date)
            raise ArgumentError,
                  "event_series entry :date must be a Date (got #{entry[:date].class})"
          end
          unless EVENT_TYPES.include?(entry[:type])
            raise ArgumentError,
                  "event_series entry :type must be one of #{EVENT_TYPES.inspect} (got #{entry[:type].inspect})"
          end
        end
      end

      def validate_version_due_dates!(version_due_dates)
        unless version_due_dates.is_a?(Array)
          raise ArgumentError, "version_due_dates must be an Array (got #{version_due_dates.class})"
        end

        version_due_dates.each do |entry|
          unless entry.is_a?(Hash)
            raise ArgumentError, "version_due_dates entries must be Hashes (got #{entry.class})"
          end
          unless entry[:version_id].is_a?(Integer)
            raise ArgumentError,
                  "version_due_dates entry :version_id must be an Integer (got #{entry[:version_id].class})"
          end
          unless entry[:due_date].instance_of?(Date)
            raise ArgumentError,
                  "version_due_dates entry :due_date must be a Date (got #{entry[:due_date].class})"
          end
          # D-TL-C (TC-11c): :name is REQUIRED, a non-empty String (whitespace-only is
          # empty). Mirrors the :version_id/:due_date checks; the domain receives name
          # as DATA and never invents it.
          unless entry[:name].is_a?(String)
            raise ArgumentError,
                  "version_due_dates entry :name must be a String (got #{entry[:name].class}) (TC-11c)"
          end
          if entry[:name].strip.empty?
            raise ArgumentError,
                  "version_due_dates entry :name must be a non-empty String (got #{entry[:name].inspect}) (TC-11c)"
          end
        end
      end
    end
  end
end
