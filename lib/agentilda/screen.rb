# frozen_string_literal: true

require "tty/cursor"

module Agentilda
  # The run, drawn. Two bars, a header, a rule, one row per agent, a rule.
  #
  # Redrawn whole once a second from a {Board}, which is why it can be
  # tested against a string: {#render} builds the frame, {#draw} puts it on
  # the terminal. Every column is a fixed number of cells and every cell is
  # cut with {UI.fit}, because an emoji is two cells wide and a column that
  # sizes itself drifts sideways every time a number grows.
  class Screen
    # Cells per column. The status column takes what is left.
    COLUMNS = { at: 9, ordinal: 6, file: 16, agent: 18, model: 7, timer: 12, tokens: 13 }.freeze

    # Cells of the timer column the countdown itself takes: "99:59" and one of
    # air. The column is wider than that only so "[wrapping]" fits after STOP.
    CLOCK = 6

    # Between columns.
    SEPARATOR = " | "

    # One cell of margin on both sides, bars included.
    MARGIN = 1

    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    # What each document is painted as. A pull request number is painted by
    # {#file_cell} from the row's `pr` instead.
    FILE_STYLES = {
      "spec.md"          => %i[green],
      "plan.md"          => %i[yellow],
      "plan-backend.md"  => %i[yellow bold],
      "plan-frontend.md" => %i[cyan],
      "pull-requests.md" => %i[magenta]
    }.freeze

    # Rows of the frame that are not agent rows: bars, blanks, header, rules.
    CHROME = 8

    # @param text [String]
    # @param url [String]
    # @return [String] an OSC 8 hyperlink most terminals make clickable
    def self.hyperlink(text, url) = "\e]8;;#{url}\e\\#{text}\e]8;;\e\\"

    # @param width [Integer] terminal columns
    # @return [Integer] cells the status column gets
    def self.status_width(width)
      fixed = COLUMNS.values.sum + (SEPARATOR.length * COLUMNS.size) + (MARGIN * 2)
      [width - fixed, 10].max
    end

    # @param output [IO]
    # @param width [Proc] terminal columns, read on every draw
    # @param height [Proc] terminal rows
    def initialize(output: $stderr, width: -> { TTY::Screen.width }, height: -> { TTY::Screen.height })
      @output = output
      @width = width
      @height = height
      @cursor = TTY::Cursor
    end

    # @return [void]
    def open = @output.print(@cursor.hide, @cursor.clear_screen)

    # @return [void]
    def close = @output.print(@cursor.show, @cursor.move_to(0, @height.call - 1), "\n")

    # @param board [Agentilda::Board]
    # @return [void]
    def draw(board)
      @output.print(@cursor.move_to(0, 0), @cursor.clear_screen_down, render(board))
      @output.flush
    end

    # @param board [Agentilda::Board]
    # @return [String] the whole frame
    def render(board)
      width = @width.call
      visible, hidden = split(board.rows)
      lines = [top_bar(board, width), "", header(width), rule(width)]
      lines += visible.map { |row| line(row, width, selected: board.selected == row.key) }
      lines << pad(" +#{hidden} more", width) if hidden.positive?
      lines += [rule(width), "", bottom_bar(board, width)]
      lines << overlay(board.dialog, "Agent", width) if board.dialog
      lines << overlay(board.help, "Keys", width, footer: "[ESC] close") if board.help
      lines << overlay(board.about, "About", width, footer: "[ESC] close") if board.about
      lines.join("\n") + "\n"
    end

    private

    # Running rows first, then the ones that just finished; what does not
    # fit is counted rather than scrolled off.
    #
    # @return [Array(Array<Agentilda::Board::Row>, Integer)]
    def split(rows)
      room = [@height.call - CHROME - 1, 1].max
      ordered = rows.sort_by { |r| [r.running? ? 0 : 1, -r.at.to_f] }
      [ordered.first(room), [ordered.size - room, 0].max]
    end

    # @return [String]
    def top_bar(board, width)
      elapsed = UI.monotonic - board.started_at
      status = case board.status
               when :quitting then UI.paint("quitting", :red, :on_white)
               when :wrapping_up then UI.paint("wrapping up", :red, :on_white)
               else UI.paint("running", :green, :on_white)
               end
      clock = UI.paint(format("%d:%02d", elapsed / 60, elapsed % 60), :black, :on_white)
      plans = UI.paint("plans in work: #{board.plans.join(", ")}", :black, :on_white)
      bar("[ #{status} #{clock} ] [ #{plans} ] [ #{tokens("tokens", board.up, board.down)} ]", width)
    end

    # @return [String]
    def bottom_bar(board, width)
      left = UI.paint("working in #{board.root}", :black, :on_white)
      running = UI.paint("agents running: #{board.running}", (board.running.positive? ? :green : :black), :on_white)
      bar("[ #{left} | #{running} | #{tokens("live", board.live_up, board.live_down)} ]", width)
    end

    # Up magenta, down cyan, on grey, as asked.
    #
    # @return [String]
    def tokens(label, up, down)
      UI.paint("#{label}:", :black, :on_white) +
        UI.paint(" ↑ #{UI.abbreviate(up)} ", :magenta, :on_bright_black) +
        UI.paint(" ↓ #{UI.abbreviate(down)} ", :cyan, :on_bright_black)
    end

    # A white bar the full width, one cell in from each edge.
    #
    # @return [String]
    def bar(content, width)
      inner = width - (MARGIN * 2)
      plain = strip(content)
      filler = UI.paint(" " * [inner - UI.display_width(plain), 0].max, :black, :on_white)
      (" " * MARGIN) + content + filler + (" " * MARGIN)
    end

    # @return [String]
    def header(width)
      cells = [["timestamp", :at], ["plan", :ordinal], ["file", :file], ["agent [R:n/m]", :agent],
               ["model", :model], ["time", :timer], ["tokens", :tokens]].map { |text, key| UI.fit(text, COLUMNS[key]) }
      cells << UI.fit("what the agent says", self.class.status_width(width))
      # Fitted first, painted second: {UI.fit} counts an escape sequence as
      # four cells, so a painted header cut to width loses its reset code.
      (" " * MARGIN) + UI.paint(cells.join(SEPARATOR), :bold)
    end

    # @return [String]
    def rule(width) = (" " * MARGIN) + ("─" * (width - (MARGIN * 2)))

    # @return [String]
    def line(row, width, selected:)
      cells = [
        UI.paint(UI.fit(row.at.strftime("%H:%M:%S"), COLUMNS[:at]), :bright_black),
        UI.fit(row.ordinal, COLUMNS[:ordinal]),
        file_cell(row),
        UI.fit("#{row.role} [R:#{row.round}/#{row.rounds}]", COLUMNS[:agent]),
        UI.fit(row.model.to_s, COLUMNS[:model]),
        timer_cell(row),
        UI.paint(UI.fit("↑#{UI.abbreviate(row.up)}", 7), :magenta) + UI.paint(UI.fit("↓#{UI.abbreviate(row.down)}", 6), :cyan),
        status_cell(row, width)
      ]
      text = (" " * MARGIN) + cells.join(SEPARATOR)
      selected ? UI.paint(text, :inverse) : text
    end

    # @return [String]
    def file_cell(row)
      if row.pr
        # Painted and linked bare, padded after: a link that spans the padding
        # is a link on empty cells, and colour on the padding is what the spec
        # asserts is not there.
        number = UI.fit("##{row.pr[:number]}", COLUMNS[:file]).rstrip
        painted = UI.paint(number, row.pr[:rejected] ? :red : :bright_blue)
        linked = row.pr[:url] ? self.class.hyperlink(painted, row.pr[:url]) : painted
        linked + (" " * (COLUMNS[:file] - UI.display_width(number)))
      else
        UI.paint(UI.fit(row.file, COLUMNS[:file]), *FILE_STYLES.fetch(row.file, [:white]))
      end
    end

    # The spinner, then the countdown. Amber once warned, red from the
    # wrap-up, and the word the design asked for after STOP.
    #
    # @return [String]
    def timer_cell(row)
      mark = case row.state
             when :running then SPINNER[row.frame % SPINNER.size]
             when :done then UI.paint("✓", :green)
             else UI.paint("✖", :red, :bold)
             end
      text = if row.state != :running
               UI.fit("", COLUMNS[:timer] - 2)
             elsif [:stopped, :expired].include?(row.phase)
               UI.paint(UI.fit("[wrapping]", COLUMNS[:timer] - 2), :red, :bold)
             elsif row.remaining.nil?
               UI.fit("", COLUMNS[:timer] - 2)
             else
               # Minutes right-aligned so the digits hold still as they count down.
               # Only the clock is painted; the cells kept for "[wrapping]" stay bare.
               clock = UI.fit(format("%2d:%02d", row.remaining / 60, row.remaining % 60), CLOCK)
               colour = case row.phase
                        when :wrap_up then :red
                        when :warned then :yellow
                        else :bright_black
                        end
               UI.paint(clock, colour) + (" " * (COLUMNS[:timer] - 2 - CLOCK))
             end
      "#{mark} #{text}"
    end

    # Bold white on yellow, reaching one cell before the edge.
    #
    # @return [String]
    def status_cell(row, width)
      text = UI.fit(row.message.to_s, self.class.status_width(width))
      styles = row.state == :failed ? %i[white bold on_red] : %i[white bold on_yellow]
      styles = %i[red bold] if row.bold && row.state != :running
      UI.paint(text, *styles)
    end

    # @return [String] the text cut to the width, margins kept
    def pad(text, width) = UI.fit(text, width)

    # A centred box over the table. The next frame draws over it, which is
    # all the dismissal a dialog needs once ESC has cleared the board's
    # `dialog` field.
    #
    # @return [String]
    def overlay(text, title, width, footer: "[ENTER] apply   [ESC] discard")
      body = text.to_s + "\n\n" + footer
      lines = body.lines
      box_width = [lines.map { |l| UI.display_width(l.chomp) }.max.to_i + 6, width].min
      box_height = lines.size + 4
      TTY::Box.frame(
        top:          [(@height.call - box_height) / 2, 0].max,
        left:         [(width - box_width) / 2, 0].max,
        width:        box_width,
        height:       box_height,
        padding:      1,
        title:        { top_left: " #{title} " },
        enable_color: UI.color?,
        style:        UI.color? ? { border: { fg: :cyan } } : {}
      ) { body }
    end

    # @return [String] text without escape sequences, for measuring
    def strip(text) = text.gsub(/\e\[[0-9;]*[a-zA-Z]|\e\]8;;[^\e]*\e\\/, "")
  end
end
