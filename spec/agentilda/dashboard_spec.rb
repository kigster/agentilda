# frozen_string_literal: true

RSpec.describe Agentilda::Dashboard do
  subject(:dashboard) { described_class.new(root: "/repo", screen:) }

  let(:screen) { instance_double(Agentilda::Screen::Ratatui, attach_keyboard: nil, open: nil, close: nil, draw: nil) }

  # It stands in for the dispatcher behind the console, so k and x must
  # reach the agent through the row's executor handle.
  describe "#kill and #extend" do
    let!(:tracker) { dashboard.track(key: "001.00 → lando-broker", fields: { plan: "001.00", agent: "lando-broker" }) }

    before do
      allow(tracker.handle).to receive(:kill!)
      allow(tracker.handle).to receive(:extend!)
      dashboard.kill("001.00 → lando-broker")
      dashboard.extend("001.00 → lando-broker", 600)
      dashboard.kill("nobody")
    end

    it { expect(tracker.handle).to have_received(:kill!).once }
    it { expect(tracker.handle).to have_received(:extend!).with(600) }
  end

  describe "#board" do
    subject(:board) { dashboard.board }

    let(:progress) { Agentilda::Transcript::Progress.new(activity: "writing spec.md", up: 1_000, down: 50, subagents: 1) }
    let!(:tracker) { dashboard.track(key: "k", fields: { plan: "001.00", agent: "anakin-briefster" }, file: "spec.md") }

    before { tracker.call(progress) }

    it { is_expected.to have_attributes(root: "/repo", plans: ["001.00"], running: 1, up: 1_000, live_down: 50) }

    it "carries the agent's row" do
      expect(board.rows.first).to have_attributes(agent: "anakin-briefster",
        file: "spec.md",
        message: "writing spec.md",
        history: ["writing spec.md"],
        subagents: 1,
        state: :running)
    end
  end

  describe "a finished row" do
    subject(:rows) { dashboard.board.rows }

    let!(:tracker) { dashboard.track(key: "k", fields: { plan: "001.00" }) }

    before { tracker.done }

    it { is_expected.to contain_exactly(have_attributes(state: :done)) }

    context "when it has lingered" do
      before do
        allow(Agentilda::UI).to receive(:monotonic).and_return(Agentilda::UI.monotonic + described_class::LINGER + 1)
      end

      it { is_expected.to be_empty }
    end
  end

  describe ".open" do
    subject(:open) { -> { described_class.open(root: "/repo", screen:) { raise "boom" } } }

    it { expect(open).to raise_error("boom") }

    context "when the block raises" do
      before do
        open.call
      rescue RuntimeError
        nil
      end

      it { expect(screen).to have_received(:attach_keyboard).with(an_instance_of(Agentilda::Keyboard)) }
      it { expect(screen).to have_received(:open) }
      it { expect(screen).to have_received(:draw).at_least(:once) }
      it { expect(screen).to have_received(:close) }
    end
  end
end
