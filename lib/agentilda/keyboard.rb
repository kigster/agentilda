# frozen_string_literal: true

require "io/console"

module Agentilda
  # Listens for single keypresses while a run is in flight, and turns them
  # into {Control} broadcasts.
  #
  # The listener is a thread reading STDIN in raw mode, which only makes
  # sense when STDIN is a terminal: piped input must never be eaten one byte
  # at a time, and a run under cron has nobody at the keys. {.listen} returns
  # nil in both cases and every caller treats nil as "no keyboard".
  #
  # Raw mode swallows Ctrl-C along with everything else, so ETX is forwarded
  # to the main thread as the Interrupt it would have been — the listener
  # must never make a run harder to kill than it was without one.
  class Keyboard
    # Key → what it does, rendered by {#help} and dispatched by {#handle}.
    BINDINGS = [
      ["h  ?", "this help"],
      ["w", "ask every running agent to wrap up as fast as possible"],
      ["n", "ask agents to write out what they have and stop; the loop continues"],
      ["q", "write out, stop everything, and quit after a #{Control::GRACE}s grace"],
      ["ctrl-c", "interrupt the run, as ever"]
    ].freeze

    # @return [Agentilda::Keyboard, nil] a running listener, or nil when
    #   STDIN is not a terminal
    def self.listen(input: $stdin)
      return nil unless input.tty?

      new(input:).start
    end

    # @param input [IO]
    def initialize(input: $stdin)
      @input = input
    end

    # @return [self]
    def start
      @thread = Thread.new do
        Thread.current.report_on_exception = false
        loop { handle(@input.getch) }
      rescue IOError, Errno::EIO
        # STDIN went away; a keyboard with no keys just stops listening.
      end
      self
    end

    # @return [void]
    def stop
      @thread&.kill
      @thread = nil
    end

    # @param key [String, nil]
    # @return [void]
    def handle(key)
      case key
      when "h", "?" then UI.popup("Keys", help)
      when "w" then acted("w — agents asked to wrap up") { Control.wrap_up! }
      when "n" then acted("n — agents asked to write out and stop") { Control.stop! }
      when "q" then acted("q — quitting; #{Control::GRACE}s grace to write out") { Control.quit! }
      when "\u0003" then Thread.main.raise(Interrupt)
      end
    end

    # @return [String] the bindings, one per line, widest key first
    def help
      width = BINDINGS.map { |key, _| key.length }.max
      BINDINGS.map { |key, does| "#{key.ljust(width)}   #{does}" }.join("\n")
    end

    private

    # A keypress with no acknowledgement looks like a keypress that did
    # nothing, so each one says what it just asked for.
    #
    # @param note [String]
    # @return [void]
    def acted(note)
      yield
      UI.log(note)
      UI.line(note)
    end
  end
end
