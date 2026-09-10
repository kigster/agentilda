# frozen_string_literal: true

module Agentilda
  # One `claude` process the harness started and therefore owns.
  #
  # `TTY::Command` never exposes the pid it spawned, so the executor used to
  # find its child by scraping `ps` for a fresh `claude` under this process
  # and could never safely signal it. Kill (`k`) and the sixty-second
  # backstop after STOP both need a pid that is certainly ours, so the
  # process is spawned here and the pid kept.
  #
  # stderr is folded into the same pipe as stdout: `claude` prints the cause
  # of a failure there, and the transcript keeps non-JSON lines for exactly
  # that reason.
  class Child
    # @param argv [Array<String>]
    # @param chdir [String, nil]
    # @return [Agentilda::Child]
    def self.spawn(argv, chdir: nil)
      reader, writer = IO.pipe
      options = { out: writer, err: writer, in: File::NULL }
      options[:chdir] = chdir if chdir
      pid = Process.spawn(*argv, **options)
      writer.close
      new(pid:, reader:)
    end

    # @param pid [Integer]
    # @param reader [IO]
    def initialize(pid:, reader:)
      @pid = pid
      @reader = reader
      @status = nil
    end

    # @return [Integer]
    attr_reader :pid

    # Read until the process closes its end. Runs on the caller's thread;
    # the executor reads on the same thread it always did.
    #
    # @yieldparam text [String] whatever arrived, possibly a partial line
    # @return [void]
    def each_chunk
      loop { yield @reader.readpartial(65_536) }
    rescue IOError
      @reader.close unless @reader.closed?
    end

    # @return [Process::Status]
    def wait
      @status ||= begin
        _, status = Process.wait2(pid)
        status
      end
    rescue Errno::ECHILD
      @status
    end

    # @param signal [String]
    # @return [void]
    def kill(signal = "KILL")
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      # Already gone, which is what was wanted.
    end

    # @return [Boolean]
    def alive?
      return false if @status

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end
