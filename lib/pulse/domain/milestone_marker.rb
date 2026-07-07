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
    # Immutable forward milestone marker. One per version_due_dates entry. Pure data —
    # standard-library types only (Integer/String/Date/Symbol/Hash); no Rails/AR/IO. The
    # complete shape is EXACTLY {version_id:Integer, name:String(non-empty),
    # due_date:{date:Date, provenance::version_due_date}} satisfying project.json
    # #/$defs/milestone. name is a passthrough of entry[:name] — never invented. Fails loud
    # (ArgumentError) on bad input.
    class MilestoneMarker
      PROVENANCE = :version_due_date

      attr_reader :version_id, :name, :due_date

      def initialize(version_id:, name:, due_date:)
        validate_version_id!(version_id)
        validate_name!(name)
        validate_due_date!(due_date)

        @version_id = version_id
        @name = name.dup.freeze
        @due_date = deep_freeze_due_date(due_date)

        freeze
      end

      private

      def deep_freeze_due_date(due_date)
        due_date.dup.freeze
      end

      def validate_version_id!(version_id)
        return if version_id.is_a?(Integer)

        raise ArgumentError, "version_id must be an Integer (got #{version_id.class})"
      end

      # name is REQUIRED, a non-empty String (whitespace-only counts as empty), always.
      def validate_name!(name)
        unless name.is_a?(String)
          raise ArgumentError, "name must be a String (got #{name.class})"
        end
        return unless name.strip.empty?

        raise ArgumentError, "name must be a non-empty String (got #{name.inspect})"
      end

      def validate_due_date!(due_date)
        unless due_date.is_a?(Hash)
          raise ArgumentError, "due_date must be a Hash (got #{due_date.class})"
        end
        # instance_of? excludes DateTime/Time — plain Date only.
        unless due_date[:date].instance_of?(Date)
          raise ArgumentError,
                "due_date :date must be a plain Date (got #{due_date[:date].class})"
        end
        unless due_date[:provenance] == PROVENANCE
          raise ArgumentError,
                "due_date :provenance must be #{PROVENANCE.inspect} " \
                "(got #{due_date[:provenance].inspect})"
        end
      end
    end
  end
end
