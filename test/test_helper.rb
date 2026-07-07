# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Functional / integration tests run INSIDE a host Redmine instance and use
# Redmine's own test harness + fixtures (e.g. permission-scope tests against
# Redmine permission fixtures). Run via Redmine's rake task:
#
#   bin/rails redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test
#
# For the PURE domain scoring engine (no Redmine needed), use
# test/domain_test_helper.rb instead.
require File.expand_path('../../../../test/test_helper', __FILE__)
