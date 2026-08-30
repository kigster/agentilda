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
end
