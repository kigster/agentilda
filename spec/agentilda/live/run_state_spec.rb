# frozen_string_literal: true

RSpec.describe Agentilda::Live::RunState do
  subject(:state) { described_class.new }

  it "holds and releases questions and cars, once each" do
    state.hold_question("001.00/B1")
    state.hold_question("001.00/B1")
    state.hold_car("001.00/luke-backend")
    state.hold_car("001.00/luke-backend", held: false)
    expect([state.question_held?("001.00/B1"), state.car_held?("001.00/luke-backend")]).to eq([true, false])
  end

  context "with a model chosen" do
    before { state.choose_model("001.00/luke-backend", "claude-haiku-5-5") }

    it "remembers it" do
      expect(state.model_for("001.00/luke-backend")).to eq("claude-haiku-5-5")
    end

    it "forgets it when told nil" do
      state.choose_model("001.00/luke-backend", nil)
      expect(state.model_for("001.00/luke-backend")).to be_nil
    end
  end
end
