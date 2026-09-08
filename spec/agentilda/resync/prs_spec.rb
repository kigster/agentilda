# frozen_string_literal: true

# Backs `agentilda resync prs` — files every pull request under the plan it
# implements. Pass one is arithmetic; pass two is `jabba-resolver`, which is
# a double here so the suite never starts a `claude` process.
RSpec.describe Agentilda::Resync::Prs, :tree do
  subject(:resync) { described_class.new(tree:, github:, resolver:, root: File.dirname(plans_root)) }

  let(:tree) { Agentilda::Tree.new(dir: plans_root) }
  let(:github) { instance_double(Agentilda::GitHub, pulls: pulls, retitle: nil) }
  let(:resolver) { instance_double(Agentilda::Resolver) }
  let(:verdicts) { {} }

  let!(:built) do
    plans do |t|
      t.plan "001.00", :new, "initial-spec", files: {"spec.md" => spec_body}
      t.plan "002.00", :approved, "dev-foundation", prs: [t.merged(2, "[002.00] Ship it")]
      t.plan "018.01", :approved, "verify-returns", prs: [t.merged(41, "[018.01] Backfill")]
    end
  end

  before do
    allow(resolver).to receive(:call) { |pending|
      pending.map { |pull| verdicts.fetch(pull[:number]) { verdict(pull[:number], plan: nil, confidence: 0.1) } }
    }
  end

  let(:changes) { resync.plan }

  def pull(number, title, branch: "kig/work-#{number}", files: [], changes: nil, merged_at: nil, created_at: Time.utc(2026, 8, 1) + number * 3600, body: "")
    {number:, title:, branch:, files:, changes: changes || files.map { |path| {path:, additions: 10, deletions: 0} },
     url: "https://github.com/example/repo/pull/#{number}", state: merged_at ? "Merged 🟣" : "Open 🟡",
     open: merged_at.nil?, merged_at:, created_at:, head_sha: "abc#{number}", body:}
  end

  def verdict(number, plan:, confidence:, dev: false, reason: "because", error: nil)
    Agentilda::Resolver::Verdict.new(number:, plan: plan && Agentilda::Ordinal.parse(plan), confidence:,
      reason:, dev:, up: 100, down: 20, cost: 0.001, cached: false, error:)
  end

  describe "which pull requests are judged" do
    let(:pulls) { [pull(10, "[002.00] Add the thing", branch: "kig/002.00-add")] }

    it "leaves a numbered title alone" do
      expect(changes).to be_empty
    end

    it "asks the resolver nothing about it" do
      changes
      expect(resolver).not_to have_received(:call)
    end

    context "under --force" do
      subject(:resync) { described_class.new(tree:, github:, resolver:, force: true, root: File.dirname(plans_root)) }

      let(:pulls) { [pull(10, "[002.00] Add the thing", branch: "kig/018.01-add")] }

      it "strips the old number and runs the pipeline from the branch" do
        expect(changes.first.new_title).to eq("[018.01] Add the thing")
      end
    end

    context "with the stale no-plan marker" do
      let(:pulls) { [pull(11, "[DEV.00] Something real", branch: "kig/something")] }
      let(:verdicts) { {11 => verdict(11, plan: "001.00", confidence: 0.9)} }

      it "re-judges it rather than restamping it" do
        expect(changes.first.new_title).to eq("[001.00] Something real")
      end
    end

    context "with [none] and [XXX]" do
      let(:pulls) { [pull(12, "[none] Open question", branch: "kig/q"), pull(13, "[XXX] Legacy", branch: "kig/l")] }
      let(:verdicts) { {12 => verdict(12, plan: "001.00", confidence: 0.85), 13 => verdict(13, plan: "002.00", confidence: 0.95)} }

      it "re-judges both" do
        expect(changes.map(&:new_title)).to eq(["[001.00] Open question", "[002.00] Legacy"])
      end
    end
  end

  describe "pass one" do
    context "when the branch names its plan" do
      let(:pulls) { [pull(10, "Add the thing", branch: "kig/002.00-add-the-thing")] }

      it "files it from the branch without consulting the model" do
        aggregate_failures do
          expect(changes.first.new_title).to eq("[002.00] Add the thing")
          expect(changes.first.kind).to eq(:branch)
          expect(resolver).not_to have_received(:call)
        end
      end
    end

    context "when the branch carries a legacy bare number" do
      let(:pulls) { [pull(11, "Older work", branch: "kig/002-older-work")] }

      it "pads it to the canonical shape" do
        expect(changes.first.new_title).to eq("[002.00] Older work")
      end
    end

    context "when the branch names a plan that does not exist" do
      let(:pulls) { [pull(17, "Typo'd branch", branch: "kig/099.00-nope")] }
      let(:verdicts) { {17 => verdict(17, plan: "001.00", confidence: 0.9)} }

      it "falls through to the judge instead of flagging" do
        expect(changes.first.new_title).to eq("[001.00] Typo'd branch")
      end
    end

    context "when most of the diff's lines sit under one plan folder" do
      let(:pulls) do
        [pull(13, "Some work", branch: "kig/fix-things", changes: [
          {path: ".plans/002.00-✅--dev-foundation/plan.md", additions: 80, deletions: 10},
          {path: "lib/thing.rb", additions: 5, deletions: 5},
          {path: "README.md", additions: 200, deletions: 0}
        ])]
      end

      it "files it there, ignoring the neutral README in the denominator" do
        aggregate_failures do
          expect(changes.first.new_title).to eq("[002.00] Some work")
          expect(changes.first.kind).to eq(:folder)
          expect(changes.first.reason).to include("90% of the diff")
        end
      end
    end

    context "when the plan folder's share is below the bar" do
      let(:pulls) do
        [pull(14, "Sweeping change", branch: "kig/fix", changes: [
          {path: ".plans/001.00-⚪️--initial-spec/spec.md", additions: 30, deletions: 0},
          {path: ".plans/002.00-✅--dev-foundation/plan.md", additions: 30, deletions: 0},
          {path: "lib/a.rb", additions: 40, deletions: 0}
        ])]
      end
      let(:verdicts) { {14 => verdict(14, plan: "001.00", confidence: 0.9)} }

      it "goes to the judge" do
        expect(changes.first.kind).to eq(:judged)
        expect(resolver).to have_received(:call).with([hash_including(number: 14)])
      end
    end

    context "when the diff has paths but no line counts" do
      let(:pulls) { [pull(16, "Write it up", branch: "kig/docs", files: [".plans/001.00-⚪️--initial-spec/spec.md"], changes: [])] }

      it "counts files instead" do
        expect(changes.first.new_title).to eq("[001.00] Write it up")
      end
    end

    context "when the title says it is a dependency bump" do
      let(:pulls) { [pull(15, "Bump json from 2.21.1 to 2.21.2", branch: "dependabot/bundler/json-2.21.2")] }

      it "marks it developer work without consulting the model" do
        aggregate_failures do
          expect(changes.first.new_title).to eq("[dev] Bump json from 2.21.1 to 2.21.2")
          expect(changes.first.kind).to eq(:dev)
          expect(resolver).not_to have_received(:call)
        end
      end
    end

    context "when a [dev] title is still developer work" do
      let(:pulls) { [pull(15, "[dev] Bump json from 2.21.1 to 2.21.2", branch: "dependabot/x")] }

      it "is reported as unchanged and never retitled" do
        aggregate_failures do
          expect(changes.first).to be_unchanged
          expect(changes.first).not_to be_applicable
        end
      end
    end
  end

  describe "pass two" do
    let(:pulls) { [pull(20, "Mystery work", branch: "kig/mystery", body: "Does a thing.")] }

    context "with a confident verdict" do
      let(:verdicts) { {20 => verdict(20, plan: "001.00", confidence: 0.85, reason: "matches the spec")} }

      it "files the pull request and keeps the verdict" do
        aggregate_failures do
          expect(changes.first.new_title).to eq("[001.00] Mystery work")
          expect(changes.first.kind).to eq(:judged)
          expect(changes.first.reason).to include("85%", "matches the spec")
          expect(changes.first).to be_judged
        end
      end
    end

    context "with a verdict that says developer work" do
      let(:verdicts) { {20 => verdict(20, plan: nil, confidence: 0.9, dev: true, reason: "editor config")} }

      it "marks it [dev]" do
        expect(changes.first.new_title).to eq("[dev] Mystery work")
      end
    end

    context "with a weak verdict" do
      let(:pulls) do
        [pull(20, "Mystery work", branch: "kig/mystery", merged_at: Time.utc(2026, 8, 10)),
          pull(2, "[002.00] Ship it", branch: "kig/002.00-ship", merged_at: Time.utc(2026, 8, 5)),
          pull(41, "[018.01] Backfill", branch: "kig/018.01-b", merged_at: Time.utc(2026, 9, 1))]
      end
      let(:verdicts) { {20 => verdict(20, plan: "018.01", confidence: 0.6)} }

      it "places it beside the plan it landed after in time, as a new sibling" do
        aggregate_failures do
          expect(changes.first.kind).to eq(:timeline)
          expect(changes.first.new_title).to eq("[002.01] Mystery work")
          expect(changes.first).to be_adopted
          expect(changes.first.reason).to include("60%", "placed by time after 002", "would adopt into 002.01")
        end
      end
    end

    context "with a weak verdict and nothing dated" do
      let(:verdicts) { {20 => verdict(20, plan: "018.01", confidence: 0.6)} }

      it "falls back to the plan the verdict named" do
        expect(changes.first.new_title).to eq("[018.02] Mystery work")
      end
    end

    context "with no plan named above the floor" do
      let(:verdicts) { {20 => verdict(20, plan: "001.00", confidence: 0.3)} }

      it "opens a new plan at the end of the stack" do
        aggregate_failures do
          expect(changes.first.kind).to eq(:straggler)
          expect(changes.first.new_title).to eq("[019.00] Mystery work")
        end
      end
    end

    context "with no verdict at all" do
      let(:verdicts) { {20 => verdict(20, plan: nil, confidence: 0, error: "claude produced no output")} }

      it "is a straggler, never a guess" do
        aggregate_failures do
          expect(changes.first.kind).to eq(:straggler)
          expect(changes.first.reason).to include("no verdict", "produced no output")
        end
      end
    end

    context "with two stragglers" do
      let(:pulls) { [pull(20, "One", branch: "kig/one"), pull(21, "Two", branch: "kig/two")] }

      it "gives them distinct numbers in pull request order" do
        expect(changes.map(&:new_title)).to eq(["[019.00] One", "[020.00] Two"])
      end
    end

    context "under --no-adopt" do
      subject(:resync) { described_class.new(tree:, github:, resolver:, adopt: false, root: File.dirname(plans_root)) }

      it "flags the straggler for a human instead of minting" do
        aggregate_failures do
          expect(changes.first).to be_ambiguous
          expect(changes.first.new_title).to be_nil
          expect(changes.first.reason).to include("--no-adopt")
        end
      end
    end
  end

  describe "#call" do
    let(:pulls) do
      [pull(10, "Add the thing", branch: "kig/002.00-add-the-thing", merged_at: Time.utc(2026, 8, 2), body: "Adds it."),
        pull(20, "Mystery work", branch: "kig/mystery")]
    end
    let(:verdicts) { {20 => verdict(20, plan: nil, confidence: 0.2)} }

    it "consults the model on a dry run but writes nothing" do
      resync.call

      aggregate_failures do
        expect(resolver).to have_received(:call)
        expect(github).not_to have_received(:retitle)
        expect(Dir.children(plans_root)).not_to include(a_string_starting_with("019.00"))
      end
    end

    it "retitles, mints and rewrites pull-requests.md under commit" do
      resync.call(commit: true)
      table = File.read(File.join(plans_root, "002.00-✅--dev-foundation", "pull-requests.md"))

      aggregate_failures do
        expect(github).to have_received(:retitle).with(number: 10, title: "[002.00] Add the thing")
        expect(github).to have_received(:retitle).with(number: 20, title: "[019.00] Mystery work")
        expect(Dir.children(plans_root)).to include("019.00-🕰️--mystery-work")
        expect(table).to include("| 10 |", '002.00\] Add the thing', "| 2 |")
      end
    end

    it "keeps prose below the table when rewriting" do
      path = File.join(plans_root, "002.00-✅--dev-foundation", "pull-requests.md")
      File.write(path, File.read(path) + "\nSome notes a person wrote.\n")
      resync.call(commit: true)

      expect(File.read(path)).to include("Some notes a person wrote.")
    end

    it "reports what the judge cost" do
      resync.call

      expect(resync.spent).to include(asked: 1, cached: 0, up: 100, down: 20)
    end
  end
end
