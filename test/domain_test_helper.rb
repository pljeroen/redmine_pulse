# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Domain unit tests exercise the pure-Ruby scoring engine (lib/pulse/domain)
# WITHOUT a Redmine instance: the domain layer uses only the standard library
# (no framework deps), so its tests are runnable standalone and deterministic
# for a fixed input + injected clock. Run e.g.:
#
#   ruby -Itest -Ilib test/unit/domain/scoring_determinism_test.rb
require 'minitest/autorun'

lib = File.expand_path('../../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
