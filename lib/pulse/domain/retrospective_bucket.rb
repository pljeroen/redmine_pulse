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
    # Immutable retrospective sparkline bucket (one 7-day half-open interval of the
    # rolling window). Pure data — standard-library types only (Date/Symbol/Integer/Hash);
    # no Rails/AR/IO. Each boundary is {at: Date, provenance: :derived_bucket}. event_count
    # is the REAL aggregate of in-window events: a real Integer >= 0, never
    # nil/interpolated. Fails loud (ArgumentError) on bad input.
    class RetrospectiveBucket
      PROVENANCE = :derived_bucket

      attr_reader :start, :end, :event_count, :issue_created_count, :issue_closed_count

      def initialize(start:, end:, event_count:, issue_created_count: nil,
                     issue_closed_count: nil)
        # `end` is a reserved word; bind the keyword arg via its local-variable name.
        end_boundary = binding.local_variable_get(:end)
        validate_boundary!(:start, start)
        validate_boundary!(:end, end_boundary)
        validate_non_negative_integer!(:event_count, event_count)
        validate_breakdown!(event_count, issue_created_count, issue_closed_count)

        @start = deep_freeze_boundary(start)
        @end = deep_freeze_boundary(end_boundary)
        @event_count = event_count
        @issue_created_count = issue_created_count
        @issue_closed_count = issue_closed_count

        freeze
      end

      private

      # Deep-copy + deep-freeze the boundary Hash so a later mutation of the caller's
      # original cannot reach us and the exposed Hash raises FrozenError on mutation.
      def deep_freeze_boundary(boundary)
        boundary.dup.freeze
      end

      def validate_boundary!(name, boundary)
        unless boundary.is_a?(Hash)
          raise ArgumentError, "#{name} boundary must be a Hash (got #{boundary.class})"
        end
        # instance_of? excludes DateTime (a Date subclass) — plain Date only.
        unless boundary[:at].instance_of?(Date)
          raise ArgumentError,
                "#{name} boundary :at must be a plain Date (got #{boundary[:at].class})"
        end
        unless boundary[:provenance] == PROVENANCE
          raise ArgumentError,
                "#{name} boundary :provenance must be #{PROVENANCE.inspect} " \
                "(got #{boundary[:provenance].inspect})"
        end
      end

      def validate_non_negative_integer!(name, value)
        # instance_of? excludes Float (2.0) and any non-Integer Numeric.
        unless value.instance_of?(Integer)
          raise ArgumentError, "#{name} must be an Integer (got #{value.class})"
        end
        return unless value < 0

        raise ArgumentError, "#{name} must be >= 0 (got #{value})"
      end

      # The breakdown is optional. If EITHER count is present, BOTH are validated as
      # non-negative Integers and their sum must equal event_count.
      def validate_breakdown!(event_count, created, closed)
        return if created.nil? && closed.nil?

        validate_non_negative_integer!(:issue_created_count, created)
        validate_non_negative_integer!(:issue_closed_count, closed)
        return if created + closed == event_count

        raise ArgumentError,
              "issue_created_count + issue_closed_count (#{created + closed}) must equal " \
              "event_count (#{event_count}) when breakdown present"
      end
    end
  end
end
