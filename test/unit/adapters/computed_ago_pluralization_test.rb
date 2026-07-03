# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

require 'minitest/autorun'

# The "computed N <unit> ago" label must singularise at N == 1 ("1 minute ago",
# not "1 minutes ago"). This test pins the singular selection for every unit and
# confirms the plural (and zero) cases stay plural. (It originally caught the bug
# where humanize_span picked the plural unit word unconditionally.)
#
# Runs standalone (fast) with a minimal I18n stub that mimics I18n.t's default +
# interpolation, so English rendering is faithful without the i18n gem. Under the
# Redmine harness (real I18n loaded) the guard skips the stub and the same
# assertions exercise the real en.yml unit keys — dual-mode by construction.
unless defined?(I18n)
  module I18n
    def self.t(_key, default: nil, **opts)
      s = default.to_s
      opts.each { |k, v| s = s.gsub("%{#{k}}", v.to_s) }
      s
    end
  end
end

require_relative '../../../lib/pulse/adapters/main_concern_labels'
require_relative '../../../lib/pulse/adapters/html_presenter'

class ComputedAgoPluralizationTest < Minitest::Test
  P = Pulse::Adapters::HtmlPresenter
  BASE = Time.utc(2026, 7, 3, 12, 0, 0)

  def ago(seconds)
    P.computed_ago(BASE - seconds, BASE)
  end

  # ── singular at N == 1 (the bug) ─────────────────────────────────────────────
  def test_one_second_singularises
    assert_equal 'computed 1 second ago', ago(1)
  end

  def test_one_minute_singularises
    assert_equal 'computed 1 minute ago', ago(60)
  end

  def test_one_hour_singularises
    assert_equal 'computed 1 hour ago', ago(3600)
  end

  def test_one_day_singularises
    assert_equal 'computed 1 day ago', ago(86_400)
  end

  # ── plural preserved for N != 1 (including the N == 0 fresh-snapshot case) ────
  def test_zero_seconds_stays_plural
    assert_equal 'computed 0 seconds ago', ago(0)
  end

  def test_two_minutes_stays_plural
    assert_equal 'computed 2 minutes ago', ago(120)
  end

  def test_several_days_stays_plural
    assert_equal 'computed 3 days ago', ago(3 * 86_400)
  end
end
