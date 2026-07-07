# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Domain
    # AlertEvent — a deeply-frozen immutable value object describing ONE detected
    # health transition for a project. PURE DOMAIN: no
    # ActiveRecord / Redmine / Setting / Mailer / clock reference; standard library only.
    #
    # Fields:
    #   project_id     : Integer                (validated: Integer, else ArgumentError)
    #   event_type     : Symbol                 (one of EVENT_TYPES, else ArgumentError)
    #   from / to      : any (typically String) (String fields dup.freeze'd — see below)
    #   score          : Numeric|nil            (current health_score at the transition)
    #   previous_score : Numeric|nil            (prior health_score)
    #   delta          : Numeric|nil            (score - previous_score, or nil)
    #   occurred_at    : Time                    (injected; no ambient clock in the domain)
    #
    # IMMUTABILITY-HOLE LESSON (timeline-engine): `frozen_string_literal` freezes only
    # String LITERALS, not interpolated / passed-in String values. So a String `from`/`to`
    # passed by the caller MUST be dup.freeze'd before assignment — otherwise mutating the
    # caller's original leaks into the stored field. `freeze_value` does exactly this for
    # String (and Symbol, defensively) fields; nil / Numeric are already immutable.
    class AlertEvent
      EVENT_TYPES = %i[rag_transition dominant_change no_data_appeared score_delta].freeze

      attr_reader :project_id, :event_type, :from, :to,
                  :score, :previous_score, :delta, :occurred_at

      def initialize(project_id:, event_type:, from:, to:,
                     score:, previous_score:, delta:, occurred_at:)
        raise ArgumentError, "project_id must be an Integer (got #{project_id.inspect})" \
          unless project_id.is_a?(Integer)
        raise ArgumentError, "event_type must be one of #{EVENT_TYPES.inspect} (got #{event_type.inspect})" \
          unless EVENT_TYPES.include?(event_type)

        @project_id     = project_id
        @event_type     = event_type
        @from           = freeze_value(from)
        @to             = freeze_value(to)
        @score          = score
        @previous_score = previous_score
        @delta          = delta
        @occurred_at    = occurred_at

        freeze
      end

      # Value equality: two events built from identical args are equal (deterministic
      # detection). Compares the full field tuple.
      def ==(other)
        other.is_a?(AlertEvent) && state == other.state
      end
      alias eql? ==

      def hash
        state.hash
      end

      protected

      def state
        [project_id, event_type, from, to, score, previous_score, delta, occurred_at]
      end

      private

      # Store an independent FROZEN copy of a mutable String (the dup.freeze idiom), so a
      # later mutation of the caller's original cannot leak into this VO. Symbols are frozen
      # already but pass through the same path for uniformity; nil / Numeric are immutable.
      def freeze_value(value)
        return value if value.nil?
        return value.dup.freeze if value.is_a?(String)

        value.frozen? ? value : value.freeze
      end
    end
  end
end
