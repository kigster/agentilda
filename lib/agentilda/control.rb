# frozen_string_literal: true

module Agentilda
  # The side channel between a keypress and a running agent.
  #
  # `claude -p` takes no input once it starts, so the only way to reach an
  # agent mid-flight is a file it has been told to poll: each invocation gets
  # a control file of its own, named in its prompt, and a keypress writes a
  # word into every file currently registered. Like everything else about the
  # prompt this is a request — an agent deep in a tool call reads the file at
  # its next step, not instantly — which is why {#quit!} also arms a deadline
  # the {Executor} checks, so "quit" is eventually a guarantee too.
  module Control
    # What a keypress writes into a control file. One word, one line, so an
    # agent can act on `File.read(path).strip` and nothing subtler.
    WRAP_UP = "WRAP_UP"
    STOP = "STOP"

    # Seconds between {#quit!} and the harness terminating whatever is still
    # running. Long enough to write files and a handoff note; short enough
    # that q means quit rather than "quit eventually".
    GRACE = 60

    @mutex = Mutex.new
    @files = []
    @quit = false
    @deadline = nil

    class << self
      # Register a fresh control file for one invocation and hand back its
      # path, to be named in the agent's prompt.
      #
      # @param dir [String] where the file lives (the trace dir — outside the
      #   repository for the same reason traces are)
      # @param name [String] something findable: plan ordinal and agent name
      # @return [String]
      def register(dir, name)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "control-#{name}-#{Process.pid}-#{format("%04x", rand(0x10000))}")
        File.write(path, "")
        @mutex.synchronize { @files << path }
        path
      end

      # Forget a finished invocation's file. The file itself is removed so a
      # crashed run does not leave stale STOPs for the next one to find.
      #
      # @param path [String]
      # @return [void]
      def release(path)
        @mutex.synchronize { @files.delete(path) }
        FileUtils.rm_f(path)
      end

      # `w`: every running agent is asked to finish the essential remainder
      # as fast as it can. The loop itself keeps going.
      #
      # @return [void]
      def wrap_up! = broadcast(WRAP_UP)

      # `n`: every running agent is asked to write out what it has and end
      # its turn. The loop keeps going — under chaining that is exactly what
      # hands the plan to the next agent.
      #
      # @return [void]
      def stop! = broadcast(STOP)

      # `q`: {#stop!}, plus the loop ends after this round, plus a deadline —
      # {GRACE} seconds from now — after which the {Executor} aborts whatever
      # is still running rather than waiting on its goodwill.
      #
      # @return [void]
      def quit!
        stop!
        @mutex.synchronize {
          @quit = true
          @deadline ||= UI.monotonic + GRACE
        }
      end

      # @return [Boolean] whether `q` has been pressed
      def quit? = @mutex.synchronize { @quit }

      # @return [Boolean] whether the grace period after `q` has run out
      def overdue?
        @mutex.synchronize { !@deadline.nil? && UI.monotonic > @deadline }
      end

      # Back to rest, for the next `Runner#call` — and for the suite, where
      # one example's q must not quit every example after it.
      #
      # @return [void]
      def reset!
        @mutex.synchronize {
          @files.each { |f| FileUtils.rm_f(f) }
          @files.clear
          @quit = false
          @deadline = nil
        }
      end

      private

      # @param word [String]
      # @return [void]
      def broadcast(word)
        @mutex.synchronize { @files.dup }.each do |path|
          File.write(path, "#{word}\n")
        rescue SystemCallError
          # A file whose invocation just finished is not an error to miss.
        end
      end
    end
  end
end
