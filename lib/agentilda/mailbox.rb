# frozen_string_literal: true

require "json"
require "time"

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
  # So the mailbox is a file in the plan folder, one entry per message,
  # readable by `agentilda mail read` during the round and by a person after
  # it — through `agentilda mail render`, because the file itself is JSON.
  # It is JSON so that an agent does no parsing: the old format was Markdown
  # matched by a heading regex, which every reader had to get right and
  # which no writer could extend. Human readability is recovered by
  # rendering rather than by storage.
  #
  # The document is an object with a `messages` key rather than a bare
  # array, so the sections a later round adds beside it — `last-known-state`
  # among them — do not break the format for everything already written.
  class Mailbox
    FILENAME = "mailbox.json"

    # What {#render} writes above the messages.
    TITLE = "# Mailbox"

    # Written by the reader, never by delivery. A consumer group's ack says
    # the bytes arrived; only the agent can say it read them.
    READ = "yes"
    UNREAD = "no"

    # One entry.
    #
    # @!attribute [r] number
    #   @return [Integer] 1-based, in order of writing
    # @!attribute [r] at
    #   @return [String] when, ISO 8601
    # @!attribute [r] from
    #   @return [String] the agent that wrote it
    # @!attribute [r] to
    #   @return [String] the agent it is for
    # @!attribute [r] body
    #   @return [String]
    # @!attribute [r] read
    #   @return [String] {READ} once the recipient has acknowledged it
    Message = Data.define(:number, :at, :from, :to, :body, :read) do
      # @return [Boolean]
      def read? = read == READ

      # @return [Hash] as it stands in the file
      def to_h = { "number" => number, "at" => at, "from" => from, "to" => to, "body" => body, "read" => read }

      # @return [String] one entry, rendered for a person
      def to_s = "## #{number} · #{at} · #{from} → #{to}#{" · unread" unless read?}\n\n#{body.strip}\n"
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

      decode(File.read(path, encoding: "UTF-8"))
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

    # What one agent has been sent and not acknowledged. The count is what
    # the dashboard shows: an agent that stopped acking is an agent that
    # stopped reading its mail, which is otherwise indistinguishable from an
    # agent with no mail.
    #
    # @param name [String, nil] one agent, or every agent when nil
    # @return [Array<Agentilda::Mailbox::Message>]
    def unread(name = nil)
      messages.reject(&:read?).select { |m| name.nil? || m.to == name }
    end

    # Append one message and give it the next number.
    #
    # @param from [String]
    # @param to [String]
    # @param body [String]
    # @param at [Time]
    # @return [Agentilda::Mailbox::Message] as written
    # @raise [Agentilda::Error] on an empty body, which would be an entry
    #   with nothing in it for the reader to act on, or on a sender or
    #   recipient that is blank or holds whitespace: a name with a space in
    #   it reads as two agents and matches neither
    def append(from:, to:, body:, at: Time.now)
      text = body.to_s.strip
      raise Error, "a message needs a body" if text.empty?
      raise Error, "a message needs --from and --to, each one agent name" unless name?(from) && name?(to)

      write do |existing|
        message = Message.new(number: (existing.last&.number || 0) + 1,
          at:   at.iso8601,
          from:,
          to:,
          body: text,
          read: UNREAD)
        [existing + [message], message]
      end
    end

    # Mark one message read, on the word of the agent it was addressed to.
    #
    # @param number [Integer]
    # @param by [String] the agent acknowledging
    # @return [Agentilda::Mailbox::Message] as it now stands
    # @raise [Agentilda::Error] when there is no such message, or when it
    #   was addressed to somebody else — an agent acking its partner's mail
    #   would mark read what nobody has read
    def ack(number, by:)
      write do |existing|
        index = existing.index { |m| m.number == number }
        raise Error, "no message ##{number} in #{path}" unless index

        found = existing[index]
        raise Error, "message ##{number} is for #{found.to}, not #{by}" unless found.to == by

        acked = found.with(read: READ)
        [existing.dup.tap { |all| all[index] = acked }, acked]
      end
    end

    # The exchange as a person reads it. Returned, never printed: STDOUT
    # carries the deliverable and this is one.
    #
    # @return [String]
    def render
      entries = messages
      return "#{TITLE}\n\nNothing has been sent.\n" if entries.empty?

      "#{TITLE}\n\n#{entries.join("\n")}"
    end

    private

    # Read, change, write, all under one exclusive lock on one inode.
    #
    # The lock is what stops two agents finishing a unit in the same second
    # from reading the same last number and both writing the one after it.
    # It is taken with `flock`, which the kernel releases when the file
    # descriptor closes, so an agent killed mid-write leaves nothing stuck.
    #
    # The file is truncated and rewritten in place rather than written to a
    # sibling and renamed over: `flock` locks an inode, and a rename gives
    # the path a new one, so a concurrent writer would hold a lock on a file
    # that no longer exists and its message would vanish. {StateFile} may
    # rename because one process writes it; this is written by as many
    # processes as the round has agents.
    #
    # @yieldparam [Array<Agentilda::Mailbox::Message>] what is on disk
    # @yieldreturn [Array(Array<Agentilda::Mailbox::Message>, Object)] what
    #   to write, and what to hand back to the caller
    # @return [Object] the second half of what the block returned
    def write
      File.open(path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        all, result = yield(decode(f.read))
        f.rewind
        f.write(JSON.pretty_generate({ "messages" => all.map(&:to_h) }))
        f.truncate(f.pos)
        result
      end
    end

    # @param value [Object]
    # @return [Boolean] one token, with no whitespace to read as two names
    def name?(value) = value.to_s.match?(/\A\S+\z/)

    # A file that is empty, half-written or not JSON at all reads as no
    # messages rather than raising: the caller is an agent polling between
    # steps, and a crash there costs the round.
    #
    # @param text [String]
    # @return [Array<Agentilda::Mailbox::Message>]
    def decode(text)
      document = JSON.parse(text.to_s)
      return [] unless document.is_a?(Hash) && document["messages"].is_a?(Array)

      document["messages"].filter_map { |entry| message_from(entry) }
    rescue JSON::ParserError
      []
    end

    # @param entry [Object] one element of `messages`
    # @return [Agentilda::Mailbox::Message, nil] nil for anything that is
    #   not an entry, which is dropped rather than raised on, for the same
    #   reason {#decode} tolerates a broken file
    def message_from(entry)
      return nil unless entry.is_a?(Hash) && entry["number"] && entry["from"] && entry["to"]

      Message.new(number: entry["number"].to_i,
        at:   entry["at"].to_s,
        from: entry["from"].to_s,
        to:   entry["to"].to_s,
        body: entry["body"].to_s,
        read: entry["read"] == READ ? READ : UNREAD)
    end
  end
end
