# frozen_string_literal: true

# Plugin-local gem dependencies. Redmine merges this into its own bundle at boot.
# The domain layer itself uses only the standard library (no external gems); the only
# addition here is a test-time JSON Schema validator for the API tests.

group :test do
  gem 'json-schema' # validate API payloads against the JSON schemas
end
