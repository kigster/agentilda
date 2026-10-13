# frozen_string_literal: true

RSpec.describe "The adapters' models" do
  describe Agentilda::Adapters::Claude do
    subject(:adapter) { described_class.new }

    it "offers its models most capable first, priced" do
      expect(adapter.models.map(&:wire).first(2)).to eq([
                                                          { id: "claude-fable-5-1", label: "Fable 5.1", rates: { in: 15, out: 75 } },
                                                          { id: "claude-opus-5-5", label: "Opus 5.5", rates: { in: 5, out: 25 } }
                                                        ])
    end

    it "resolves a full id, an alias, and no name to a model" do
      expect([adapter.model_entry("claude-haiku-5-5"), adapter.model_entry("opus"), adapter.model_entry(nil),
              adapter.model_entry("default"), adapter.model_entry("gpt-5")].map { it&.id })
        .to eq(["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5", nil])
    end

    it "sets its autocompact threshold for the child" do
      expect(adapter.environment).to eq("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" => "40")
    end

    it "prices tokens per million" do
      expect(adapter.model_entry("sonnet").cost(1_000_000, 100_000)).to eq(4.5)
    end
  end

  describe Agentilda::Adapters::Codex do
    subject(:adapter) { described_class.new }

    it "offers nothing it has no prices for, and adds nothing to the environment" do
      expect([adapter.models, adapter.model_entry("gpt-5"), adapter.environment]).to eq([[], nil, {}])
    end
  end
end
