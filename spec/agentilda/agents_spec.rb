# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Agentilda::Agents do
  subject(:agents) { described_class.new(dir: @dir) }

  around do |example|
    Dir.mktmpdir("agents") do |tmp|
      @dir = tmp
      %w[leah-researcher luke-backend lando-broker hansolo-reviewer].each do |name|
        File.write(File.join(tmp, "#{name}.md"), <<~MD)
          ---
          name: #{name}
          description: #{name} does its one thing.
          handles: [building]
          ---
          Prompt for #{name}.
        MD
      end
      example.run
    end
  end

  def names(result) = result.map(&:name)

  # `run --agent` and `run --skip` narrow the roster the loop assigns from,
  # so the narrowing has to live here rather than in the command.
  describe "#only and #without" do
    it "keeps exactly the agents named" do
      expect(names(agents.only("luke-backend").all)).to eq(["luke-backend"])
    end

    it "drops exactly the agents named, preserving order" do
      expect(names(agents.without("luke-backend", "lando-broker").all))
        .to eq(%w[hansolo-reviewer leah-researcher])
    end

    it "derives a roster the original does not share state with" do
      agents.only("luke-backend")

      expect(names(agents.all).size).to eq(4)
    end
  end

  # `agents describe leah` should not make anyone type the whole hyphenated
  # name, let alone the file name with its extension.
  describe "#match" do
    it "finds an agent by its exact name" do
      expect(names(agents.match("luke-backend"))).to eq(%w[luke-backend])
    end

    it "accepts the file name tab completion produces" do
      expect(names(agents.match("leah-researcher.md"))).to eq(%w[leah-researcher])
    end

    it "accepts a whole path, since completion in agents/ yields one" do
      expect(names(agents.match("agents/lando-broker.md"))).to eq(%w[lando-broker])
    end

    it "finds an agent by the first word of its name" do
      expect(names(agents.match("leah"))).to eq(%w[leah-researcher])
    end

    it "finds an agent by a fragment from the middle" do
      expect(names(agents.match("review"))).to eq(%w[hansolo-reviewer])
    end

    it "returns every candidate when the fragment fits several" do
      expect(names(agents.match("l"))).to contain_exactly("lando-broker", "leah-researcher", "luke-backend")
    end

    # An exact hit must never be widened: an agent named `luke` alongside
    # `luke-backend` would otherwise make `luke` permanently ambiguous.
    it "prefers an exact name over the prefixes it also fits" do
      File.write(File.join(@dir, "luke.md"), <<~MD)
        ---
        name: luke
        description: The short-named one.
        handles: [building]
        ---
        Prompt.
      MD

      expect(names(agents.match("luke"))).to eq(%w[luke])
    end

    it "returns nothing for a fragment no name contains" do
      expect(agents.match("chewbacca")).to be_empty
    end
  end

  describe "an agent's own timeout" do
    it "reads a positive timeout from the frontmatter" do
      File.write(File.join(@dir, "slowpoke.md"), <<~MD)
        ---
        name: slowpoke
        description: Takes its time.
        handles: [building]
        timeout: 1800
        ---
        Prompt.
      MD

      expect(agents.find("slowpoke").timeout).to eq(1800)
    end

    it "leaves the timeout nil when the definition says nothing, deferring to the run" do
      expect(agents.find("luke-backend").timeout).to be_nil
    end

    # A zero or negative timeout would abandon the agent before it starts;
    # nothing an author writes should be able to mean that.
    it "treats a non-positive timeout as unset" do
      File.write(File.join(@dir, "hasty.md"), <<~MD)
        ---
        name: hasty
        description: Misconfigured.
        handles: [building]
        timeout: 0
        ---
        Prompt.
      MD

      expect(agents.find("hasty").timeout).to be_nil
    end
  end

  describe "the ledger, rounds, effort and the rename hooks" do
    let(:agents) { described_class.new }

    it "lists the documents each agent signs, in order" do
      aggregate_failures do
        expect(agents.find("leah-researcher").ledger).to eq(%w[spec.md])
        expect(agents.find("luke-backend").ledger).to eq(%w[plan-backend.md pull-requests.md])
        expect(agents.find("rey-frontend").ledger).to eq(%w[plan-frontend.md pull-requests.md])
        expect(agents.find("hansolo-reviewer").ledger).to eq(%w[pull-requests.md])
        expect(agents.find("lando-broker").ledger).to eq(%w[plan.md])
      end
    end

    it "defaults rounds to one and caps them at five" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.md"), "---\nname: a\nhandles: [new]\nrounds: 9\n---\nbody")
        File.write(File.join(dir, "b.md"), "---\nname: b\nhandles: [new]\n---\nbody")
        roster = described_class.new(dir:)
        expect(roster.find("a").rounds).to eq(Agentilda::Agent::MAX_ROUNDS)
        expect(roster.find("b").rounds).to eq(1)
      end
    end

    it "reads the model and effort the definitions declare" do
      aggregate_failures do
        expect(agents.find("leah-researcher").model).to eq("haiku")
        expect(agents.find("leah-researcher").effort).to eq("xhigh")
        expect(agents.find("hansolo-reviewer").effort).to eq("high")
        expect(agents.find("lando-broker").effort).to be_nil
      end
    end

    it "reads the timeouts as settled" do
      expect(agents.all.to_h { |a| [a.name, a.timeout] }).to include(
        "yoda-writer"       => 300,
        "palpatine-planner" => 600,
        "luke-backend"      => 1200,
        "rey-frontend"      => 1200,
        "hansolo-reviewer"  => 300,
        "leah-researcher"   => 1200
      )
    end

    it "knows the state luke starts a plan into and the one it holds at while rey is still building" do
      luke = agents.find("luke-backend")
      expect([luke.starts_as, luke.holds_at]).to eq(%i[building building_ui])
      expect(agents.find("rey-frontend").starts_as).to be_nil
    end

    it "gives hansolo in_review as the state a review starts in" do
      expect(agents.find("hansolo-reviewer").starts_as).to eq(:in_review)
    end

    it "strips the name to the role for the screen" do
      expect(agents.find("palpatine-planner").role).to eq("planner")
    end
  end

  describe "the prompts" do
    let(:agents) { described_class.new }

    # A4: the harness renames. A prompt that still says `git mv` would race it.
    it "never tells an agent to rename its own folder" do
      agents.all.each do |agent|
        expect(agent.prompt).not_to include("git mv"), "#{agent.name} still renames its folder"
      end
    end

    it "tells luke and rey to sign pull-requests.md" do
      %w[luke-backend rey-frontend].each do |name|
        expect(agents.find(name).prompt).to include("pull-requests.md")
      end
    end

    it "tells hansolo the verdict words and the two-rejection rule" do
      prompt = agents.find("hansolo-reviewer").prompt
      expect(prompt).to include("(rejected 1/2)", "(rejected 2/2)", "(approved)", "(slop)", "👍🏼 to deploy")
    end

    it "tells yoda to leave a blank plan.md" do
      expect(agents.find("yoda-writer").prompt).to include("plan.md")
    end
  end
end
