# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/alert_event'

module Pulse
  module Domain
    # AlertRules — PURE transition detection (C6 / FR-C6-02 / FR-C6-06 / FC-C6-01/02/03).
    # stdlib + Pulse::Domain only; no ActiveRecord / Redmine / Setting / Mailer / clock.
    #
    #   evaluate(prior_state, health_result, score_delta_threshold:, occurred_at:) -> frozen Array<AlertEvent>
    #
    #   prior_state    : Hash-or-nil {last_rag, last_dominant, last_no_data, last_score}
    #                    (nil OR all-fields-nil => first run / baseline => [])
    #   health_result  : Pulse::Domain::HealthResult (.rag Symbol, .dominant_signal, .health_score,
    #                    AND .project_id Integer — stamped onto every emitted AlertEvent.project_id)
    #   score_delta_threshold (N) : Numeric|nil — the canonical/global setting; DEFAULT disabled
    #                               (nil OR <= 0 => score_delta never fires)
    #   occurred_at    : Time — injected (no ambient clock in the domain)
    #
    # RECONCILED predicates (post SAT-C6-01 / SAT-C6-02). For prior p, current c:
    #   (1) rag_transition   IFF prior_rag PRESENT AND prior_rag != rag AND rag != :no_data
    #   (2) dominant_change  IFF prior_dom PRESENT AND prior_dom != dom AND BOTH non-no-data
    #   (3) no_data_appeared IFF prior_rag PRESENT AND prior_rag != :no_data AND rag == :no_data
    #   (4) score_delta      IFF N configured (non-nil AND N>0) AND prior_score PRESENT AND
    #                            current score PRESENT AND |score - prior_score| >= N
    #
    # :no_data is a REAL RAG band (Scoring::NO_DATA_RAG); in it health_score AND
    # dominant_signal are nil. Comparisons normalize prior (String) and current (Symbol)
    # to a common form, so 'green' (prior) != :amber (current) reads as a genuine change.
    # Multiple predicates may fire on one step (independence); each yields its own event.
    module AlertRules
      NO_DATA = :no_data

      module_function

      def evaluate(prior_state, health_result, score_delta_threshold: nil, occurred_at: nil)
        return [].freeze if first_run?(prior_state)

        prior_rag   = normalize(prior_state[:last_rag])
        prior_dom   = normalize(prior_state[:last_dominant])
        prior_score = prior_state[:last_score]

        rag   = normalize(health_result.rag)
        dom   = normalize(health_result.dominant_signal)
        score = health_result.health_score

        pid = health_result.project_id
        events = []

        if rag_transition?(prior_rag, rag)
          events << event(:rag_transition, pid, prior_rag, rag, score, prior_score, occurred_at)
        end

        if no_data_appeared?(prior_rag, rag)
          events << event(:no_data_appeared, pid, prior_rag, rag, score, prior_score, occurred_at)
        end

        if dominant_change?(prior_rag, rag, prior_dom, dom)
          events << event(:dominant_change, pid, prior_dom, dom, score, prior_score, occurred_at)
        end

        if score_delta?(prior_score, score, score_delta_threshold)
          events << event(:score_delta, pid, prior_score, score, score, prior_score, occurred_at)
        end

        events.freeze
      end

      # First run / baseline: no prior row (nil) OR every prior field is nil (a row that has
      # never been evaluated). Nothing fires — no first-cron flood (FC-C6-03).
      def first_run?(prior_state)
        return true if prior_state.nil?

        [prior_state[:last_rag], prior_state[:last_dominant],
         prior_state[:last_no_data], prior_state[:last_score]].all?(&:nil?)
      end

      # (1) prior present, band actually changed, and the NEW band is not :no_data
      #     (into-no-data is handled by no_data_appeared, not rag_transition — SAT-C6-01).
      def rag_transition?(prior_rag, rag)
        !prior_rag.nil? && prior_rag != rag && rag != NO_DATA.to_s
      end

      # (3) prior present, prior was NOT no_data, and the current band IS :no_data.
      def no_data_appeared?(prior_rag, rag)
        !prior_rag.nil? && prior_rag != NO_DATA.to_s && rag == NO_DATA.to_s
      end

      # (2) prior present, dominant key changed, and BOTH prior and current bands are
      #     non-no-data (in :no_data the dominant is nil, so a change into/out of no_data
      #     must NOT masquerade as a dominant_change).
      def dominant_change?(prior_rag, rag, prior_dom, dom)
        return false if prior_dom.nil? || dom.nil?
        return false if prior_rag == NO_DATA.to_s || rag == NO_DATA.to_s

        prior_dom != dom
      end

      # (4) N configured (non-nil AND > 0), both scores present, |delta| >= N. nil-safe:
      #     a nil on either side (into/out-of no_data) never fires and never raises.
      def score_delta?(prior_score, score, threshold)
        return false if threshold.nil?
        return false unless threshold.is_a?(Numeric) && threshold > 0
        return false if prior_score.nil? || score.nil?

        (score - prior_score).abs >= threshold
      end

      # Normalize a rag / dominant value to a String for cross-type comparison (prior is
      # stored as a String; current is a Symbol). nil stays nil (absent / no-data).
      def normalize(value)
        return nil if value.nil?

        value.to_s
      end

      def event(event_type, project_id, from, to, score, previous_score, occurred_at)
        delta = (score.nil? || previous_score.nil?) ? nil : (score - previous_score)
        AlertEvent.new(
          project_id: project_id, event_type: event_type,
          from: from, to: to,
          score: score, previous_score: previous_score, delta: delta,
          occurred_at: occurred_at
        )
      end
    end
  end
end
