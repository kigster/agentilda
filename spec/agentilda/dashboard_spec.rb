# frozen_string_literal: true

RSpec.describe Agentilda::Dashboard do
  let(:screen) { instance_double(Agentilda::Screen::Ratatui, attach_keyboard: nil, open: nil, close: nil, draw: nil) }
  let(:dashboard) { described_class.new(root: "/repo", screen:) }

  it "stands in for the dispatcher: kill and extend reach the row's executor handle" do
    tracker = dashboard.track(key: "001.00 → lando-broker", fields: { plan: "001.00", agent: "lando-broker" })
    allow(tracker.handle).to receive(:kill!)
    allow(tracker.handle).to receive(:extend!)

    dashboard.kill("001.00 → lando-broker")
    dashboard.extend("001.00 → lando-broker", 600)
    dashboard.kill("nobody")

    expect(tracker.handle).to have_received(:kill!)
    expect(tracker.handle).to have_received(:extend!).with(600)
  end

  it "builds a board from running rows and totals their tokens" do
    tracker = dashboard.track(key: "k", fields: { plan: "001.00", agent: "anakin-briefster" }, file: "spec.md")
    tracker.call(Agentilda::Transcript::Progress.new(activity: "writing spec.md", up: 1_000, down: 50, subagents: 1))

    board = dashboard.board

    expect(board.root).to eq("/repo")
    expect(board.plans).to eq(["001.00"])
    expect(board.running).to eq(1)
    expect([board.up, board.live_down]).to eq([1_000, 50])
    expect(board.rows.first).to have_attributes(agent: "anakin-briefster",
      file: "spec.md",
      message: "writing spec.md",
      subagents: 1,
      state: :running)
  end

  it "drops a finished row once it has lingered" do
    tracker = dashboard.track(key: "k", fields: { plan: "001.00" })
    tracker.done
    expect(dashboard.board.rows.size).to eq(1)

    allow(Agentilda::UI).to receive(:monotonic).and_return(Agentilda::UI.monotonic + described_class::LINGER + 1)
    expect(dashboard.board.rows).to be_empty
  end

  it "attaches a keyboard, paints, and closes the screen even when the block raises" do
    expect { described_class.open(root: "/repo", screen:) { raise "boom" } }.to raise_error("boom")

    expect(screen).to have_received(:attach_keyboard).with(an_instance_of(Agentilda::Keyboard))
    expect(screen).to have_received(:open)
    expect(screen).to have_received(:draw).at_least(:once)
    expect(screen).to have_received(:close)
  end
end
