# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/milestone_marker'

# MilestoneMarker value object: frozen; exact shape {version_id:Integer,
# name:String(non-empty), due_date:{date:Date, provenance::version_due_date}}.
# The :name field is NOT gated — it is always present.
class TimelineMilestoneValueObjectTest < Minitest::Test
  DUE = Date.new(2026, 7, 1)

  def build(**overrides)
    args = {
      version_id: 3,
      name: 'Sprint 7',
      due_date: { date: DUE, provenance: :version_due_date }
    }.merge(overrides)
    Pulse::Domain::MilestoneMarker.new(**args)
  end

  # --- immutability ---
  def test_marker_is_frozen_at_construction
    assert build.frozen?, 'MilestoneMarker must be frozen at construction'
  end

  def test_mutation_raises_frozen_error
    mk = build
    assert_raises(FrozenError) { mk.instance_variable_set(:@version_id, 99) } if mk.frozen?
  end

  # --- version_id Integer passthrough ---
  def test_version_id_is_integer
    assert_instance_of Integer, build.version_id
    assert_equal 3, build.version_id
  end

  def test_non_integer_version_id_rejected
    assert_raises(ArgumentError) { build(version_id: '3') }
  end

  # --- due_date is a plain Date tagged :version_due_date ---
  def test_due_date_is_plain_date
    mk = build
    assert_instance_of Date, mk.due_date[:date]
    refute_kind_of DateTime, mk.due_date[:date], 'due_date.date must be a plain Date, not DateTime'
  end

  def test_due_date_provenance_is_version_due_date
    assert_equal :version_due_date, build.due_date[:provenance]
  end

  def test_rejects_time_typed_due_date
    assert_raises(ArgumentError) do
      build(due_date: { date: Time.new(2026, 7, 1), provenance: :version_due_date })
    end
  end

  def test_rejects_due_date_provenance_outside_closed_set
    assert_raises(ArgumentError) do
      build(due_date: { date: DUE, provenance: :derived_bucket })
    end
  end

  # --- name is a REQUIRED non-empty String (passthrough), UNCONDITIONAL ---
  def test_name_is_non_empty_string_passthrough
    mk = build(name: 'Sprint 7')
    assert_instance_of String, mk.name
    assert_equal 'Sprint 7', mk.name, 'name must be the passthrough of entry[:name] (not invented)'
    refute_empty mk.name
  end

  # --- name String is frozen (defensive copy) ---
  # Uses +"..." (mutable String) so the assertion fails against an implementation that does
  # not defensively copy, regardless of frozen_string_literal: true in this file.
  def test_name_is_frozen
    mk = build(name: +'Sprint 7')
    assert mk.name.frozen?, 'mk.name must be frozen'
  end

  def test_caller_mutation_of_name_string_does_not_change_marker
    orig = +'Sprint 7'  # mutable String
    mk = build(name: orig)
    orig << '-MUTATED'
    assert_equal 'Sprint 7', mk.name,
                 'MilestoneMarker must defensively copy name — caller mutation must not reach mk.name'
  end

  def test_rejects_missing_name
    assert_raises(ArgumentError) do
      Pulse::Domain::MilestoneMarker.new(
        version_id: 3, due_date: { date: DUE, provenance: :version_due_date }
      )
    end
  end

  def test_rejects_nil_name
    assert_raises(ArgumentError) { build(name: nil) }
  end

  def test_rejects_non_string_name
    assert_raises(ArgumentError) { build(name: 7) }
    assert_raises(ArgumentError) { build(name: :sprint) }
  end

  def test_rejects_empty_name
    assert_raises(ArgumentError) { build(name: '') }
  end

  def test_rejects_whitespace_only_name
    assert_raises(ArgumentError) { build(name: "   \t ") }
  end

  # --- complete shape is EXACTLY {version_id, name, due_date} ---
  def test_marker_exposes_exactly_version_id_name_due_date
    mk = build
    %i[version_id name due_date].each { |f| assert_respond_to mk, f }
    # No provenance/field outside the closed milestone shape (no computed_at).
    refute_respond_to mk, :computed_at, 'marker must NOT expose computed_at'
  end
end
