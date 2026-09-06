# frozen_string_literal: true

require "json"

RSpec.describe Agentilda::StateFile, :tree do
  subject(:state) { described_class.new(path:, pid: 4242) }

  let(:path) { File.join(plans_root, described_class::DIRNAME, described_class::FILENAME) }

  it "lives under .plans/tmp" do
    tree = Agentilda::Tree.new(dir: plans_root)
    expect(described_class.for(tree)).to eq(path)
  end

  it "starts empty, saves atomically, and loads what it saved" do
    state.begin_run!(root: "/repo")
    state.record("001.00", agent: "leah-researcher", round: 1, status: "Started", model: "haiku")
    state.save
    loaded = described_class.new(path:, pid: 4242).load
    aggregate_failures do
      expect(loaded.stages("001.00").first).to include("agent" => "leah-researcher", "status" => "Started", "model" => "haiku")
      expect(JSON.parse(File.read(path)).dig("run", "pid")).to eq(4242)
      expect(Dir.children(File.dirname(path))).to eq([described_class::FILENAME])
    end
  end

  it "merges later fields into the same stage rather than adding a second one" do
    state.record("001.00", agent: "leah-researcher", round: 1, status: "Started")
    state.record("001.00", agent: "leah-researcher", round: 1, status: "Completed", up: 12)
    expect(state.stages("001.00").size).to eq(1)
    expect(state.stages("001.00").first).to include("status" => "Completed", "up" => 12)
  end

  it "keeps a second round as its own stage" do
    state.record("001.00", agent: "leah-researcher", round: 1, status: "Interrupted")
    state.record("001.00", agent: "leah-researcher", round: 2, status: "Started")
    expect(state.stages("001.00").map { |s| s["round"] }).to eq([1, 2])
  end

  # A harness that died leaves Started stages behind; the next one must
  # know they are stranded rather than still running.
  it "reports stages a dead run left Started as stranded" do
    dead = described_class.new(path:, pid: 999_999_999)
    dead.begin_run!(root: "/repo")
    dead.record("001.00", agent: "yoda-writer", round: 1, status: "Started")
    dead.record("002.00", agent: "leah-researcher", round: 1, status: "Completed")
    dead.save

    fresh = described_class.new(path:, pid: 4242).load
    aggregate_failures do
      expect(fresh).to be_previous_run_dead
      expect(fresh.stranded.map { |ordinal, stage| [ordinal, stage["agent"]] }).to eq([["001.00", "yoda-writer"]])
    end
  end

  it "does not call a live run's Started stages stranded" do
    state.begin_run!(root: "/repo")
    state.record("001.00", agent: "yoda-writer", round: 1, status: "Started")
    state.save
    fresh = described_class.new(path:, pid: 4242).load
    expect(fresh.stranded).to be_empty
  end

  describe ".ensure_ignored!" do
    it "adds .plans/tmp/ to .gitignore once, and says so" do
      root = File.dirname(plans_root)
      system("git", "-C", root, "init", "-q")
      aggregate_failures do
        expect(described_class.ensure_ignored!(root)).to be(true)
        expect(File.read(File.join(root, ".gitignore"))).to include(".plans/tmp/\n")
        expect(described_class.ensure_ignored!(root)).to be(false)
      end
    end

    it "does nothing outside a repository" do
      expect(described_class.ensure_ignored!(File.dirname(plans_root))).to be(false)
    end
  end
end
