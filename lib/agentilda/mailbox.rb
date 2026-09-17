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

    # Written by the reader, never by delivery. A stream's own ack says the
    # bytes arrived; only the agent can say it read them.
    READ = "yes"
    UNREAD = "no"

    # The document's three sections. `stream` is the id of the last bus
    # entry folded in, which is what makes {#sync!} idempotent: two
    # processes draining the same stream write the same messages once.
    MESSAGES = "messages"
    STATE = "last-known-state"
    STREAM = "stream"

    # What {#sync!} does with a payload, by its `kind`.
    MESSAGE_KIND = "message"
    STATE_KIND = "state"

    # Who wrote a {STATE} entry. An agent's own account of where it got to
    # always wins; the harness fills in for one that never got to write.
    BY_AGENT = "agent"
    BY_HARNESS = "harness"

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
    def messages = decode_messages(document)

    # The whole file, with every section present whether or not it has been
    # written yet, so no caller has to test for a missing key.
    #
    # @return [Hash]
    def document
      return blank unless exist?

      normalize(JSON.parse(File.read(path, encoding: "UTF-8")))
    rescue JSON::ParserError
      blank
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

    # Where each agent on this plan got to, as last recorded.
    #
    # @return [Hash{String => Hash}] keyed by agent name, last write wins
    def last_known_state = document[STATE]

    # Record where one agent got to, for the round that picks the plan up.
    #
    # Two writers, and a precedence between them. An agent interrupted
    # cleanly writes its own entry, which is the better one: it knows what
    # it finished and what the next step is. An agent that was terminated
    # when the grace period expired, or that died outright, writes nothing,
    # and the harness fills in from what it watched. So a harness entry
    # never displaces an agent's, and an agent's always displaces whatever
    # is there.
    #
    # @param agent [String]
    # @param source [String] {BY_AGENT} or {BY_HARNESS}
    # @param fields [Hash] round, status, done, remaining, next_step, note
    # @return [Hash, nil] what now stands for that agent, or nil when a
    #   harness entry was declined in favour of the agent's own
    def record_state(agent, source:, at: Time.now, **fields)
      write do |doc|
        held = doc[STATE][agent.to_s]
        if source == BY_HARNESS && held && held["source"] == BY_AGENT
          [doc, nil]
        else
          entry = { "source" => source, "at" => at.iso8601 }.merge(fields.transform_keys(&:to_s))
          [doc.merge(STATE => doc[STATE].merge(agent.to_s => entry)), entry]
        end
      end
    end

    # Fold everything the bus has carried since the last sync into the file.
    #
    # This is what replaces a broker process. Any number of readers may run
    # it — the harness thread once a second, and whoever is about to read
    # the file — because `flock` makes the write safe and the {STREAM}
    # watermark makes it idempotent. A message is therefore never lost to
    # nobody-was-listening, which is the failure a published-and-forgotten
    # transport has and a stream does not.
    #
    # @param bus [Agentilda::Bus]
    # @param ordinal [String]
    # @return [Integer] how many entries were folded in
    def sync!(bus, ordinal)
      drained = bus.drain(ordinal, after: document[STREAM])
      return 0 if drained.empty?

      write do |doc|
        folded = drained.reduce(doc) { |carry, (id, payload)| fold(carry, id, payload) }
        [folded, drained.size]
      end
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

      write do |doc|
        message = next_message(doc, from:, to:, body: text, at: at.iso8601)
        [add(doc, message), message]
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
      write do |doc|
        existing = decode_messages(doc)
        index = existing.index { |m| m.number == number }
        raise Error, "no message ##{number} in #{path}" unless index

        found = existing[index]
        raise Error, "message ##{number} is for #{found.to}, not #{by}" unless found.to == by

        acked = found.with(read: READ)
        [doc.merge(MESSAGES => existing.dup.tap { |all| all[index] = acked }.map(&:to_h)), acked]
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
    # @yieldparam [Hash] the document on disk, with every section present
    # @yieldreturn [Array(Hash, Object)] what to write, and what to hand
    #   back to the caller
    # @return [Object] the second half of what the block returned
    def write
      File.open(path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        text = f.read
        doc, result = yield(parse_or_blank(text))
        f.rewind
        f.write(JSON.pretty_generate(doc))
        f.truncate(f.pos)
        result
      end
    end

    # @return [Hash] an empty document, every section present
    def blank = { STREAM => Bus::BEGINNING, MESSAGES => [], STATE => {} }

    # @param text [String]
    # @return [Hash]
    def parse_or_blank(text)
      normalize(JSON.parse(text.to_s))
    rescue JSON::ParserError
      blank
    end

    # A file half-written, or edited by hand into something else, gives back
    # whichever sections still make sense and blanks the rest. The caller is
    # an agent polling between steps, and a crash there costs the round.
    #
    # @param parsed [Object]
    # @return [Hash]
    def normalize(parsed)
      return blank unless parsed.is_a?(Hash)

      { STREAM   => parsed[STREAM].is_a?(String) ? parsed[STREAM] : Bus::BEGINNING,
        MESSAGES => parsed[MESSAGES].is_a?(Array) ? parsed[MESSAGES] : [],
        STATE    => parsed[STATE].is_a?(Hash) ? parsed[STATE] : {} }
    end

    # @param doc [Hash]
    # @return [Array<Agentilda::Mailbox::Message>]
    def decode_messages(doc) = doc[MESSAGES].filter_map { |entry| message_from(entry) }

    # @return [Agentilda::Mailbox::Message]
    def next_message(doc, from:, to:, body:, at:)
      Message.new(number: (decode_messages(doc).last&.number || 0) + 1, at:, from:, to:, body:, read: UNREAD)
    end

    # @return [Hash] the document with one more message in it
    def add(doc, message) = doc.merge(MESSAGES => doc[MESSAGES] + [message.to_h])

    # One bus entry, folded into the document. The watermark moves whatever
    # the payload turned out to be, including a kind this version does not
    # know: leaving it would make every later sync re-read it forever.
    #
    # @param doc [Hash]
    # @param id [String] the entry's stream id
    # @param payload [Hash]
    # @return [Hash]
    def fold(doc, id, payload)
      moved = doc.merge(STREAM => id)
      case payload["kind"]
      when MESSAGE_KIND then fold_message(moved, payload)
      when STATE_KIND then fold_state(moved, payload)
      else moved
      end
    end

    # @return [Hash]
    def fold_message(doc, payload)
      return doc unless name?(payload["from"]) && name?(payload["to"]) && !payload["body"].to_s.strip.empty?

      add(doc,
        next_message(doc,
          from: payload["from"].to_s,
          to:   payload["to"].to_s,
          body: payload["body"].to_s.strip,
          at:   payload["at"].to_s))
    end

    # @return [Hash]
    def fold_state(doc, payload)
      agent = payload["agent"].to_s
      return doc unless name?(agent)

      held = doc[STATE][agent]
      return doc if payload["source"] == BY_HARNESS && held && held["source"] == BY_AGENT

      doc.merge(STATE => doc[STATE].merge(agent => payload.except("kind", "agent")))
    end

    # @param value [Object]
    # @return [Boolean] one token, with no whitespace to read as two names
    def name?(value) = value.to_s.match?(/\A\S+\z/)

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
