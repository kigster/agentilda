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

  describe "#render, against the pre-layout widget doubles" do
    before { screen.render(tui, frame, area, board, table_state) }

    let(:table) { widgets_of(RatatuiRuby::Widgets::Table).first }
    let(:cells) { table.rows.first.cells }

    it("renders exactly one table") { expect(table).not_to be_nil }

    describe "the agent name cell" do
      subject(:agent_cell) { cells[3] }

      it("holds the agent name") { expect(agent_cell.content).to eq("leah-researcher") }
      it("is yellow") { expect(agent_cell.style.fg).to eq(:yellow) }
      it("is bold") { expect(agent_cell.style.modifiers).to include(:bold) }
    end

    it "carries the sub-agent count in the row" do
      expect(cells[6]).to eq("2")
    end

    # UI.abbreviate rounds the 10k-1M band to a bare integer (see
    # spec/agentilda/ui_spec.rb: 121_000 -> "121k"), so 11_000 comes back
    # "11k", not "11.0k".
    it "carries the token totals in the row" do
      expect(cells[7]).to include("1.5M", "11k")
    end

    describe "the elapsed and time-left bars, with the spec's color rules" do
      let(:elapsed_bar) { cells[8].spans.first }
      let(:elapsed_clock) { cells[8].spans.last }
      let(:left_bar) { cells[9].spans.first }
      let(:left_clock) { cells[9].spans.last }

      it("colors elapsed green under 15min (200s)") { expect(elapsed_bar.style.fg).to eq(:green) }

      # Bar.cell formats the clock as " %2d:%02d" — a literal leading space
      # plus a space-padded 2-wide minutes field, so a single-digit minute
      # count (3, from 200s) prints with two leading spaces, not one (see
      # spec/agentilda/screen/ratatui/bar_spec.rb, which only exercises a
      # two-digit minute count and so never shows this).
      it("prints the elapsed clock") { expect(elapsed_clock.content).to eq("  3:20") }
      it("colors time-left yellow under 15min, at or over 5min (761s)") { expect(left_bar.style.fg).to eq(:yellow) }
      it("prints the time-left clock") { expect(left_clock.content).to eq(" 12:41") }
    end

    # TableState selection syncs from Board#selected by row key.
    context "when a row is selected" do
      let(:board) { super().with(selected: row.key) }

      it("selects its index in TableState") { expect(table_state.selected).to eq(0) }
    end

    context "when a selected row is then cleared" do
      let(:board) { super().with(selected: row.key) }

      before { screen.render(tui, frame, area, board.with(selected: nil), table_state) }

      it("clears the TableState selection") { expect(table_state.selected).to be_nil }
    end

    context "with a dialog, help, or about overlay" do
      let(:board) { super().with(dialog: "kill: yes") }

      it "renders it as a centered block, exclusively" do
        expect(widgets_of(RatatuiRuby::Widgets::Paragraph).map(&:text)).to include(a_string_including("kill: yes"))
      end
    end

    it "renders the running-agent sparkline in the bottom strip" do
      expect(widgets_of(RatatuiRuby::Widgets::Sparkline)).not_to be_empty
    end
  end

  # The specs above assert on the pre-layout `Text::Line`/`Text::Span`
  # objects `Screen::Ratatui#render` builds — they can't see what ratatui's
  # own layout engine does to a column once it doesn't fit, which is
  # exactly the blind spot that let COLUMNS's elapsed/time-left widths ship
  # too narrow (see the comment on COLUMNS itself). This describe block
  # renders through a real (headless) terminal instead, so it can.
  describe "against a real terminal, not the pre-layout widget doubles above" do
    include RatatuiRuby::TestHelper

    # with_test_terminal returns its block's value, so the buffer is captured
    # while the headless terminal is still alive and asserted on afterwards.
    subject(:text) do
      with_test_terminal(160, 10) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board, table_state) }
        buffer_content.join("\n")
      end
    end

    # Same fixture as "the elapsed and time-left bars…" above:
    # elapsed 200s -> "  3:20", remaining 761s -> " 12:41".
    it("does not truncate the elapsed clock text") { is_expected.to include("3:20") }
    it("does not truncate the time-left clock text") { is_expected.to include("12:41") }
  end

  describe "the two-line agent layout, in a real terminal" do
    include RatatuiRuby::TestHelper

    # One status line per agent, so the line numbers below stay the
    # arithmetic this block is about rather than the default's.
    subject(:screen) { described_class.new(scroll_height: 1) }

    let(:lines) do
      with_test_terminal(160, 14) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board.with(rows: [row, second]), table_state) }
        buffer_content
      end
    end

    let(:second) do
      row.with(key: "002.00/luke-backend",
        ordinal: "002.00",
        file: "plan-frontend.md",
        agent: "luke-backend",
        message: "writing lib/agentilda/screen/ratatui.rb and its spec")
    end

    it("leaves line 1 blank") { expect(lines[0].strip).to be_empty }
    it("puts the status bar on line 2") { expect(lines[1]).to include("running", "plans: 001.00") }
    it("leaves line 3 blank") { expect(lines[2].strip).to be_empty }
    it("puts the header on line 4") { expect(lines[3]).to include("time", "feature") }

    describe "the first agent" do
      it("fills its first line") { expect(lines[4]).to include("001.00", "spec.md", "leah-researcher") }
      it("keeps the message off its first line") { expect(lines[4]).not_to include("reading plan.md") }

      it "aligns the message on its second line under the file" do
        expect(lines[5].index("reading plan.md")).to eq(lines[4].index("spec.md"))
      end

      it("is followed by a gap") { expect(lines[6].strip).to be_empty }
    end

    describe "the second agent" do
      it("fills its first line") { expect(lines[7]).to include("002.00", "plan-frontend.md") }

      it "aligns the message on its second line under the file" do
        expect(lines[8].index("writing lib/agentilda")).to eq(lines[7].index("plan-frontend.md"))
      end
    end
  end

  # The bars frame the whole screen, so a strip that stops short of the
  # edge — as the bottom one did while the sparkline's own area was left
  # unpainted — reads as a drawing fault rather than a layout choice.
  describe "the status bars, in a real terminal" do
    include RatatuiRuby::TestHelper

    subject(:bars) do
      with_test_terminal(width, height) do
        tui.draw { |frame| screen.render(tui, frame, frame.area, board, table_state) }
        { top: cells_of(1), bottom: cells_of(height - 1) }
      end
    end

    let(:width) { 160 }
    let(:height) { 12 }

    def cells_of(row) = (0...width).map { |x| get_cell(x, row) }

    it("paints the top bar cyan, edge to edge") { expect(bars[:top].map(&:bg).uniq).to eq([:cyan]) }
    it("writes the top bar in black") { expect(bars[:top].first.fg).to eq(:black) }
    it("paints the bottom bar cyan, edge to edge") { expect(bars[:bottom].map(&:bg).uniq).to eq([:cyan]) }
    it("writes the bottom bar in black") { expect(bars[:bottom].first.fg).to eq(:black) }
  end

  describe "--scroll-height, in a real terminal" do
    include RatatuiRuby::TestHelper

    subject(:screen) { described_class.new(scroll_height: 3) }

    it("is what a screen built with no argument already draws") { expect(described_class.new.scroll_height).to eq(3) }

    context "when a row has a history" do
      let(:talkative) { row.with(history: ["writing plan.md", "reading spec.md", "listing .plans", "starting"]) }

      # Cells are only readable while the headless terminal is alive, so
      # the two status rows are captured in full alongside the text.
      let(:rendered) do
        with_test_terminal(160, 14) do
          tui.draw { |frame| screen.render(tui, frame, frame.area, board.with(rows: [talkative]), table_state) }
          { lines: buffer_content, cells: [5, 6].to_h { |y| [y, (0...160).map { |x| get_cell(x, y) }] } }
        end
      end
      let(:lines) { rendered[:lines] }
      let(:column) { lines[4].index("spec.md") }
      let(:newest) { rendered[:cells][5][column] }
      let(:older) { rendered[:cells][6][column] }

      it("keeps the row itself in place") { expect(lines[4]).to include("001.00", "leah-researcher") }

      it "shows the latest statuses under the row, newest first" do
        expect(lines[5..7].map { |l| l[column..].strip }).to eq(["writing plan.md", "reading spec.md", "listing .plans"])
      end

      it("stops after scroll_height lines") { expect(lines[8].strip).to be_empty }
      it("drops the oldest status") { expect(lines.join).not_to include("starting") }
      it("draws the newest status bold") { expect(newest.modifiers).to include(:bold) }
      it("draws the rest plain") { expect(older.modifiers).not_to include(:bold) }
      it("draws them all yellow") { expect([newest.fg, older.fg]).to all(eq(:yellow)) }
    end

    # The status gets the whole width but for a margin at the right edge.
    context "when a status is longer than the terminal" do
      let(:width) { 160 }
      let(:long) { row.with(history: ["reading #{"x" * 300}"]) }
      let(:status_line) do
        with_test_terminal(width, 10) do
          tui.draw { |frame| screen.render(tui, frame, frame.area, board.with(rows: [long]), table_state) }
          buffer_content[5]
        end
      end

      it("ends it with an ellipsis") { expect(status_line.rstrip).to end_with("…") }

      it "stops 5 cells before the right edge" do
        expect(status_line.rstrip.length).to eq(width - described_class::ACTIVITY_MARGIN)
      end
    end

    context "when a row has no history yet" do
      subject(:lines) do
        with_test_terminal(160, 10) do
          tui.draw { |frame| screen.render(tui, frame, frame.area, board, table_state) }
          buffer_content
        end
      end

      it("falls back to the message") { expect(lines[5]).to include("reading plan.md") }
    end
  end

  describe "#tick" do
    let(:keyboard) { instance_double(Agentilda::Keyboard, handle: nil) }

    before { screen.attach_keyboard(keyboard) }

    context "when no board has been drawn yet" do
      before do
        allow(tui).to receive(:poll_event)
        screen.tick(tui, table_state)
      end

      it("does nothing") { expect(tui).not_to have_received(:poll_event) }
    end

    context "when a board has been drawn" do
      before do
        screen.draw(board)
        allow(tui).to receive(:draw).and_yield(frame)
        allow(tui).to receive(:poll_event).and_return(event)
        screen.tick(tui, table_state)
      end

      context "with a key event" do
        let(:event) { RatatuiRuby::Event::Key.new(code: "k") }

        it("draws the latest board") { expect(tui).to have_received(:draw) }
        it("forwards the translated key to the keyboard") { expect(keyboard).to have_received(:handle).with("k") }
      end

      context "with a non-key event" do
        let(:event) { RatatuiRuby::Event::None.new }

        it("does not call the keyboard") { expect(keyboard).not_to have_received(:handle) }
      end
    end

    context "when sampling the running-agent count" do
      before do
        allow(tui).to receive(:draw)
        allow(tui).to receive(:poll_event).and_return(RatatuiRuby::Event::None.new)
        allow(Agentilda::UI).to receive(:monotonic).and_return(0.0, 1.0, 11.0)

        screen.draw(board.with(running: 3))
        screen.tick(tui, table_state) # t=0: first sample always taken
        screen.draw(board.with(running: 5))
        screen.tick(tui, table_state) # t=1: too soon, no sample
        screen.draw(board.with(running: 7))
        screen.tick(tui, table_state) # t=11: 10s elapsed, sample taken
      end

      it "samples once every 10 seconds, not every tick" do
        expect(screen.history).to eq([3, 7])
      end
    end
  end

  describe "#open and #close" do
    let(:keyboard) { instance_double(Agentilda::Keyboard, handle: nil) }
    # A screen of its own rather than the subject, since these examples
    # inject a runner and stub #tick on it.
    let(:threaded) { described_class.new(runner:) }

    before { threaded.attach_keyboard(keyboard) }

    context "with a runner that loops" do
      let(:ticked) { Queue.new }
      # run_loop calls `tui.table_state(nil)` unconditionally before
      # entering the tick loop; #tick itself is stubbed below, so the
      # returned value is never used, but the call itself must not raise.
      let(:fake_tui) { instance_double(RatatuiRuby::TUI, table_state: nil) }
      let(:runner) { ->(&block) { block.call(fake_tui) } }

      before do
        # Memoized up front, on this thread: the runner reads them from its own.
        fake_tui
        ticked
        allow(threaded).to receive(:tick) { ticked << true }

        threaded.open
        sleep 0.05 until ticked.size >= 2
        threaded.close
      end

      it "runs the loop on its own thread via the injected runner, until closed" do
        expect(ticked.size).to be >= 2
      end
    end

    context "with a runner that fails" do
      let(:runner) { ->(&) { raise RatatuiRuby::Error, "terminal init failed" } }

      before do
        allow(Agentilda::UI).to receive(:line)
        threaded.open
      end

      it("does not re-raise it from #close") { expect { threaded.close }.not_to raise_error }

      context "when closed" do
        before { threaded.close }

        it "surfaces the failure through UI.line" do
          expect(Agentilda::UI).to have_received(:line).with(a_string_including("terminal init failed"))
        end
      end
    end
  end
end
