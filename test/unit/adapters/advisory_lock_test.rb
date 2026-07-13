# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'minitest/autorun'
begin
  require 'minitest/mock' # Object#stub — native on minitest 5.x (Redmine 6.1).
rescue LoadError => e # minitest 6.x (Redmine 7 / Rails 8.1) dropped minitest/mock.
  raise unless e.path == 'minitest/mock'
  require File.expand_path('../../support/portable_stub', __dir__)
end

# AdvisoryLock port + three adapters — pure-adapter unit lane (F1).
#
# These tests use a hand-rolled connection SPY (not a real DB) for the SQL-shape and
# control-flow assertions (which SQL each adapter issues, that RELEASE runs in an ensure,
# that the MySQL adapter fails closed on non-acquire, that Null issues no SQL). The real-DB
# lock SEMANTICS (contention / serialization) are proven separately in the MySQL concurrency
# integration test — here we prove the adapter's OWN discipline in isolation.
#
# RED-reason at authoring time: Pulse::Ports::AdvisoryLock and the three adapters
# (Pulse::Adapters::PgAdvisoryLock / MysqlAdvisoryLock / NullAdvisoryLock) do NOT exist yet,
# so every reference NameErrors. They GREEN once A9 creates the port + adapters.
lib = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

# RED-phase load guard: the port + adapters do not exist yet, so these requires raise
# LoadError. We CAPTURE it rather than let it propagate — an unguarded top-level require of a
# not-yet-created file would abort the WHOLE shared rake test-lane loader (poisoning every
# sibling class), instead of producing a clean per-test RED here. Once A9 creates the files the
# requires succeed and ADVISORY_LOCK_LOAD_ERROR is nil, so the assertions run for real (GREEN).
ADVISORY_LOCK_LOAD_ERROR = begin
  require 'pulse/ports/advisory_lock'
  require 'pulse/adapters/pg_advisory_lock'
  require 'pulse/adapters/mysql_advisory_lock'
  require 'pulse/adapters/null_advisory_lock'
  nil
rescue LoadError => e
  e
end

module AdvisoryLockLoadGuard
  def setup
    if ADVISORY_LOCK_LOAD_ERROR
      # RED for the RIGHT reason: the port/adapter files are absent (A9 not done yet).
      flunk("AdvisoryLock port/adapters not implemented yet: #{ADVISORY_LOCK_LOAD_ERROR.message}")
    end
    super
  end
end

# A minimal connection double recording every execute/select_value SQL string. It also
# emulates #transaction(requires_new:) { ... } by just yielding (PG auto-release is the
# txn-unwind — the spy proves the SQL was issued INSIDE the transaction block).
class AdvisoryLockConnSpy
  attr_reader :sqls

  # get_lock_result: what SELECT GET_LOCK(...) returns (1 acquired, 0 timeout, nil error).
  def initialize(get_lock_result: 1)
    @sqls = []
    @get_lock_result = get_lock_result
    @in_transaction = false
  end

  def transaction(requires_new: false)
    @sqls << "BEGIN(requires_new=#{requires_new})"
    @in_transaction = true
    yield
  ensure
    @in_transaction = false
    @sqls << 'COMMIT'
  end

  def execute(sql)
    @sqls << sql
    nil
  end

  # GET_LOCK / RELEASE_LOCK are read via select_value.
  def select_value(sql)
    @sqls << sql
    return @get_lock_result if sql =~ /GET_LOCK/i
    return 1 if sql =~ /RELEASE_LOCK/i

    nil
  end

  # Adapters that quote the lock-name literal go through #quote.
  def quote(str)
    "'#{str}'"
  end

  def in_transaction?
    @in_transaction
  end
end

class AdvisoryLockPortTest < Minitest::Test
  include AdvisoryLockLoadGuard

  # ── the port is the house duck-typed doc-only module (no ABC / no inheritance) ──
  def test_port_is_a_plain_module_not_a_class
    assert_kind_of Module, Pulse::Ports::AdvisoryLock,
                   'AdvisoryLock port must be a module (house duck-typed idiom)'
    refute_kind_of Class, Pulse::Ports::AdvisoryLock,
                   'the port must NOT be a Class/ABC — it is a doc-only protocol module'
  end

  def test_all_three_adapters_respond_to_with_lock
    [Pulse::Adapters::PgAdvisoryLock,
     Pulse::Adapters::MysqlAdvisoryLock,
     Pulse::Adapters::NullAdvisoryLock].each do |klass|
      adapter = klass.new(AdvisoryLockConnSpy.new)
      assert_respond_to adapter, :with_lock,
                        "#{klass} must implement the AdvisoryLock port method #with_lock"
    end
  end
end

