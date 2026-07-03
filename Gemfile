# frozen_string_literal: true

# Plugin-local gem dependencies. Redmine merges this into its own bundle at boot.
# The domain layer itself is stdlib-only (INV-DOMAIN-PURITY); the only addition
# here is a test-time JSON Schema validator for the API contract tests.

group :test do
  gem 'json-schema' # AC-API-SCHEMA: validate API payloads against contracts/schemas/*
end
