# frozen_string_literal: true

RSpec.describe Agentilda::Screen do
  subject(:screen) { described_class.new(output:, width: -> { 120 }, height: -> { 30 }) }

  let(:output) { CapturedStream.new }
  let(:row) do
    Agentilda::Board::Row.new(key: "001.00/leah-researcher", at: Time.new(2026, 9, 4, 11, 29, 20),
      ordinal: "001.00", file: "spec.md", agent: "leah-researcher", role: "researcher", round: 1, rounds: 2,
      model: "haiku", remaining: 761, phase: :calm, up: 1_500_000, down: 11_000,
      message: "reading plan.md", state: :running, frame: 3)
  end
  let(:board) do
    Agentilda::Board.new(started_at: 0.0, status: :running, plans: %w[001.00], up: 2_700_000, down: 22_000,
      rows: [row], root: "/repo/qualified-at", running: 1, live_up: 1_500_000, live_down: 11_000)
  end

  def frame = strip_ansi(screen.render(board))

  it "draws the top bar, a blank line, the header, a rule, the rows, a rule, a blank line and the bottom bar" do
    lines = frame.lines.map(&:chomp)
    aggregate_failures do
      expect(lines[0]).to include("plans in work: 001.00", "tokens: ↑ 2.7M", "↓ 22k")
      expect(lines[1]).to eq("")
      expect(lines[2]).to include("timestamp", "plan", "file", "agent", "model")
      expect(lines[3]).to start_with(" " + "─" * 118)
      expect(lines[4]).to include("11:29:20", "001.00", "spec.md", "researcher [R:1/2]", "haiku", "12:41", "↑1.5M", "↓11k", "reading plan.md")
      expect(lines[5]).to start_with(" " + "─" * 118)
      expect(lines[6]).to eq("")
      expect(lines[7]).to include("working in /repo/qualified-at", "agents running: 1", "↑ 1.5M", "↓ 11k")
    end
  end

  it "keeps every line inside the terminal width" do
    expect(frame.lines.map { |l| Agentilda::UI.display_width(l.chomp) }.max).to be <= 120
  end

  it "paints files by name and the status on yellow, when colour is on" do
    allow(Agentilda::UI).to receive(:color?).and_return(true)
    text = screen.render(board)
    pastel = Pastel.new(enabled: true)
    aggregate_failures do
      expect(text).to include(pastel.green("spec.md".ljust(described_class::COLUMNS[:file])))
      expect(text).to include(pastel.decorate("reading plan.md".ljust(described_class.status_width(120)), :white, :bold, :on_yellow))
    end
  end

  it "shows a pull request number as a link, red when the plan was rejected" do
    allow(Agentilda::UI).to receive(:color?).and_return(true)
    judged = board.with(rows: [row.with(file: "pull-requests.md", pr: {number: "43", url: "https://github.com/x/y/pull/43", rejected: true})])
    text = screen.render(judged)
    aggregate_failures do
      expect(text).to include("\e]8;;https://github.com/x/y/pull/43\e\\")
      expect(text).to include(Pastel.new(enabled: true).red("#43"))
    end
  end

  it "turns the countdown amber once warned and red once wrapping up, and reads [wrapping] after STOP" do
    allow(Agentilda::UI).to receive(:color?).and_return(true)
    pastel = Pastel.new(enabled: true)
    aggregate_failures do
      expect(screen.render(board.with(rows: [row.with(phase: :warned)]))).to include(pastel.yellow("12:41 "))
      expect(screen.render(board.with(rows: [row.with(phase: :wrap_up, remaining: 59)]))).to include(pastel.red(" 0:59 "))
      expect(strip_ansi(screen.render(board.with(rows: [row.with(phase: :stopped, remaining: 0)])))).to include("[wrapping]")
    end
  end

  it "marks a finished row with a tick and a failed one with a cross" do
    done = strip_ansi(screen.render(board.with(rows: [row.with(state: :done, message: "done")])))
    failed = strip_ansi(screen.render(board.with(rows: [row.with(state: :failed, message: "claude exited 1")])))
    expect(done).to include("✓")
    expect(failed).to include("✖", "claude exited 1")
  end

  it "says how many rows are hidden when there are more than fit" do
    many = board.with(rows: Array.new(40) { |i| row.with(key: i.to_s, ordinal: format("%03d.00", i)) })
    text = strip_ansi(screen.render(many))
    expect(text).to match(/\+\d+ more/)
    expect(text.lines.size).to be <= 30
  end

  it "inverts the selected row" do
    allow(Agentilda::UI).to receive(:color?).and_return(true)
    text = screen.render(board.with(selected: row.key))
    expect(text).to include("\e[7m")
  end

  it "draws the dialog and the help over the table when asked" do
    text = strip_ansi(screen.render(board.with(dialog: "kill: yes\nextend: +10m", help: false)))
    expect(text).to include("kill: yes", "extend: +10m", "ENTER", "ESC")
  end

  describe ".hyperlink" do
    it "wraps text in an OSC 8 link" do
      expect(described_class.hyperlink("#7", "https://example.com/pull/7")).to eq("\e]8;;https://example.com/pull/7\e\\#7\e]8;;\e\\")
    end
  end
end
