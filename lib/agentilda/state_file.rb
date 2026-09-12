# frozen_string_literal: true

require "fileutils"
require "json"

module Agentilda
  # Where a run stands, written every second, so a harness that dies leaves
  # the next one something to restart from.
  #
  # The ledger inside each document is the record humans read and the
  # dispatcher acts on; this is the index of it, plus what the ledger cannot
  # hold: which run wrote what, process ids, tokens, and whether the run
  # that wrote a `Started` is still alive. It sits under `.plans/tmp/`
  # rather than the system temp dir because a reboot must not lose it, and
  # it is gitignored because it is about one machine's run, not the plan.
  class StateFile
    DIRNAME = "tmp"
    FILENAME = "agentilda-state.json"

    # The line {.ensure_ignored!} adds.
    IGNORE = "#{Agentilda::PLANS_DIR}/#{DIRNAME}/"

    # @param tree [Agentilda::Tree]
    # @return [String]
    def self.for(tree) = File.join(tree.dir, DIRNAME, FILENAME)

    # Add the ignore line once. Editing somebody's `.gitignore` is a thing
    # to announce, which is why this returns whether it did.
    #
    # @param root [String] repository root
    # @return [Boolean] true when a line was added
    def self.ensure_ignored!(root)
      return false unless system("git", "-C", root, "rev-parse", "--git-dir", out: File::NULL, err: File::NULL)
      return false if system("git", "-C", root, "check-ignore", "-q", IGNORE, out: File::NULL, err: File::NULL)

      path = File.join(root, ".gitignore")
      existing = File.file?(path) ? File.read(path) : ""
      glue = existing.empty? || existing.end_with?("\n") ? "" : "\n"
      File.write(path, "#{existing}#{glue}#{IGNORE}\n")
      true
    end

    # @param path [String]
    # @param pid [Integer] this run's process id
    def initialize(path:, pid: Process.pid)
      @path = path
      @pid = pid
      @data = { "run" => {}, "plans" => {} }
      @mutex = Mutex.new
    end

    # @return [String]
    attr_reader :path

    # @return [self]
    def load
      @mutex.synchronize do
        @data = JSON.parse(File.read(path)) if File.file?(path)
        @data = { "run" => {}, "plans" => {} } unless @data.is_a?(Hash) && @data["plans"].is_a?(Hash)
      end
      self
    rescue JSON::ParserError
      self
    end

    # Written whole to a sibling and renamed over, so a reader never sees
    # half a file.
    #
    # @return [void]
    def save
      @mutex.synchronize do
        FileUtils.mkdir_p(File.dirname(path))
        temp = "#{path}.#{@pid}.tmp"
        File.write(temp, JSON.pretty_generate(@data))
        File.rename(temp, path)
      end
    end

    # @param root [String]
    # @return [void]
    def begin_run!(root:)
      @mutex.synchronize do
        @data["run"] = { "pid" => @pid, "root" => root, "started_at" => Time.now.iso8601,
                        "heartbeat_at" => Time.now.iso8601 }
      end
    end

    # @return [void]
    def heartbeat!
      @mutex.synchronize { @data["run"]["heartbeat_at"] = Time.now.iso8601 }
    end

    # @param ordinal [String]
    # @param agent [String]
    # @param round [Integer]
    # @param fields [Hash] anything else worth keeping: status, model, file,
    #   pid, up, down, state, next, exit
    # @return [void]
    def record(ordinal, agent:, round:, **fields)
      @mutex.synchronize do
        plan = (@data["plans"][ordinal.to_s] ||= { "stages" => [] })
        stage = plan["stages"].find { |s| s["agent"] == agent && s["round"] == round }
        unless stage
          stage = { "agent" => agent, "round" => round, "run_pid" => @pid }
          plan["stages"] << stage
        end
        fields.each { |key, value| stage[key.to_s] = value }
      end
    end

    # @param ordinal [String]
    # @return [Array<Hash>]
    def stages(ordinal) = @mutex.synchronize { (@data.dig("plans", ordinal.to_s, "stages") || []).map(&:dup) }

    # @return [Array<String>] every ordinal with a stage recorded
    def plans = @mutex.synchronize { @data["plans"].keys }

    # @return [Boolean] whether the run that last wrote this file is gone
    def previous_run_dead?
      previous = @data.dig("run", "pid")
      return false if previous.nil? || previous == @pid

      Process.kill(0, previous)
      false
    rescue Errno::ESRCH, Errno::EPERM
      true
    end

    # Stages a dead run left `Started`. Each is an agent that was cut off
    # mid-flight and has to be re-run, with the harness's own Interrupted
    # line written so the document agrees with this file.
    #
    # @return [Array<Array(String, Hash)>] ordinal and stage
    def stranded
      return [] unless previous_run_dead?

      @mutex.synchronize do
        @data["plans"].flat_map { |ordinal, plan|
          plan["stages"].select { |s| s["status"] == "Started" && s["run_pid"] != @pid }
                        .map { |s| [ordinal, s.dup] }
        }
      end
    end
  end
end
