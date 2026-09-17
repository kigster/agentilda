# frozen_string_literal: true

source "https://rubygems.org"

# What agentilda needs in order to run is declared in the gemspec beside this
# file, so there is one list rather than two that drift. What is left here is
# only what you need in order to work on it.
gemspec

gem "rake"
gem "yard"

group :development do
  gem "colored2"
  gem "irb"
end

group :test do
  gem "coverage-badge"
  gem "json_schemer" # validates configuration.example.yml against configuration.schema.json
  # ratatui_ruby's own test_helper hard-requires "minitest/mock" (for its
  # Terminal/EventInjection mixins), which minitest 6.x dropped entirely.
  # Pinned to the last line that still ships Mock, purely so `require
  # "ratatui_ruby/test_helper"` resolves; RSpec itself never touches minitest.
  gem "minitest", "~> 5.27"
  gem "rspec"
  gem "rspec-its"
  gem "rspec_junit_formatter" # JUnit XML for CircleCI store_test_results
  gem "simplecov"
end

group :development, :test do
  gem "rubocop"
  gem "rubocop-rspec"
  gem "rubocop-rake"
  gem "rubocop-rubycw"
  gem "rubocop-on-rbs"
end
