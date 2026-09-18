# frozen_string_literal: true

require "digest"
require "json"

module Agentilda
  # What carries a message out of a `claude -p` process.
  #
  # An agent is its own process, so the only things it can reach are the
  # filesystem and the network. The plan's `mailbox.json` is the durable
  # record and always will be; this is the transport that lets the harness,
  # and the partner, learn about a message in the second it was written
  # rather than whenever somebody next reads the file.
  #
  # **Streams, not pub/sub.** `PUBLISH` to a channel nobody is subscribed to
  # discards the message silently — no error, no queue — so a harness that
  # was restarting would lose whatever was sent in that window and nothing
  # anywhere would say so. A stream keeps what was added until it is
  # trimmed, can be read from any point, and can be replayed.
  #
  # Redis is required rather than optional. A run that degrades silently to
  # no transport looks exactly like a run where nobody had anything to say.
  class Bus
    # Prefix on every key, so a `KEYS agentilda:*` finds all of them and
    # nothing else on a shared development Redis is touched.
    NAMESPACE = "agentilda"

    # How long a message stays in the stream. The committed JSON is the
    # durable record, so nothing is lost by trimming; this only bounds what
    # a reader may still replay.
    TTL = 3600

    # Cells of the checkout digest in a key. Enough that two of this repo's
    # worktrees do not collide, short enough to read in `redis-cli`.
    DIGEST_LENGTH = 12

    # Where the last read stopped, for a reader that wants only what is new.
    # `0-0` is before every entry Redis will ever mint.
    BEGINNING = "0-0"

    class << self
      # The one place a client is built, so every other caller takes one as
      # an argument and the suite never opens a socket.
      #
      # @param url [String, nil] `$REDIS_URL`, or Redis's own default
      # @return [Redis]
      def client(url = ENV.fetch("REDIS_URL", nil))
        require "redis"
        url ? Redis.new(url:) : Redis.new
      end

      # @param root [String] the checkout this run is working in
      # @param ordinal [String, Agentilda::Ordinal]
      # @return [String] the stream key for one plan
      #
      # The checkout is in the key, not just the plan number. Ten sessions
      # run at once here, and two worktrees of one repository both running
      # `001.00` would otherwise read each other's mail.
      def key(root, ordinal)
        digest = Digest::SHA256.hexdigest(File.expand_path(root.to_s))[0, DIGEST_LENGTH]
        "#{NAMESPACE}:#{digest}:#{ordinal}"
      end
    end

    # @param root [String] the checkout this run is working in
    # @param redis [Redis, #xadd] a client, or anything answering the four
    #   commands used here; the suite passes a fake and never reaches a
    #   socket
    def initialize(root:, redis: self.class.client)
      @root = root
      @redis = redis
    end

    # @return [String]
    attr_reader :root

    # @param ordinal [String]
    # @return [String] this plan's stream key
    def key_for(ordinal) = self.class.key(root, ordinal)

    # Add one entry, then trim what has aged out.
    #
    # @param ordinal [String]
    # @param payload [Hash] anything JSON can carry
    # @return [String] the entry id Redis minted
    def publish(ordinal, payload)
      key = key_for(ordinal)
      id = @redis.xadd(key, { "json" => JSON.generate(payload) })
      trim(key)
      id
    end

    # What is in the stream after a given id.
    #
    # Every entry is returned, even one {#decode} could not make sense of —
    # with `nil` standing in for its payload — so the caller's watermark
    # moves over it. Dropping a malformed entry outright would leave the
    # watermark exactly where it was, and every poll after would re-fetch
    # and re-skip the same entry until it aged out of the stream.
    #
    # @param ordinal [String]
    # @param after [String] an id from a previous read, or {BEGINNING}
    # @return [Array<Array(String, Hash, nil)>] each id with its decoded
    #   payload, or nil for an entry {#decode} discarded
    def drain(ordinal, after: BEGINNING)
      @redis.xrange(key_for(ordinal), exclusive(after), "+").map do |id, fields|
        [id, decode(fields)]
      end
    end

    # Whether the server is actually there. Called once at the start of a
    # run so the failure is reported where somebody can act on it, rather
    # than from inside an agent's thread twenty minutes later.
    #
    # @return [Boolean]
    def reachable?
      @redis.ping
      true
    rescue StandardError
      false
    end

    private

    # `XRANGE` is inclusive at both ends, and Redis 6.2 reads a `(` prefix
    # as "after this one". Without it a reader re-reads the last entry it
    # already has on every poll.
    #
    # @param id [String]
    # @return [String]
    def exclusive(id) = id == BEGINNING ? id : "(#{id}"

    # Trimming by id rather than by length: an hour of history is the rule,
    # and a plan with two messages should not keep them forever while a
    # chatty one drops yesterday's.
    #
    # @param key [String]
    # @return [void]
    def trim(key)
      @redis.xtrim(key, (Time.now.to_i - TTL) * 1000, strategy: "MINID")
      @redis.expire(key, TTL)
    end

    # An entry written by something other than {#publish} is skipped rather
    # than raised on. A reader here is an agent polling between steps, and
    # one stray entry must not cost it the round.
    #
    # @param fields [Hash]
    # @return [Hash, nil]
    def decode(fields)
      raw = fields["json"] or return nil
      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end
