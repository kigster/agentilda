# frozen_string_literal: true

RSpec.describe Agentilda::Live::Meter do
  subject(:meter) { described_class.new }

  let(:price) { ->(model) { Agentilda::Adapters.for("claude").model_entry(model) } }

  def row(round:, up:, down:, agent: "luke-backend", model: "opus")
    Agentilda::Engine::Board::Row.new(key: "001.00/#{agent}",
      at: Time.now,
      ordinal: "001.00",
      file: "plan.md",
      agent:,
      role: "backend",
      round:,
      rounds: 2,
      model:,
      up:,
      down:,
      state: :running)
  end

  it "keeps the highest reading of each round, and adds rounds and agents together" do
    meter.record([row(round: 1, up: 100, down: 10)], now: Time.utc(2026, 1, 1))
    meter.record([row(round: 1, up: 50, down: 5), row(round: 2, up: 1_000_000, down: 0, model: "haiku")])
    aggregate_failures do
      expect(meter.for("001.00", price)).to eq(up: 1_000_100, down: 10, cost: 1.0008)
      expect(meter.started_at("001.00")).to eq(Time.utc(2026, 1, 1))
      expect(meter.for("002.00", price)).to eq(up: 0, down: 0, cost: 0)
    end
  end
end