class PgAdvisoryLockTest < Minitest::Test
  include AdvisoryLockLoadGuard

  def test_takes_xact_lock_inside_requires_new_transaction_then_yields
    spy = AdvisoryLockConnSpy.new
    adapter = Pulse::Adapters::PgAdvisoryLock.new(spy)

    ran = false
    result = adapter.with_lock(42) do
      ran = true
      assert spy.in_transaction?, 'the block must run INSIDE the requires_new transaction'
      :block_value
    end

    assert ran, 'the block must be yielded'
    assert_equal :block_value, result, 'the block return value passes through unchanged'
    assert_includes spy.sqls, 'BEGIN(requires_new=true)',
                    'PG lock must wrap the block in a requires_new transaction (txn-scoped auto-release)'
    lock_sql = spy.sqls.find { |s| s =~ /pg_advisory_xact_lock/i }
    refute_nil lock_sql, 'PG adapter must issue pg_advisory_xact_lock'
    # Byte-identical namespace + objid derivation (R3): classid 0x70756c73, objid Integer(id).
    assert_match(/pg_advisory_xact_lock\(\s*#{0x70756c73}\s*,\s*42\s*\)/, lock_sql,
                 'classid must be 0x70756c73 and objid must be Integer(project_id) — byte-identical to today')
  end

  def test_coerces_project_id_via_integer
    spy = AdvisoryLockConnSpy.new
    adapter = Pulse::Adapters::PgAdvisoryLock.new(spy)
    adapter.with_lock('7') { nil }
    lock_sql = spy.sqls.find { |s| s =~ /pg_advisory_xact_lock/i }
    assert_match(/,\s*7\s*\)/, lock_sql, 'project_id must be Integer-coerced into the objid')
  end
end

class MysqlAdvisoryLockTest < Minitest::Test
  include AdvisoryLockLoadGuard

  def test_acquires_get_lock_yields_then_releases_in_order
    spy = AdvisoryLockConnSpy.new(get_lock_result: 1)
    adapter = Pulse::Adapters::MysqlAdvisoryLock.new(spy)

    ran = false
    result = adapter.with_lock(42) do
      ran = true
      # RELEASE_LOCK must NOT have run yet — the block executes while holding the lock.
      refute spy.sqls.any? { |s| s =~ /RELEASE_LOCK/i },
             'RELEASE_LOCK must not fire until AFTER the block completes'
      :mysql_block
    end

    assert ran, 'the block must be yielded when the lock is acquired'
    assert_equal :mysql_block, result, 'the block return value passes through unchanged'
    get_idx = spy.sqls.index { |s| s =~ /GET_LOCK/i }
    rel_idx = spy.sqls.index { |s| s =~ /RELEASE_LOCK/i }
    refute_nil get_idx, 'MySQL adapter must call GET_LOCK'
    refute_nil rel_idx, 'MySQL adapter must call RELEASE_LOCK'
    assert get_idx < rel_idx, 'GET_LOCK must precede RELEASE_LOCK'
  end

  def test_releases_lock_in_ensure_even_when_block_raises
    spy = AdvisoryLockConnSpy.new(get_lock_result: 1)
    adapter = Pulse::Adapters::MysqlAdvisoryLock.new(spy)

    assert_raises(RuntimeError) do
      adapter.with_lock(42) { raise 'boom in critical section' }
    end
    assert spy.sqls.any? { |s| s =~ /RELEASE_LOCK/i },
           'RELEASE_LOCK MUST run in an ensure even when the block raises (no held-lock leak)'
  end

  def test_fails_closed_does_not_yield_when_lock_not_acquired
    # GET_LOCK returns 0 (timeout) — the adapter MUST NOT run the critical section unlocked.
    spy = AdvisoryLockConnSpy.new(get_lock_result: 0)
    adapter = Pulse::Adapters::MysqlAdvisoryLock.new(spy)

    ran = false
    result = adapter.with_lock(42) { ran = true; :should_not_run }

    refute ran, 'FAIL CLOSED: the block MUST NOT execute when GET_LOCK does not acquire (0/timeout)'
    assert_equal [], result,
                 'fail-closed returns [] (no events emitted) so advance_state does not run unlocked'
    refute spy.sqls.any? { |s| s =~ /RELEASE_LOCK/i },
           'nothing to release when the lock was never acquired'
  end

  def test_fails_closed_when_get_lock_returns_null
    # GET_LOCK returns NULL (error/killed session) — also fail closed.
    spy = AdvisoryLockConnSpy.new(get_lock_result: nil)
    adapter = Pulse::Adapters::MysqlAdvisoryLock.new(spy)

    ran = false
    adapter.with_lock(42) { ran = true }
    refute ran, 'FAIL CLOSED: NULL from GET_LOCK (error/killed) must NOT yield the critical section'
  end

  def test_lock_name_stays_within_mysql_64_char_limit
    # ASM-03: the derived GET_LOCK name must be <= 64 chars for any plausible project_id.
    spy = AdvisoryLockConnSpy.new(get_lock_result: 1)
    adapter = Pulse::Adapters::MysqlAdvisoryLock.new(spy)
    adapter.with_lock(9_223_372_036_854_775_807) { nil } # Bigint max
    get_sql = spy.sqls.find { |s| s =~ /GET_LOCK/i }
    name = get_sql[/GET_LOCK\(\s*'([^']*)'/, 1]
    refute_nil name, 'the GET_LOCK name must be a quoted string literal (no raw interpolation)'
    assert_operator name.length, :<=, 64,
                    "the derived lock name must be <= 64 chars (MySQL limit); got #{name.length}"
  end
end

class NullAdvisoryLockTest < Minitest::Test
  include AdvisoryLockLoadGuard

  def test_yields_with_no_sql
    spy = AdvisoryLockConnSpy.new
    adapter = Pulse::Adapters::NullAdvisoryLock.new(spy)

    ran = false
    result = adapter.with_lock(42) { ran = true; :null_value }

    assert ran, 'the null adapter must still yield the block (degraded no-lock behavior)'
    assert_equal :null_value, result, 'the block return value passes through unchanged'
    assert_empty spy.sqls, 'the null adapter must issue NO SQL (no lock primitive)'
  end
end
