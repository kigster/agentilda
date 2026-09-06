# frozen_string_literal: true

module Agentilda
  # What the keys do to the screen, and to the running agents.
  #
  # Selection and the dialog live here, never on the screen: the screen
  # draws whatever board it is handed, and this decides what the board
  # says. Pending changes are visible only in the dialog and take effect
  # only on ENTER, so a stray `k` kills nobody.
  class Console
    # Seconds each `x` adds.
    EXTENSION = 600

    # @param screen [Agentilda::Screen]
    def initialize(screen:)
      @screen = screen
      @dispatcher = nil
      @board = nil
      @selected = nil
      @dialog = false
      @help = false
      @pending = {kill: false, extend: 0}
      @mutex = Mutex.new
    end

    # @return [String, nil] the selected row's key
    attr_reader :selected

    # @return [Hash] `{kill: Boolean, extend: Integer}`
    attr_reader :pending

    # @return [Agentilda::Screen]
    attr_reader :screen

    # @return [Boolean]
    def dialog? = @dialog

    # @return [Boolean]
    def help? = @help

    # The dispatcher exists only once the run starts, after the keyboard is
    # already listening, so it arrives late.
    #
    # @param dispatcher [Agentilda::Dispatcher]
    # @return [void]
    def attach(dispatcher) = @dispatcher = dispatcher

    # Called by the dispatcher each tick.
    #
    # @param board [Agentilda::Board]
    # @return [void]
    def paint(board)
      @mutex.synchronize do
        @board = board
        @selected = nil if @selected && board.rows.none? { |r| r.key == @selected && r.running? }
        @screen.draw(board.with(selected: @selected, dialog: (dialog_text if @dialog), help: (help_text if @help)))
      end
    end

    # @return [void]
    def select_next = move(1)

    # @return [void]
    def select_prev = move(-1)

    # @return [void]
    def toggle_kill
      select_next unless @selected
      return unless @selected

      @pending[:kill] = !@pending[:kill]
      @dialog = true
    end

    # @return [void]
    def extend
      select_next unless @selected
      return unless @selected

      @pending[:extend] += EXTENSION
      @dialog = true
    end

    # ENTER.
    #
    # @return [void]
    def apply
      return unless @dialog && @selected && @dispatcher

      @dispatcher.kill(@selected) if @pending[:kill]
      @dispatcher.extend(@selected, @pending[:extend]) if @pending[:extend].positive?
      UI.log("applied to #{@selected}: #{dialog_text.tr("\n", ", ")}")
      close_dialog
    end

    # ESC: the dialog first, then the help, then the selection.
    #
    # @return [void]
    def escape
      if @dialog
        close_dialog
      elsif @help
        @help = false
      else
        @selected = nil
      end
    end

    # @return [void]
    def toggle_help = @help = !@help

    private

    # @return [void]
    def close_dialog
      @dialog = false
      @pending = {kill: false, extend: 0}
    end

    # @param step [Integer]
    # @return [void]
    def move(step)
      keys = (@board&.rows || []).select(&:running?).map(&:key)
      return @selected = nil if keys.empty?

      index = keys.index(@selected)
      @selected = index.nil? ? keys.first : keys[(index + step) % keys.size]
    end

    # @return [String]
    def dialog_text
      row = @board&.rows&.find { |r| r.key == @selected }
      who = row ? "#{row.ordinal} #{row.agent}" : @selected.to_s
      extension = @pending[:extend].positive? ? "+#{@pending[:extend] / 60}m" : "none"
      "#{who}\n\nkill: #{@pending[:kill] ? "yes" : "no"}\nextend: #{extension}"
    end

    # @return [String]
    def help_text = Keyboard.new(input: $stdin).help
  end
end
