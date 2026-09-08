# frozen_string_literal: true

# A weakly judged pull request is filed beside its nearest plan in time, and
# "nearest in time" is what this works out.
RSpec.describe Agentilda::Timeline, :tree do
  subject(:timeline) { described_class.new(tree: Agentilda::Tree.new(dir: plans_root), pulls:) }

  let!(:tree) do
    plans do |t|
      t.plan "001.00", :approved, "first", prs: [t.merged(1, "[001.00] a")]
      t.plan "002.00", :approved, "second", prs: [t.merged(2, "[002.00] b")]
      t.plan "003.00", :new, "third", files: {"spec.md" => spec_body}
    end
  end

  def pull(number, title, merged_at: nil, created_at: nil)
    {number:, title:, merged_at:, created_at:}
  end

  let(:pulls) do
    [pull(1, "[001.00] a", merged_at: Time.utc(2026, 1, 10)),
      pull(3, "[001.00] c", merged_at: Time.utc(2026, 1, 20)),
      pull(2, "[002.00] b", merged_at: Time.utc(2026, 2, 5)),
      pull(4, "[002.00] d", created_at: Time.utc(2026, 2, 20)),
      pull(5, "[099.00] not a plan", merged_at: Time.utc(2026, 3, 1)),
      pull(6, "no prefix", merged_at: Time.utc(2026, 3, 1))]
  end

  describe "#spans" do
    it "runs from a plan's first merge to its last, open pull requests by creation" do
      expect(timeline.spans.map { |s| [s.ordinal.to_s, s.from, s.to] }).to eq([
        ["001.00", Time.utc(2026, 1, 10), Time.utc(2026, 1, 20)],
        ["002.00", Time.utc(2026, 2, 5), Time.utc(2026, 2, 20)]
      ])
    end

    it "ignores prefixes that name no plan in the tree, and titles with none" do
      expect(timeline.spans.map { |s| s.ordinal.to_s }).not_to include("099.00")
    end
  end

  describe "#place" do
    it "lands inside the span that covers it" do
      expect(timeline.place(pull(9, "x", merged_at: Time.utc(2026, 1, 15)))).to eq(1)
    end

    it "lands after the last span that ended before it" do
      expect(timeline.place(pull(9, "x", merged_at: Time.utc(2026, 1, 25)))).to eq(1)
      expect(timeline.place(pull(9, "x", merged_at: Time.utc(2026, 6, 1)))).to eq(2)
    end

    it "lands beside the first plan when it predates the whole sequence" do
      expect(timeline.place(pull(9, "x", merged_at: Time.utc(2025, 1, 1)))).to eq(1)
    end

    it "picks the span whose end is nearest when several overlap" do
      overlapping = described_class.new(tree: Agentilda::Tree.new(dir: plans_root), pulls: [
        pull(1, "[001.00] a", merged_at: Time.utc(2026, 1, 1)), pull(3, "[001.00] c", merged_at: Time.utc(2026, 3, 1)),
        pull(2, "[002.00] b", merged_at: Time.utc(2026, 1, 15)), pull(4, "[002.00] d", merged_at: Time.utc(2026, 2, 1))
      ])

      expect(overlapping.place(pull(9, "x", merged_at: Time.utc(2026, 1, 25)))).to eq(2)
    end

    it "says nothing about an undated pull request" do
      expect(timeline.place(pull(9, "x"))).to be_nil
    end

    it "says nothing when no plan is dated" do
      empty = described_class.new(tree: Agentilda::Tree.new(dir: plans_root), pulls: [])

      expect(empty.place(pull(9, "x", merged_at: Time.utc(2026, 1, 1)))).to be_nil
    end
  end
end
