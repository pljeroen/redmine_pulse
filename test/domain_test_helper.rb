# frozen_string_literal: true

# Domain unit tests exercise the pure-Ruby scoring engine (lib/pulse/domain)
# WITHOUT a Redmine instance: the domain layer has zero framework deps
# (INV-DOMAIN-PURITY), so its tests are runnable standalone and deterministic
# for a fixed input + injected clock (AC-SCORE-DETERMINISM). Run e.g.:
#
#   ruby -Itest -Ilib test/unit/domain/scoring_determinism_test.rb
require 'minitest/autorun'

lib = File.expand_path('../../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
