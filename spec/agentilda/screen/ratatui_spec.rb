# frozen_string_literal: true

require "ratatui_ruby"
require "ratatui_ruby/test_helper"

# ratatui_ruby 1.5.0's MockFrame test double only captures plain
# `render_widget` calls (see test_helper/test_doubles.rb) — it has no
# `render_stateful_widget`, even though the real, native `Frame` does. A
# stateful `Table` (the one thing this screen needs a `TableState` for) has
# nowhere else to render in a view test, so the double is extended here,
# in the test only, to also capture stateful widgets the same way.
RatatuiRuby::TestHelper::TestDoubles::MockFrame.class_eval do
  def render_stateful_widget(widget, area, _state)
    render_widget(widget, area)
  end

  # Likewise, the real, native `Frame` has an `#area` (the gem's own doc
  # example instead passes an area alongside the frame — see the class
  # comment above — but `Screen::Ratatui#tick` reads it straight off the
  # frame `tui.draw` yields, exactly as the real terminal loop does), so
  # the double grows one too: a fixed `StubRect`, since nothing in these
  # specs asserts particular dimensions from it.
  def area
    RatatuiRuby::TestHelper::TestDoubles::StubRect.new
  end
end

RSpec.describe Agentilda::Screen::Ratatui do
  subject(:screen) { described_class.new }

  let(:tui) { RatatuiRuby::TUI.new }
  let(:frame) { RatatuiRuby::TestHelper::TestDoubles::MockFrame.new }
  let(:area) { RatatuiRuby::TestHelper::TestDoubles::StubRect.new(width: 140, height: 30) }
  # TableState.new's documented `selected = nil` default isn't honored by the
  # native binding — it raises ArgumentError given zero arguments — so the
  # nil has to be explicit.
  let(:table_state) { tui.table_state(nil) }

  let(:row) do
    Agentilda::Board::Row.new(key: "001.00/leah-researcher",
      at: Time.new(2026, 9, 4, 11, 29, 20),
      ordinal: "001.00",
      file: "spec.md",
      agent: "leah-researcher",
      role: "researcher",
      round: 1,
      rounds: 2,
      model: "haiku",
      remaining: 761,
      phase: :calm,
      up: 1_500_000,
      down: 11_000,
      message: "reading plan.md",
      state: :running,
      frame: 3,
      elapsed: 200,
      subagents: 2)
  end

  let(:board) do
    Agentilda::Board.new(started_at: 0.0,
      status: :running,
      plans: %w[001.00],
      up: 2_700_000,
      down: 22_000,
      rows: [row],
      root: "/repo/qualified-at",
      running: 1,
      live_up: 1_500_000,
      live_down: 11_000)
  end

  def widgets_of(klass)
    frame.rendered_widgets.map { |w| w[:widget] }.grep(klass)
  end

  it "renders exactly one table with the agent name bold yellow" do
    screen.render(tui, frame, area, board, table_state)

    table = widgets_of(RatatuiRuby::Widgets::Table).first
    expect(table).not_to be_nil
    agent_cell = table.rows.first.cells[3]
    expect(agent_cell.content).to eq("leah-researcher")
    expect(agent_cell.style.fg).to eq(:yellow)
    expect(agent_cell.style.modifiers).to include(:bold)
  end

  it "carries the sub-agent count and token totals in the row" do
    screen.render(tui, frame, area, board, table_state)

    cells = widgets_of(RatatuiRuby::Widgets::Table).first.rows.first.cells
    expect(cells[6]).to eq("2")
    # UI.abbreviate rounds the 10k-1M band to a bare integer (see
    # spec/agentilda/ui_spec.rb: 121_000 -> "121k"), so 11_000 comes back
    # "11k", not "11.0k".
    expect(cells[7]).to include("1.5M", "11k")
  end

  it "renders the elapsed and time-left bars with the spec's color rules" do
    screen.render(tui, frame, area, board, table_state)

    cells = widgets_of(RatatuiRuby::Widgets::Table).first.rows.first.cells
    elapsed_bar, elapsed_clock = cells[8].spans
    left_bar, left_clock = cells[9].spans
    expect(elapsed_bar.style.fg).to eq(:green) # 200s < 15min
    # Bar.cell formats the clock as " %2d:%02d" — a literal leading space
    # plus a space-padded 2-wide minutes field, so a single-digit minute
    # count (3, from 200s) prints with two leading spaces, not one (see
    # spec/agentilda/screen/ratatui/bar_spec.rb, which only exercises a
    # two-digit minute count and so never shows this).
    expect(elapsed_clock.content).to eq("  3:20")
    expect(left_bar.style.fg).to eq(:yellow) # 761s < 15min, >= 5min
    expect(left_clock.content).to eq(" 12:41")
  end

  it "syncs TableState selection from Board#selected by row key" do
    screen.render(tui, frame, area, board.with(selected: row.key), table_state)
    expect(table_state.selected).to eq(0)

    screen.render(tui, frame, area, board.with(selected: nil), table_state)
    expect(table_state.selected).to be_nil
  end

  it "renders the dialog, help, or about overlay as a centered block, exclusively" do
    screen.render(tui, frame, area, board.with(dialog: "kill: yes"), table_state)
    expect(widgets_of(RatatuiRuby::Widgets::Paragraph).map(&:text)).to include(a_string_including("kill: yes"))
  end

  it "renders the running-agent sparkline in the bottom strip" do
    screen.render(tui, frame, area, board, table_state)
    expect(widgets_of(RatatuiRuby::Widgets::Sparkline)).not_to be_empty
  end

  # The specs above assert on the pre-layout `Text::Line`/`Text::Span`
  # objects `Screen::Ratatui#render` builds — they can't see what ratatui's
  # own layout engine does to a column once it doesn't fit, which is
  # exactly the blind spot that let COLUMNS's elapsed/time-left widths ship
  # too narrow (see the comment on COLUMNS itself). This describe block
  # renders through a real (headless) terminal instead, so it can.
  describe "against a real terminal, not the pre-layout widget doubles above" do
    include RatatuiRuby::TestHelper

    it "does not truncate the elapsed/time-left clock text once ratatui lays the table out" do
      with_test_terminal(160, 10) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board, table_state) }

        text = buffer_content.join("\n")
        # Same fixture as "renders the elapsed and time-left bars…" above:
        # elapsed 200s -> "  3:20", remaining 761s -> " 12:41".
        expect(text).to include("3:20")
        expect(text).to include("12:41")
      end
    end
  end

  describe "the two-line agent layout, in a real terminal" do
    include RatatuiRuby::TestHelper

    let(:second) do
      row.with(key: "002.00/luke-backend",
        ordinal: "002.00",
        file: "plan-frontend.md",
        agent: "luke-backend",
        message: "writing lib/agentilda/screen/ratatui.rb and its spec")
    end

    it "puts the status bar on line 2, a blank line 3, and each agent on two lines plus a gap" do
      with_test_terminal(160, 14) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board.with(rows: [row, second]), table_state) }

        lines = buffer_content
        expect(lines[0].strip).to be_empty
        expect(lines[1]).to include("running", "plans: 001.00")
        expect(lines[2].strip).to be_empty
        expect(lines[3]).to include("time", "feature")
        expect(lines[4]).to include("001.00", "spec.md", "leah-researcher")
        expect(lines[4]).not_to include("reading plan.md")
        expect(lines[5].index("reading plan.md")).to eq(lines[4].index("spec.md"))
        expect(lines[6].strip).to be_empty
        expect(lines[7]).to include("002.00", "plan-frontend.md")
        expect(lines[8].index("writing lib/agentilda")).to eq(lines[7].index("plan-frontend.md"))
      end
    end
  end

  describe "--scroll-height, in a real terminal" do
    include RatatuiRuby::TestHelper

    subject(:screen) { described_class.new(scroll_height: 3) }

    it "shows the latest statuses under the row, newest first and bold, the rest plain" do
      talkative = row.with(history: ["writing plan.md", "reading spec.md", "listing .plans", "starting"])
      with_test_terminal(160, 14) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board.with(rows: [talkative]), table_state) }

        lines = buffer_content
        expect(lines[4]).to include("001.00", "leah-researcher")
        column = lines[4].index("spec.md")
        expect(lines[5..7].map { |l| l[column..].strip }).to eq(["writing plan.md", "reading spec.md", "listing .plans"])
        expect(lines[8].strip).to be_empty
        expect(buffer_content.join).not_to include("starting")

        expect(get_cell(column, 5).modifiers).to include(:bold)
        expect(get_cell(column, 6).modifiers).not_to include(:bold)
        expect([get_cell(column, 5).fg, get_cell(column, 6).fg]).to all(eq(:yellow))
      end
    end

    it "falls back to the message when a row has no history yet" do
      with_test_terminal(160, 10) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board, table_state) }
        expect(buffer_content[5]).to include("reading plan.md")
      end
    end
  end

  describe "lifecycle" do
    let(:keyboard) { instance_double(Agentilda::Keyboard, handle: nil) }

    before { screen.attach_keyboard(keyboard) }

    describe "#tick" do
      it "does nothing when no board has been drawn yet" do
        allow(tui).to receive(:poll_event)
        screen.tick(tui, table_state)
        expect(tui).not_to have_received(:poll_event)
      end

      it "draws the latest board and forwards the translated key to the keyboard" do
        screen.draw(board)
        allow(tui).to receive(:draw).and_yield(frame)
        allow(tui).to receive(:poll_event).and_return(RatatuiRuby::Event::Key.new(code: "k"))

        screen.tick(tui, table_state)

        expect(tui).to have_received(:draw)
        expect(keyboard).to have_received(:handle).with("k")
      end

      it "ignores a non-key event without calling the keyboard" do
        screen.draw(board)
        allow(tui).to receive(:draw).and_yield(frame)
        allow(tui).to receive(:poll_event).and_return(RatatuiRuby::Event::None.new)

        screen.tick(tui, table_state)

        expect(keyboard).not_to have_received(:handle)
      end

      it "samples the running-agent count once every 10 seconds, not every tick" do
        allow(tui).to receive(:draw)
        allow(tui).to receive(:poll_event).and_return(RatatuiRuby::Event::None.new)
        allow(Agentilda::UI).to receive(:monotonic).and_return(0.0, 1.0, 11.0)

        screen.draw(board.with(running: 3))
        screen.tick(tui, table_state) # t=0: first sample always taken
        screen.draw(board.with(running: 5))
        screen.tick(tui, table_state) # t=1: too soon, no sample
        screen.draw(board.with(running: 7))
        screen.tick(tui, table_state) # t=11: 10s elapsed, sample taken

        expect(screen.history).to eq([3, 7])
      end
    end

    describe "#open and #close" do
      it "runs the loop on its own thread via the injected runner, until closed" do
        ticked = Queue.new
        fake_tui = Object.new
        # run_loop calls `tui.table_state(nil)` unconditionally before
        # entering the tick loop; #tick itself is stubbed below, so the
        # returned value is never used, but the call itself must not raise.
        def fake_tui.table_state(*) = nil
        runner = ->(&block) { block.call(fake_tui) }
        screen = described_class.new(runner:)
        screen.attach_keyboard(keyboard)
        allow(screen).to receive(:tick) { ticked << true }

        screen.open
        sleep 0.05 until ticked.size >= 2
        screen.close

        expect(ticked.size).to be >= 2
      end

      it "surfaces a runner failure through UI.line instead of re-raising it from #close" do
        runner = ->(&) { raise RatatuiRuby::Error, "terminal init failed" }
        screen = described_class.new(runner:)
        screen.attach_keyboard(keyboard)
        allow(Agentilda::UI).to receive(:line)

        screen.open
        expect { screen.close }.not_to raise_error

        expect(Agentilda::UI).to have_received(:line).with(a_string_including("terminal init failed"))
      end
    end
  end
end
