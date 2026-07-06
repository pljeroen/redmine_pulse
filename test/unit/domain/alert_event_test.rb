# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'pulse/domain/alert_event'
require 'time'

# C6 / FR-C6-05 / FC-C6-04 / FC-C6-14 — AlertEvent value object (PURE DOMAIN).
#
# Pulse::Domain::AlertEvent is a deeply-frozen immutable VO with fields
#   {project_id:Integer, event_type:Symbol, from, to, score:Numeric|nil,
#    previous_score:Numeric|nil, delta:Numeric|nil, occurred_at:Time}.
# event_type MUST be one of {:rag_transition,:dominant_change,:no_data_appeared,
# :score_delta}; a bogus event_type or a non-Integer project_id raises ArgumentError.
#
# IMMUTABILITY-HOLE LESSON (timeline-engine): frozen_string_literal freezes LITERALS
# but NOT interpolated / passed-in String values — so passed String fields (from/to)
# MUST be explicitly dup.freeze'd before assignment. This suite mutates the ORIGINAL
# passed-in String after construction and asserts the stored field is unchanged AND
# frozen (the dup.freeze idiom), which a naive `@from = from` would fail.
#
# Pure lane: `ruby -Itest -Ilib test/unit/domain/alert_event_test.rb`.
# RED until lib/pulse/domain/alert_event.rb exists (NameError on the constant).
class AlertEventTest < Minitest::Test
  OCC = Time.utc(2026, 7, 6, 9, 0, 0)

  def build(**overrides)
    Pulse::Domain::AlertEvent.new(**{
      project_id: 42, event_type: :rag_transition,
      from: 'green', to: 'amber',
      score: 55.0, previous_score: 80.0, delta: -25.0,
      occurred_at: OCC
    }.merge(overrides))
  end

  # ── field set + readers (FC-C6-04) ──────────────────────────────────────────
  def test_exposes_all_fields_via_attr_reader
    e = build
    assert_equal 42, e.project_id
    assert_equal :rag_transition, e.event_type
    assert_equal 'green', e.from
    assert_equal 'amber', e.to
    assert_in_delta 55.0, e.score, 1e-12
    assert_in_delta 80.0, e.previous_score, 1e-12
    assert_in_delta(-25.0, e.delta, 1e-12)
    assert_equal OCC, e.occurred_at
  end

  def test_no_setters
    e = build
    refute_respond_to e, :project_id=, 'AlertEvent must expose NO setters (immutable VO)'
    refute_respond_to e, :event_type=
    refute_respond_to e, :from=
    refute_respond_to e, :to=
  end

  # ── (a) instance frozen; String fields frozen (FC-C6-04a) ───────────────────
  def test_instance_is_frozen
    assert build.frozen?, 'AlertEvent instance must be frozen after construction'
  end

  def test_string_fields_are_frozen
    e = build
    assert e.from.frozen?, 'from String field must be frozen (dup.freeze idiom)'
    assert e.to.frozen?,   'to String field must be frozen (dup.freeze idiom)'
  end

  # ── the immutability-hole lesson: mutating the ORIGINAL must not leak in ─────
  def test_mutating_passed_in_string_does_not_affect_stored_field
    from_arg = +'green'   # a MUTABLE (unfrozen) String, as a caller might pass
    to_arg   = +'amber'
    e = Pulse::Domain::AlertEvent.new(
      project_id: 7, event_type: :rag_transition, from: from_arg, to: to_arg,
      score: nil, previous_score: nil, delta: nil, occurred_at: OCC
    )
    # Mutate the ORIGINAL references AFTER construction.
    from_arg << '_MUTATED'
    to_arg   << '_MUTATED'
    assert_equal 'green', e.from, 'stored from must be an independent frozen copy (dup.freeze)'
    assert_equal 'amber', e.to,   'stored to must be an independent frozen copy (dup.freeze)'
    assert e.from.frozen?
    assert e.to.frozen?
  end

  # ── (b) mutating a field raises FrozenError ─────────────────────────────────
  def test_mutation_raises_frozen_error
    e = build
    assert_raises(FrozenError) { e.instance_variable_set(:@event_type, :bogus) } if e.frozen?
  end

  # ── (c) invalid event_type => ArgumentError (FC-C6-04c) ─────────────────────
  def test_bogus_event_type_raises_argument_error
    assert_raises(ArgumentError) { build(event_type: :bogus) }
  end

  def test_nil_event_type_raises_argument_error
    assert_raises(ArgumentError) { build(event_type: nil) }
  end

  def test_each_of_the_four_event_types_is_accepted
    %i[rag_transition dominant_change no_data_appeared score_delta].each do |t|
      e = build(event_type: t)
      assert_equal t, e.event_type
    end
  end

  # ── (d) non-Integer project_id => ArgumentError (FC-C6-04d) ─────────────────
  def test_non_integer_project_id_raises_argument_error
    assert_raises(ArgumentError) { build(project_id: 'x') }
  end

  def test_nil_project_id_raises_argument_error
    assert_raises(ArgumentError) { build(project_id: nil) }
  end

  # ── (e) two events with identical args are value-equal (FC-C6-01/04e) ───────
  def test_two_events_with_identical_args_are_value_equal
    assert_equal build, build,
                 'AlertEvent built with identical args must be value-equal (deterministic detection)'
  end

  def test_events_differing_in_a_field_are_not_equal
    refute_equal build, build(to: 'red')
  end

  # ── nil-valued numeric fields are permitted (no_data / no-score events) ─────
  def test_nil_score_fields_permitted
    e = build(score: nil, previous_score: nil, delta: nil)
    assert_nil e.score
    assert_nil e.previous_score
    assert_nil e.delta
    assert e.frozen?
  end
end
