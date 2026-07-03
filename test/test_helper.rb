# frozen_string_literal: true

# Functional / integration tests run INSIDE a host Redmine instance and use
# Redmine's own test harness + fixtures (e.g. permission-scope tests against
# Redmine permission fixtures — AC-PERMISSION). Run via Redmine's rake task:
#
#   bin/rails redmine:plugins:test NAME=redmine_pulse RAILS_ENV=test
#
# For the PURE domain scoring engine (no Redmine needed), use
# test/domain_test_helper.rb instead — see DEC-03 / AC-SCORE-DETERMINISM.
require File.expand_path('../../../../test/test_helper', __FILE__)
