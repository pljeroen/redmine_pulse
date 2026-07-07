# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require_relative '../../domain_test_helper'
require 'date'
require 'pulse/domain/retrospective_bucket'

# RetrospectiveBucket value-object shape: frozen, explicit {at:Date, provenance:
# :derived_bucket} boundaries, real Integer event_count, fail-loud on bad input.
class TimelineBucketValueObjectTest < Minitest::Test
  START_AT = Date.new(2026, 6, 6)
  END_AT   = Date.new(2026, 6, 13)

  def build(**overrides)
    args = {
      start: { at: START_AT, provenance: :derived_bucket },
      end: { at: END_AT, provenance: :derived_bucket },
      event_count: 3
    }.merge(overrides)
    Pulse::Domain::RetrospectiveBucket.new(**args)
  end

  # --- immutability ---
  def test_bucket_is_frozen_at_construction
    assert build.frozen?, 'RetrospectiveBucket must be frozen at construction'
  end

  def test_mutation_raises_frozen_error
    b = build
    assert_raises(FrozenError) { b.instance_variable_set(:@event_count, 99) } if b.frozen?
  end

  # --- explicit Date boundaries tagged :derived_bucket ---
  def test_start_and_end_boundaries_are_plain_dates
    b = build
    assert_instance_of Date, b.start[:at]
    assert_instance_of Date, b.end[:at]
    refute_kind_of DateTime, b.start[:at], 'boundary :at must be a plain Date, not DateTime'
    refute_kind_of DateTime, b.end[:at], 'boundary :at must be a plain Date, not DateTime'
  end

  def test_boundary_provenance_is_derived_bucket
    b = build
    assert_equal :derived_bucket, b.start[:provenance]
    assert_equal :derived_bucket, b.end[:provenance]
  end

  # --- event_count is a real Integer >= 0 ---
  def test_event_count_is_non_negative_integer
    b = build(event_count: 0)
    assert_instance_of Integer, b.event_count
    assert_equal 0, b.event_count
  end

  def test_negative_event_count_rejected_fail_loud
    assert_raises(ArgumentError) { build(event_count: -1) }
  end

  def test_non_integer_event_count_rejected
    assert_raises(ArgumentError) { build(event_count: 2.0) }
  end

  # --- reject a non-Date / Time boundary (no invented time-of-day) ---
  def test_rejects_time_typed_boundary
    assert_raises(ArgumentError) do
      build(start: { at: Time.new(2026, 6, 6), provenance: :derived_bucket })
    end
  end

  def test_rejects_boundary_provenance_outside_closed_set
    assert_raises(ArgumentError) do
      build(end: { at: END_AT, provenance: :version_due_date })
    end
  end

  # --- stdlib-only field types ---
  def test_fields_are_stdlib_types_only
    b = build
    assert_kind_of Hash, b.start
    assert_kind_of Hash, b.end
    assert_kind_of Symbol, b.start[:provenance]
    assert_kind_of Integer, b.event_count
  end

  # --- optional breakdown sums to event_count when present ---
  def test_breakdown_counts_sum_to_event_count_when_present
    b = build(event_count: 5, issue_created_count: 3, issue_closed_count: 2)
    assert_equal 3, b.issue_created_count
    assert_equal 2, b.issue_closed_count
    assert_equal b.event_count, b.issue_created_count + b.issue_closed_count,
                 'event_count must equal created + closed when breakdown present'
  end

  def test_breakdown_not_summing_to_event_count_rejected
    assert_raises(ArgumentError) do
      build(event_count: 5, issue_created_count: 3, issue_closed_count: 1)
    end
  end

  def test_negative_breakdown_count_rejected
    assert_raises(ArgumentError) do
      build(event_count: 1, issue_created_count: -1, issue_closed_count: 2)
    end
  end
end
