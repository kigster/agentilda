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
end
