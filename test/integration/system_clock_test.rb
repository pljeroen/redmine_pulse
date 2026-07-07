# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))

# SystemClock#today returns a Date in the instance-configured timezone, NOT UTC
# Requires Pulse::Adapters::SystemClock.
#
# Canonical API: Pulse::Adapters::SystemClock.new.today -> Date (== Time.zone.today)
class SystemClockTest < ActiveSupport::TestCase
  def with_time_zone(zone)
    old = Time.zone
    Time.zone = zone
    yield
  ensure
    Time.zone = old
  end

  def test_today_returns_a_plain_date
    today = Pulse::Adapters::SystemClock.new.today
    assert_instance_of Date, today
  end

  def test_today_matches_instance_time_zone
    with_time_zone('Pacific/Kiritimati') do # UTC+14
      assert_equal Time.zone.today, Pulse::Adapters::SystemClock.new.today,
                   'SystemClock#today == Time.zone.today (instance tz), not UTC Date'
    end
  end

  def test_today_uses_zone_not_utc_at_day_boundary
    # Freeze a wall instant where the UTC date and the +14 zone date differ.
    travel_to Time.utc(2026, 6, 20, 12, 0, 0) do
      with_time_zone('Pacific/Kiritimati') do
        assert_equal Time.zone.today, Pulse::Adapters::SystemClock.new.today
      end
    end
  end

  # ── snapshot-max-age-refresh: the age check uses @clock.now,
  # an absolute instant (UTC), NOT a bare Time.now. SystemClock must expose #now
  # returning a Time ~ Time.now.utc.

  def test_now_returns_a_time
    now = Pulse::Adapters::SystemClock.new.now
    assert_kind_of Time, now, 'SystemClock#now must return a Time (absolute instant)'
  end

  def test_now_is_approximately_time_now
    before = Time.now.utc
    now = Pulse::Adapters::SystemClock.new.now
    after = Time.now.utc
    # #now must be a real current instant bracketed by two Time.now.utc reads (allow a
    # small slack for clock granularity).
    assert_operator now.to_f, :>=, before.to_f - 1.0,
                    'SystemClock#now must be ~ the current instant'
    assert_operator now.to_f, :<=, after.to_f + 1.0,
                    'SystemClock#now must be ~ the current instant'
  end

  def test_now_is_utc
    now = Pulse::Adapters::SystemClock.new.now
    assert_equal 0, now.utc_offset,
                 'SystemClock#now must be a UTC instant (utc_offset 0)'
  end
end
