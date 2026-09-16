# frozen_string_literal: true

source "https://rubygems.org"

# What agentilda needs in order to run is declared in the gemspec beside this
# file, so there is one list rather than two that drift. What is left here is
# only what you need in order to work on it.
gemspec

gem "rake"
gem "yard"

# 0.2.0 adds the Line handle UI.concurrently draws through. Until it is on
# RubyGems, bundle it from its pull request branch.
gem "dry-cli-ui", github: "kigster/dry-cli-ui", branch: "kig/live-spinner-handles"

group :development do
  gem "colored2"
  gem "irb"
end

group :test do
  gem "coverage-badge"
  gem "json_schemer" # validates configuration.example.yml against configuration.schema.json
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
