# frozen_string_literal: true

RSpec.describe Agentilda::Console do
  subject(:console) { described_class.new(screen:) }

  let(:screen) { instance_double(Agentilda::Screen, draw: nil) }
  let(:dispatcher) { instance_double(Agentilda::Dispatcher, kill: nil, extend: nil) }
  let(:rows) do
    %w[001.00/leah-researcher 002.00/yoda-writer 003.00/palpatine-planner].each_with_index.map do |key, i|
      Agentilda::Board::Row.new(key:,
        at: Time.now,
        ordinal: key[0, 6],
        file: "spec.md",
        agent: key.split("/").last,
        role: "x",
        round: 1,
        rounds: 1,
        model: "opus",
        up: 0,
        down: 0,
        message: nil,
        state: i == 2 ? :done : :running)
    end
  end
  let(:board) do
    Agentilda::Board.new(started_at: 0.0,
      status: :running,
      plans: [],
      up: 0,
      down: 0,
      rows:,
      root: "/r",
      running: 2,
      live_up: 0,
      live_down: 0)
  end

  before do
    console.attach(dispatcher)
    console.paint(board)
  end

  it "s selects the first running row, then cycles, skipping finished rows" do
    console.select_next
    expect(console.selected).to eq("001.00/leah-researcher")
    console.select_next
    expect(console.selected).to eq("002.00/yoda-writer")
    console.select_next
    expect(console.selected).to eq("001.00/leah-researcher")
  end

  it "arrows move the selection both ways" do
    console.select_next
    console.select_prev
    expect(console.selected).to eq("002.00/yoda-writer")
  end

  it "k and x open the dialog with pending changes and touch nothing yet" do
    console.select_next
    console.toggle_kill
    console.extend
    console.extend
    aggregate_failures do
      expect(console).to be_dialog
      expect(console.pending).to eq(kill: true, extend: 1200)
      expect(dispatcher).not_to have_received(:kill)
      expect(dispatcher).not_to have_received(:extend)
    end
  end

  it "ENTER applies the pending changes to the selected agent and closes the dialog" do
    console.select_next
    console.toggle_kill
    console.extend
    console.apply
    aggregate_failures do
      expect(dispatcher).to have_received(:kill).with("001.00/leah-researcher")
      expect(dispatcher).to have_received(:extend).with("001.00/leah-researcher", 600)
      expect(console).not_to be_dialog
      expect(console.pending).to eq(kill: false, extend: 0)
    end
  end

  it "ESC discards the dialog, then clears the selection, then does nothing" do
    console.select_next
    console.toggle_kill
    console.escape
    expect(console).not_to be_dialog
    expect(console.pending).to eq(kill: false, extend: 0)
    expect(console.selected).to eq("001.00/leah-researcher")
    console.escape
    expect(console.selected).to be_nil
    expect { console.escape }.not_to raise_error
  end

  it "k without a selection selects the first running row first" do
    console.toggle_kill
    expect(console.selected).to eq("001.00/leah-researcher")
    expect(console).to be_dialog
  end

  it "paints the board with the selection, the dialog text and the help flag" do
    console.select_next
    console.toggle_kill
    console.toggle_help
    console.paint(board)
    expect(screen).to have_received(:draw).with(having_attributes(selected: "001.00/leah-researcher",
      dialog: a_string_including("kill: yes"),
      help: a_string_including("kill")))
  end

  it "paints the board with the about text once toggled, mentioning the version" do
    console.toggle_about
    console.paint(board)
    expect(screen).to have_received(:draw).with(having_attributes(about: a_string_including(Agentilda::VERSION)))
  end

  it "escape closes the about screen before clearing the selection" do
    console.select_next
    console.toggle_about
    console.escape
    expect(console).not_to be_about
    expect(console.selected).to eq("001.00/leah-researcher")
  end
end
