# frozen_string_literal: true

require "ratatui_ruby"

module Agentilda
  module Screen
    # A ratatui_ruby-backed alternative to {Screen}, selected with `--tui
    # ratatui`. Unlike {Screen}, whose #draw renders synchronously from the
    # dispatcher's own tick, ratatui_ruby owns a blocking render+input loop
    # of its own — see the lifecycle methods added in the next task. This
    # class carries the parts of that loop with no terminal dependency: the
    # widget tree built from a {Board}.
    class Ratatui
      # Cells each column takes. The last one is stretched to the edge by
      # ratatui's legacy flex. The elapsed/time-left columns (indices 8 and 9) are 17,
      # not 13: {Bar.cell} emits a 10-cell bar plus a clock suffix up to 7
      # characters wide (e.g. " 12:41"), and a narrower column clips the
      # clock digits once ratatui actually lays the table out (see
      # spec/agentilda/screen/ratatui_spec.rb's real-terminal regression
      # test, which is the only one of this file's specs that can see
      # that — the rest inspect the pre-layout `Text::Line` object).
      COLUMNS = [9, 7, 16, 18, 8, 8, 5, 13, 17, 17].freeze

      HEADER = %w[time plan feature agent round model subs tokens elapsed left].freeze

      # Blank lines between two agents.
      ROW_GAP = 1

      # The highlight symbol's column. Reserved even with nothing selected,
      # so the activity line's x never shifts when a selection appears.
      HIGHLIGHT_SYMBOL = "> "

      # The activity line starts under the feature column: past the
      # highlight symbol, time and plan, each column plus its 1-cell gap.
      ACTIVITY_INDENT = HIGHLIGHT_SYMBOL.length + COLUMNS[0] + 1 + COLUMNS[1] + 1

      # Cells a status line stops short of the terminal's right edge.
      ACTIVITY_MARGIN = 5

      # Seconds between samples for the running-agent-count sparkline.
      SAMPLE_INTERVAL = 10

      # Points the sparkline keeps before the oldest scrolls off the left.
      HISTORY = 60

      # @return [Array<Integer>] running-agent-count samples, oldest first
      attr_reader :history

      # @return [Integer] status lines drawn under each agent's row
      attr_reader :scroll_height

      # @param runner [#call] `RatatuiRuby.method(:run)` by default; a fake
      #   in tests, so this class never needs a real terminal to exercise
      #   its own orchestration
      # @param scroll_height [Integer] how many of an agent's latest statuses
      #   show under its row, newest at the top
      def initialize(runner: RatatuiRuby.method(:run), scroll_height: 1)
        @runner = runner
        @scroll_height = Integer(scroll_height).clamp(1, Board::Row::HISTORY)
        @board = nil
        @keyboard = nil
        @history = []
        @last_sample = nil
        # Read from the dispatcher's thread in #tick's `until @closing` via
        # #run_loop, written from the caller's thread in #close. Safe only
        # under MRI/CRuby's GVL, which serializes the read and the write;
        # a GVL-free Ruby would need a real memory barrier here.
        @closing = false
        @error = nil
        @mutex = Mutex.new
      end

      # @param keyboard [Agentilda::Keyboard] built with `.new`, never
      #   `.start`'d — this is what feeds it keys, from the thread
      #   ratatui_ruby's own loop runs on.
      # @return [void]
      def attach_keyboard(keyboard) = @keyboard = keyboard

      # @return [void]
      def open
        @closing = false
        @error = nil
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            @runner.call { |tui| run_loop(tui) }
          rescue StandardError => e
            # A background render thread's job is never to crash the run:
            # #close's `@thread&.join` would otherwise re-raise this inside
            # `run.rb`'s `ensure`, after every agent has already run,
            # discarding the whole run report. Stash it; #close surfaces it
            # with a one-line warning instead.
            @error = e
          end
        end
      end

      # Called by {Console#paint} from the dispatcher's own thread, exactly
      # as {Screen#draw} is. Stores the board; the ratatui thread picks it
      # up on its own next tick, a fraction of a frame later.
      #
      # @param board [Agentilda::Board]
      # @return [void]
      def draw(board) = @mutex.synchronize { @board = board }

      # @return [void]
      def close
        @closing = true
        @thread&.join
        @thread = nil
        UI.line("ratatui backend failed: #{@error.message} (the run itself continued; nothing was drawn)") if @error
      end

      # @param tui [RatatuiRuby::TUI]
      # @return [void]
      def run_loop(tui)
        # `TableState.new`'s documented `selected = nil` default isn't
        # honored by the native binding — it raises ArgumentError given
        # zero arguments (see spec/agentilda/screen/ratatui_spec.rb's own
        # `table_state` let) — so the nil has to be explicit.
        table_state = tui.table_state(nil)
        tick(tui, table_state) until @closing
      end

      # One frame: draw the latest board, sample the sparkline, forward the
      # next key. Public so the lifecycle spec can drive it without needing
      # to manage the `until @closing` loop.
      #
      # @param tui [RatatuiRuby::TUI]
      # @param table_state [RatatuiRuby::TableState]
      # @return [void]
      def tick(tui, table_state)
        board = @mutex.synchronize { @board }
        unless board
          # `tui.poll_event` below is what paces this loop (ratatui's
          # default poll timeout is ~16ms); returning ahead of it, as here,
          # would otherwise spin a CPU core flat out until the dispatcher's
          # first paint.
          sleep(0.05)
          return
        end

        sample(board)
        tui.draw { |frame| render(tui, frame, frame.area, board, table_state) }
        forward(tui.poll_event)
      end

      # @param tui [RatatuiRuby::TUI]
      # @param frame [RatatuiRuby::Frame]
      # @param area [RatatuiRuby::Layout::Rect]
      # @param board [Agentilda::Board]
      # @param table_state [RatatuiRuby::TableState]
      # @return [void]
      def render(tui, frame, area, board, table_state)
        sync_selection(board, table_state)
        _, top, _, table_area, bottom = tui.layout_split(area,
          direction:   :vertical,
          constraints: [tui.constraint_length(1), tui.constraint_length(1), tui.constraint_length(1),
                        tui.constraint_fill(1), tui.constraint_length(1)])
        bottom_text, bottom_spark = tui.layout_split(bottom,
          direction:   :horizontal,
          constraints: [tui.constraint_fill(3), tui.constraint_fill(1)])

        frame.render_widget(top_bar(tui, board), top)
        frame.render_stateful_widget(table(tui, board), table_area, table_state)
        render_activities(tui, frame, table_area, board, table_state)
        frame.render_widget(bottom_bar(tui, board), bottom_text)
        frame.render_widget(tui.sparkline(data: @history, style: tui.style(fg: :cyan)), bottom_spark)
        render_overlay(tui, frame, area, board)
      end

      # @param board [Agentilda::Board]
      # @return [void]
      def sample(board)
        now = UI.monotonic
        return if @last_sample && now - @last_sample < SAMPLE_INTERVAL

        @last_sample = now
        @history << board.running
        @history.shift while @history.size > HISTORY
      end

      # @param event [RatatuiRuby::Event]
      # @return [void]
      def forward(event)
        key = KeyTranslator.call(event) or return
        @keyboard&.handle(key)
      end

      private

      # @param board [Agentilda::Board]
      # @param table_state [RatatuiRuby::TableState]
      # @return [void]
      def sync_selection(board, table_state)
        index = board.selected && board.rows.index { |r| r.key == board.selected }
        table_state.select(index)
      end

      # @return [RatatuiRuby::Widgets::Paragraph]
      def top_bar(tui, board)
        tui.paragraph(
          text:  "#{board.status} · plans: #{board.plans.join(", ")} " \
                 "· tokens ↑#{UI.abbreviate(board.up)} ↓#{UI.abbreviate(board.down)}",
          style: tui.style(fg: :black, bg: :white)
        )
      end

      # @return [RatatuiRuby::Widgets::Paragraph]
      def bottom_bar(tui, board)
        tui.paragraph(
          text:  "working in #{board.root} · agents running: #{board.running} " \
                 "· live ↑#{UI.abbreviate(board.live_up)} ↓#{UI.abbreviate(board.live_down)}",
          style: tui.style(fg: :black, bg: :white)
        )
      end

      # @return [RatatuiRuby::Widgets::Table]
      def table(tui, board)
        tui.table(header: HEADER,
          rows: board.rows.map { |row| table_row(tui, row) },
          widths: COLUMNS.map { |w| tui.constraint_length(w) },
          highlight_symbol: HIGHLIGHT_SYMBOL,
          highlight_spacing: :always,
          row_highlight_style: tui.style(modifiers: [:reversed]))
      end

      # Lines one agent takes: its table row, then its statuses.
      #
      # @return [Integer]
      def row_height = 1 + scroll_height

      # Paints each visible agent's latest statuses over the empty lines
      # under its table row, newest first: the newest bold, the rest plain,
      # all yellow. A table cell cannot span columns, so a status would
      # otherwise be clipped to one column's width; drawn on top, it gets
      # everything from the feature column to {ACTIVITY_MARGIN} cells before
      # the right edge, and a longer status ends in an ellipsis.
      #
      # @return [void]
      def render_activities(tui, frame, table_area, board, table_state)
        width = table_area.width - ACTIVITY_INDENT - ACTIVITY_MARGIN
        return if width <= 0

        bottom = table_area.y + table_area.height
        board.rows.drop(table_state.offset.to_i).each_with_index do |row, index|
          # +1 for the header line, +1 more to land under the row's own line.
          top = table_area.y + 1 + (index * (row_height + ROW_GAP)) + 1
          break if top >= bottom

          statuses(row).each_with_index do |text, line|
            y = top + line
            break if y >= bottom

            modifiers = line.zero? ? [:bold] : []
            frame.render_widget(
              tui.paragraph(text: ellipsize(text, width), style: tui.style(fg: :yellow, modifiers:)),
              tui.rect(x: table_area.x + ACTIVITY_INDENT, y:, width:, height: 1)
            )
          end
        end
      end

      # @param text [String]
      # @param width [Integer] cells available
      # @return [String] the text, or its head and an ellipsis within +width+
      def ellipsize(text, width) = text.length > width ? "#{text[0, width - 1]}…" : text

      # @param row [Agentilda::Board::Row]
      # @return [Array<String>] newest first, at most {#scroll_height}
      def statuses(row)
        lines = row.history.empty? ? [row.message.to_s] : row.history
        lines.first(scroll_height)
      end

      # @return [RatatuiRuby::Widgets::Row]
      def table_row(tui, row)
        tui.row(height: row_height,
          bottom_margin: ROW_GAP,
          cells: [
            row.at.strftime("%H:%M:%S"),
            row.ordinal,
            row.file,
            tui.text_span(content: row.agent, style: tui.style(fg: :yellow, modifiers: [:bold])),
            "R:#{row.round}/#{row.rounds}",
            row.model.to_s,
            row.subagents.to_s,
            "↑#{UI.abbreviate(row.up)} ↓#{UI.abbreviate(row.down)}",
            Bar.cell(tui, row.elapsed, Bar.elapsed_color(row.elapsed)),
            Bar.cell(tui, row.remaining, Bar.remaining_color(row.remaining))
          ])
      end

      # @return [void]
      def render_overlay(tui, frame, area, board)
        text = board.dialog || board.help || board.about or return
        title = if board.dialog
                  "Agent"
                else
                  (board.help ? "Keys" : "About")
                end
        lines = text.lines.size + 4
        width = [text.lines.map { |l| l.chomp.length }.max.to_i + 6, area.width].min
        overlay_area = tui.rect(x: [(area.width - width) / 2, 0].max,
          y: [(area.height - lines) / 2, 0].max,
          width:,
          height: lines)
        frame.render_widget(tui.paragraph(text:, block: tui.block(title:, borders: [:all])), overlay_area)
      end
    end
  end
end
