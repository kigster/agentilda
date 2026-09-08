# frozen_string_literal: true

require "yaml"

# The shipped example project is the evals' fixture, and its CSV files are
# the right answers. With the judge stubbed from `verdicts.yml`, the whole
# command must score 100 against them — which is what makes the CSVs
# trustworthy when the live judge scores less.
RSpec.describe Agentilda::Evals do
  let(:fixture) { Agentilda::Evals::EXAMPLE_PROJECT }
  let(:oracle) { YAML.safe_load_file(File.join(fixture, "verdicts.yml")) }
  let(:resolver) { instance_double(Agentilda::Resolver) }

  before do
    allow(Agentilda::Resolver).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:call) { |pulls|
      pulls.map { |pull|
        v = oracle.fetch(pull[:number]) { raise "##{pull[:number]} reached the judge but verdicts.yml does not expect it" }
        Agentilda::Resolver::Verdict.new(number: pull[:number], plan: v["plan"] && Agentilda::Ordinal.parse(v["plan"]),
          confidence: v["confidence"].to_f, dev: v["dev"] == true, reason: v["reason"].to_s, up: 1000, down: 30, cost: 0.002)
      }
    }
  end

  def score(expected_file, actual, key)
    Agentilda::Evals::Score.new(expected: Agentilda::Evals::Score.read(File.join(fixture, expected_file)), actual:, key:).call
  end

  describe Agentilda::Evals::Run do
    it "scores 100 against the committed answers, and never touches the fixture" do
      before = Dir.glob(File.join(fixture, "**", "*")).sort
      outcome = described_class.new(source: fixture).call

      aggregate_failures do
        expect(score("plans.csv", outcome.plans, "before").lines).to be_empty
        expect(score("prs.csv", outcome.prs, "number").lines).to be_empty
        expect(Dir.glob(File.join(fixture, "**", "*")).sort).to eq(before)
        expect(File.read(File.join(fixture, ".prs", "4.md"))).to include("title: Add mooring booking form")
      end
    end

    it "scores 100 against the --force answers" do
      outcome = described_class.new(source: fixture, force: true).call

      expect(score("prs-force.csv", outcome.prs, "number").lines).to be_empty
    end

    it "reads what the run reported spending" do
      expect(described_class.new(source: fixture).call.spent).to include(up: 8000, down: 240)
    end

    it "asks the judge afresh rather than reading a cache" do
      described_class.new(source: fixture).call

      expect(Agentilda::Resolver).to have_received(:new).with(hash_including(cache_dir: nil))
    end
  end

  describe "the fixture" do
    it "exercises every path of the pipeline" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "p")
        FileUtils.cp_r(fixture, root)
        tree = Agentilda::Tree.new(dir: File.join(root, ".plans"))
        Agentilda::Resync::Dirs.new(tree:).call(commit: true)
        changes = Agentilda::Resync::Prs.new(tree:, github: Agentilda::FakeGitHub.new(dir: File.join(root, ".prs")), resolver:).plan

        expect(changes.map(&:kind).uniq).to include(:branch, :folder, :dev, :judged, :timeline, :straggler)
      end
    end
  end

  describe Agentilda::Evals::Score do
    let(:expected) { [{"number" => "1", "after" => "a"}, {"number" => "2", "after" => "b"}, {"number" => "3", "after" => "c"}] }

    it "is 100 when every row matches" do
      expect(described_class.new(expected:, actual: expected, key: "number").call.score).to eq(100.0)
    end

    it "counts a wrong value, a missing row and an unexpected row as one discrepancy each" do
      actual = [{"number" => "1", "after" => "a"}, {"number" => "2", "after" => "WRONG"}, {"number" => "9", "after" => "z"}]
      result = described_class.new(expected:, actual:, key: "number").call

      aggregate_failures do
        expect(result.hits).to eq(1)
        expect(result.wrong.map { |r| r["key"] }).to eq(["2"])
        expect(result.missing.map { |r| r["key"] }).to eq(["3"])
        expect(result.unexpected.map { |r| r["key"] }).to eq(["9"])
        expect(result.score).to eq(25.0)
        expect(result.lines.size).to eq(3)
      end
    end

    it "is 0 when every row is wrong, and 100 when nothing was expected or produced" do
      aggregate_failures do
        expect(described_class.new(expected:, actual: [], key: "number").call.score).to eq(0.0)
        expect(described_class.new(expected: [], actual: [], key: "number").call.score).to eq(100.0)
      end
    end

    it "reads a CSV with a header" do
      expect(described_class.read(File.join(fixture, "prs.csv")).first).to include("number" => "4", "after" => "[002.00] Add mooring booking form")
    end
  end
end
