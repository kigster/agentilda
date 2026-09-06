# frozen_string_literal: true

module Agentilda
  # The one channel two agents on the same plan have to each other.
  #
  # `luke-backend` and `rey-frontend` build one plan in one worktree at the
  # same time, but each is its own `claude -p` process. Claude Code can
  # message between local sessions, and the prompts used to say so, but a
  # session is named after its directory plus a random suffix, so a pair had
  # to guess its partner from a list of every session on the machine by start
  # time. It worked once, by luck. With ten plans running there would have
  # been ten `agentilda-xx` entries and nothing to tell them apart.
  #
  # So the mailbox is a file in the plan folder, append-only, one numbered
  # entry per message, readable by `agentilda mail read` during the round and
  # by a person after it. The harness names the file and the partner in each
  # agent's prompt, so nobody guesses.
  class Mailbox
    FILENAME = "mailbox.md"

    # Between the fields of a heading. Neither a name nor a timestamp
    # contains it, which is what makes the heading parseable.
    SEPARATOR = " · "

    # `## 3 · 2026-09-06 10:30:53 -0700 · rey-frontend → luke-backend`
    HEADING = /\A\#\# (\d+) · (.+?) · (\S+) → (\S+)\s*\z/

    TIME_FORMAT = "%Y-%m-%d %H:%M:%S %z"

    # One entry.
    #
    # @!attribute [r] number
    #   @return [Integer] 1-based, in order of writing
    # @!attribute [r] at
    #   @return [String] when, as {TIME_FORMAT} writes it
    # @!attribute [r] from
    #   @return [String] the agent that wrote it
    # @!attribute [r] to
    #   @return [String] the agent it is for
    # @!attribute [r] body
    #   @return [String]
    Message = Data.define(:number, :at, :from, :to, :body) do
      # @return [String] as it stands in the file
      def to_s = "## #{number}#{SEPARATOR}#{at}#{SEPARATOR}#{from} → #{to}\n\n#{body.strip}\n"
    end

    # @param dir [String] the plan folder
    def initialize(dir:)
      @dir = dir
    end

    # @return [String] the plan folder
    attr_reader :dir

    # @return [String]
    def path = File.join(dir, FILENAME)

    # @return [Boolean]
    def exist? = File.file?(path)

    # Every message, in the order it was written.
    #
    # @return [Array<Agentilda::Mailbox::Message>]
    def messages
      return [] unless exist?

      parse(File.read(path, encoding: "UTF-8"))
    end

    # What is waiting for one agent.
    #
    # @param name [String] the reader
    # @param after [Integer] a number the reader has already seen; only
    #   messages above it are returned
    # @return [Array<Agentilda::Mailbox::Message>]
    def for(name, after: 0)
      messages.select { |m| m.to == name && m.number > after }
    end

    # Append one message and give it the next number.
    #
    # The append takes a lock on the file. Two agents finishing a unit in the
    # same second would otherwise read the same last number and both write
    # the one after it.
    #
    # @param from [String]
    # @param to [String]
    # @param body [String]
    # @param at [Time]
    # @return [Agentilda::Mailbox::Message] as written
    # @raise [Agentilda::Error] on an empty body, which would be a heading
    #   with nothing under it for the reader to act on, or on a sender or
    #   recipient that is blank or holds whitespace: {HEADING} could not
    #   parse such an entry back, so it would be written and never read
    def append(from:, to:, body:, at: Time.now)
      text = body.to_s.strip
      raise Error, "a message needs a body" if text.empty?
      raise Error, "a message needs --from and --to, each one agent name" unless name?(from) && name?(to)

      File.open(path, File::RDWR | File::CREAT | File::APPEND, 0o644) do |f|
        f.flock(File::LOCK_EX)
        f.rewind
        existing = f.read
        number = (parse(existing).last&.number || 0) + 1
        message = Message.new(number:, at: at.strftime(TIME_FORMAT), from:, to:, body: text)
        f.write(existing.empty? ? "# Mailbox\n\n#{message}" : "\n#{message}")
        message
      end
    end

    private

    # @param value [Object]
    # @return [Boolean] one token, as {HEADING} expects a name to be
    def name?(value) = value.to_s.match?(/\A\S+\z/)

    # Only a line shaped exactly like {HEADING} starts a message, so a body
    # may hold headings of its own, code, anything.
    #
    # @param text [String]
    # @return [Array<Agentilda::Mailbox::Message>]
    def parse(text)
      messages = []
      current = nil
      body = []

      text.to_s.each_line(chomp: true) do |line|
        if (heading = HEADING.match(line))
          messages << current.with(body: body.join("\n").strip) if current
          current = Message.new(number: heading[1].to_i, at: heading[2], from: heading[3], to: heading[4], body: "")
          body = []
        elsif current
          body << line
        end
      end

      messages << current.with(body: body.join("\n").strip) if current
      messages
    end
  end
end
