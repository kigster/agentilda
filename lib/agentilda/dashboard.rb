# frozen_string_literal: true

module Agentilda
  # The ratatui dashboard for agent work that is not a `run`: `unblock`
  # handing plans to lando-broker, `create` drafting a spec.md. `run` has a
  # {Dispatcher} to build its {Board}; this builds one from the items
  # {UI.concurrently} hands it, so every agent a person waits on is drawn
  # the same way, with the same keys.
  #
  # It stands in for the dispatcher behind {Console}, which is why it
  # answers {#kill} and {#extend}: a row whose work passed its
  # {Tracker#handle} on to {Executor#call} can be killed or given more time.
  class Dashboard
    # Seconds between frames handed to the screen.
    REFRESH = 0.25

    # Seconds a finished row stays on screen, so a fast agent is still seen.
    LINGER = 3

    # One item's row, and the {UI::Line} its work streams progress through.
    # Nothing is drawn by the line itself; the dashboard reads it each frame.
    class Tracker < UI::Line
      # @return [String]
      attr_reader :key

      # @return [Agentilda::Executor::Handle] handed to {Executor#call} by a
      #   caller that wants the kill and extend keys to reach its agent.
      #   Not `@handle`: {UI::Line} keeps its dry-cli-ui line under that name.
      def handle = @executor_handle

      # @return [Symbol] :running, :done or :failed
      attr_reader :state

      # @return [Float, nil] monotonic reading of when it stopped running
      attr_reader :finished_at

      # @param key [String]
      # @param fields [Hash] plan, status, agent and round, for the log and the row
      # @param file [String] what the row's feature column says
      # @param message [String] shown until the agent says something
      # @param timeout [Integer, nil]
      def initialize(key:, fields:, file:, message:, timeout: nil)
        super(fields:, timeout:)
        @key = key
        @file = file
        @message = message
        @executor_handle = Executor::Handle.new
        @state = :running
        @update = nil
        @history = []
        @finished_at = nil
      end

      # @param update [Agentilda::Transcript::Progress]
      # @return [void]
      def call(update)
        super
        @update = update
        return unless update.activity

        @message = update.activity
        @history = Board::Row.remember(@history, @message)
      end

      # @return [void]
      def done
        super
        finish(:done)
      end

      # @param reason [String]
      # @return [void]
      def failed(reason)
        super
        @message = reason
        @history = Board::Row.remember(@history, reason)
        finish(:failed)
      end

      # @return [Agentilda::Board::Row]
      def row
        Board::Row.new(key:,
          at: Time.now,
          ordinal: @fields[:plan].to_s,
          file: @file,
          agent: @fields[:agent].to_s,
          role: @fields[:agent].to_s,
          round: @fields[:round] || 1,
          rounds: @fields[:round] || 1,
          model: "default",
          remaining: handle.remaining || remaining,
          phase: handle.phase,
          up: @update&.up.to_i,
          down: @update&.down.to_i,
          message: @message,
          state:,
          elapsed: seconds.round,
          subagents: @update&.subagents.to_i,
          history: @history)
      end

      private

      # @param state [Symbol]
      # @return [void]
      def finish(state)
        @state = state
        @finished_at = UI.monotonic
      end
    end

    # Opens the screen, runs the block, and always closes it again.
    #
    # @param root [String] shown in the bottom bar
    # @param screen [Agentilda::Screen::Ratatui]
    # @yieldparam dashboard [Agentilda::Dashboard]
    # @return [Object] the block's value
    def self.open(root: Dir.pwd, screen: Screen::Ratatui.new)
      dashboard = new(root:, screen:)
      dashboard.start
      begin
        yield dashboard
      ensure
        dashboard.stop
      end
    end

    # @param root [String]
    # @param screen [Agentilda::Screen::Ratatui]
    def initialize(root:, screen:)
      @root = root
      @screen = screen
      @console = Console.new(screen:)
      @console.attach(self)
      @trackers = []
      @lock = Mutex.new
      @started_at = UI.monotonic
      @closing = false
    end

    # @return [void]
    def start
      # ratatui owns the terminal's input, so the keyboard is fed from its
      # loop rather than reading STDIN on a thread of its own.
      @keyboard = Keyboard.new(sink: @console)
      @screen.attach_keyboard(@keyboard)
      @screen.open
      @painter = Thread.new do
        Thread.current.report_on_exception = false
        until @closing
          paint
          sleep(REFRESH)
        end
      end
    end

    # @return [void]
    def stop
      @closing = true
      @painter&.join
      paint
      @screen.close
    end

    # @param key [String]
    # @param fields [Hash]
    # @param file [String]
    # @param message [String]
    # @param timeout [Integer, nil]
    # @return [Tracker]
    def track(key:, fields: {}, file: "", message: "starting", timeout: nil)
      Tracker.new(key:, fields:, file:, message:, timeout:).tap do |tracker|
        @lock.synchronize { @trackers << tracker }
      end
    end

    # @return [void]
    def paint = @console.paint(board)

    # @return [Agentilda::Board]
    def board
      rows = visible.map(&:row)
      running = rows.select(&:running?)
      Board.new(started_at: @started_at,
        status: Control.quit? ? :quitting : :running,
        plans: rows.map(&:ordinal).reject(&:empty?).uniq,
        up: rows.sum(&:up),
        down: rows.sum(&:down),
        rows:,
        root: @root,
        running: running.size,
        live_up: running.sum(&:up),
        live_down: running.sum(&:down))
    end

    # @param key [String]
    # @return [void]
    def kill(key) = find(key)&.handle&.kill!

    # @param key [String]
    # @param seconds [Integer]
    # @return [void]
    def extend(key, seconds) = find(key)&.handle&.extend!(seconds)

    private

    # @return [Array<Tracker>] running, plus whatever finished a moment ago
    def visible
      now = UI.monotonic
      @lock.synchronize do
        @trackers.reject { |t| t.finished_at && now - t.finished_at > LINGER }
      end
    end

    # @param key [String]
    # @return [Tracker, nil]
    def find(key) = @lock.synchronize { @trackers.find { |t| t.key == key } }
  end
end
