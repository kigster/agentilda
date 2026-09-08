#!/usr/bin/env ruby
# frozen_string_literal: true

# Scores `agentilda resync` against example-project/ and records the run as a
# Braintrust experiment. Run it with `just eval`; it needs BRAINTRUST_API_KEY
# in the environment and a `claude` login the shell can reach.
#
#   just eval                    # both cases: plain, and --force
#   just eval --model sonnet     # a different judge
#   just eval --dry              # score locally, log nothing to Braintrust

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agentilda"
require "optparse"

options = {model: nil, dry: false, project: "agentilda", experiment: nil}
OptionParser.new do |o|
  o.on("--model MODEL", "Judge with this model instead of the frontmatter's") { |m| options[:model] = m }
  o.on("--dry", "Score locally and log nothing") { options[:dry] = true }
  o.on("--project NAME", "Braintrust project (default: agentilda)") { |p| options[:project] = p }
  o.on("--experiment NAME", "Experiment name (default: resync-<date>)") { |e| options[:experiment] = e }
end.parse!

fixture = Agentilda::Evals::EXAMPLE_PROJECT
cases = [
  {input: {force: false}, expected: {plans: "plans.csv", prs: "prs.csv"}, tags: ["plain"]},
  {input: {force: true}, expected: {plans: "plans.csv", prs: "prs-force.csv"}, tags: ["force"]}
]

task = lambda do |input:|
  Agentilda::Evals::Run.new(source: fixture, force: input[:force], cache: false, model: options[:model]).call.to_h
end

# Braintrust may hand cases back with string keys; read either.
fetch = ->(hash, key) { hash[key] || hash[key.to_s] || hash[key.to_sym] }

scorer = lambda do |name, key|
  kind = name.delete_suffix("_score").to_sym
  Braintrust::Scorer.new(name) do |expected:, output:|
    result = Agentilda::Evals::Score.new(expected: Agentilda::Evals::Score.read(File.join(fixture, fetch.call(expected, kind))),
      actual: fetch.call(output, kind), key:).call
    result.score / 100.0
  end
end

report = lambda do |label, input, output|
  puts "== #{label}"
  %i[plans prs].each do |kind|
    expected_file = (kind == :prs && input[:force]) ? "prs-force.csv" : "#{kind}.csv"
    result = Agentilda::Evals::Score.new(expected: Agentilda::Evals::Score.read(File.join(fixture, expected_file)),
      actual: output[kind], key: (kind == :plans) ? "before" : "number").call
    puts format("  %-6s %6.2f  (%d hits, %d discrepancies)", kind, result.score, result.hits, result.discrepancies)
    result.lines.each { |line| puts "         #{line}" }
  end
  spent = output[:spent]
  puts format("  spent  %s tokens in, %s out, $%.4f", spent[:up], spent[:down], spent[:cost])
end

if options[:dry]
  cases.each { |c| report.call(c[:tags].first, c[:input], task.call(input: c[:input])) }
  exit
end

abort "BRAINTRUST_API_KEY is not set; it lives in the sopsy-encrypted .env" if ENV["BRAINTRUST_API_KEY"].to_s.empty?
require "braintrust"
Braintrust.init

outputs = {}
wrapped = ->(input:) { outputs[input] = task.call(input:) }
Braintrust::Eval.run(
  project: options[:project],
  experiment: options[:experiment] || "resync-#{Time.now.strftime("%Y%m%d-%H%M")}",
  cases:,
  task: wrapped,
  scorers: [scorer.call("plans_score", "before"), scorer.call("prs_score", "number")]
)
cases.each { |c| report.call(c[:tags].first, c[:input], outputs[c[:input]]) if outputs[c[:input]] }
