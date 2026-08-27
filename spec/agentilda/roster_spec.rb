# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# `agentilda agents`. Everything here is read from the definition files,
# so the examples write real ones rather than stubbing the loader: a summary of
# an agent that Ruby maintains separately is the drift this command exists to
# prevent.
RSpec.describe Agentilda::Roster do
  subject(:roster) { described_class.new(agents: Agentilda::Agents.new(dir: dir)) }

  let(:dir) { @dir }

  around do |example|
    Dir.mktmpdir("agents") do |tmp|
      @dir = tmp
      write(tmp, "luke-backend", <<~MD)
        ---
        name: luke-backend
        description: Builds one work unit from a plan.
        handles: [building, rejected]
        advances_to: ready_for_review
        model: sonnet
        allowed_tools: [Read, Write]
        ---
        You are implementing one work unit.
      MD
      write(tmp, "hansolo-reviewer", <<~MD)
        ---
        name: hansolo-reviewer
        description: Reads the diff against the plan.
        handles: [ready_for_review]
        model: sonnet
        ---
        You are reviewing.
      MD
      example.run
    end
  end

  def write(dir, name, body) = File.write(File.join(dir, "#{name}.md"), body)

  def plain(text) = text.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")

  describe "#list" do
    let(:table) { plain(roster.list) }

    it "names every agent, in name order" do
      expect(table.scan(/^\s+(\S+-\S+)\s/).flatten).to eq(%w[hansolo-reviewer luke-backend])
    end

    # The states are written the way the folder names write them, so what an
    # agent handles reads the same here as it does in `status` and on disk.
    it "writes each state as its emoji and its words" do
      expect(table).to include("🟡 Building", "🟢 Ready for Review")
    end

    # An agent with no advances_to is never offered work by the loop. Printing
    # a blank there would read as "advances to nothing in particular".
    it "says read-only rather than leaving the destination blank" do
      expect(table).to match(/hansolo-reviewer.*read-only/)
    end

    it "says so plainly when there are no definitions to list" do
      Dir.mktmpdir("empty") do |empty|
        expect(described_class.new(agents: Agentilda::Agents.new(dir: empty)).list).to include("No agent definitions")
      end
    end
  end
end
