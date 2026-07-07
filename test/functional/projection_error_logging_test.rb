# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require File.expand_path('../../../../../test/test_helper', File.expand_path(__FILE__))
require File.expand_path('../../pulse_adapter_test_support', File.expand_path(__FILE__))
require 'date'

# Scoring-error observability. A corrupt snapshot payload
# or a Scoring/Timeline raise inside Engine#build_projection must surface as a
# DIAGNOSABLE log line (project_id + exception class/message + backtrace head) AND
# still re-raise — behavior unchanged, but no longer a bare opaque 500. This suite
# injects a failure via a stub store and asserts the Rails.logger spy captured it.
class ProjectionErrorLoggingTest < ActiveSupport::TestCase
  include PulseAdapterTestSupport

  # A store stub whose deserialize_metrics raises — simulating a corrupt cached
  # payload — so build_projection enters its rescue path deterministically, with no
  # Redmine harness scenario required.
  class RaisingStore
    BOOM = 'corrupt snapshot payload (injected)'

    def fetch_row(_pid, _ctx, _fp)
      { payload: { 'last_activity_at' => nil }, computed_at: Time.now.utc }
    end

    def deserialize_metrics(_payload)
      raise ArgumentError, BOOM
    end
  end

  # A minimal settings provider (the engine only needs scoring_config; it never
  # reaches it because deserialize raises first, but it must respond).
  class FixedSettings
    def scoring_config
      Pulse::Domain::ScoringConfig.new
    end

    def risk_tracker_ids
      []
    end
  end

  # A logger spy: records every #error(message) call.
  class SpyLogger
    attr_reader :errors

    def initialize
      @errors = []
    end

    def error(msg = nil)
      @errors << (msg || (block_given? ? yield : nil)).to_s
    end
  end

  ProjectStub = Struct.new(:id)

  def setup
    @engine = Pulse::Adapters::PulseProjection::Engine.new(
      metrics_source: Object.new,
      store: RaisingStore.new,
      settings_provider: FixedSettings.new,
      clock: PulseAdapterTestSupport::FixedClock.new(Date.new(2026, 6, 20))
    )
  end

  def with_spy_logger
    spy = SpyLogger.new
    original = Rails.logger
    Rails.logger = spy
    yield spy
  ensure
    Rails.logger = original
  end

  # The injected failure is RE-RAISED (observable behavior unchanged — still a 500).
  def test_projection_failure_is_re_raised
    with_spy_logger do
      err = assert_raises(ArgumentError) do
        @engine.send(:build_projection, ProjectStub.new(4242), { 'last_activity_at' => nil }, Time.now.utc)
      end
      assert_match(/#{Regexp.escape(RaisingStore::BOOM)}/, err.message)
    end
  end

  # The failure is LOGGED with the project_id + exception class + message.
  def test_projection_failure_is_logged_with_project_id_and_exception
    with_spy_logger do |spy|
      assert_raises(ArgumentError) do
        @engine.send(:build_projection, ProjectStub.new(4242), { 'last_activity_at' => nil }, Time.now.utc)
      end

      assert_equal 1, spy.errors.size, 'exactly one error line emitted'
      line = spy.errors.first
      assert_match(/project_id=4242/, line, 'log line names the failing project_id')
      assert_match(/ArgumentError/, line, 'log line names the exception class')
      assert_match(/#{Regexp.escape(RaisingStore::BOOM)}/, line, 'log line carries the message')
      assert_match(/redmine_pulse/, line, 'log line is plugin-tagged')
    end
  end

  # A logger that itself raises must NOT mask the original exception.
  def test_failing_logger_does_not_mask_original_error
    exploding = Object.new
    def exploding.error(*)
      raise 'logger is down'
    end
    original = Rails.logger
    Rails.logger = exploding
    begin
      err = assert_raises(ArgumentError) do
        @engine.send(:build_projection, ProjectStub.new(7), { 'last_activity_at' => nil }, Time.now.utc)
      end
      assert_match(/#{Regexp.escape(RaisingStore::BOOM)}/, err.message,
                   'original error survives a broken logger')
    ensure
      Rails.logger = original
    end
  end
end
