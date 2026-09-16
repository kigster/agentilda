# frozen_string_literal: true

RSpec.describe Agentilda::Board::Row do
  describe ".remember" do
    it "puts a new status on top" do
      expect(described_class.remember(["reading spec.md"], "editing plan.md")).to eq(["editing plan.md", "reading spec.md"])
    end

    it "drops an empty status and one that repeats the newest" do
      expect(described_class.remember(["reading spec.md"], "reading spec.md")).to eq(["reading spec.md"])
      expect(described_class.remember(["reading spec.md"], "  ")).to eq(["reading spec.md"])
      expect(described_class.remember([], nil)).to eq([])
    end

    it "keeps at most HISTORY statuses" do
      history = (1..described_class::HISTORY).map(&:to_s)
      expect(described_class.remember(history, "new").size).to eq(described_class::HISTORY)
    end
  end
end
