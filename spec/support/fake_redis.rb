# frozen_string_literal: true

# The four commands {Agentilda::Bus} uses, in memory.
#
# The suite never opens a socket, so this stands in for the real client at
# the one place a client is built, {Agentilda::Bus.client}. It is not a
# double: it keeps entries, mints ids that sort the way Redis's do, and
# honours `XRANGE`'s exclusive `(` prefix, because the bus's idempotence
# rests on exactly that and a double that returned whatever it was told
# would prove nothing about it.
class FakeRedis
  # @return [Hash{String => Array<Array(String, Hash)>}] entries by key
  attr_reader :streams

  # @return [Hash{String => Integer}] the TTL last set on each key
  attr_reader :expirations

  # @param reachable [Boolean] false makes #ping raise, as an absent server
  #   does
  def initialize(reachable: true)
    @reachable = reachable
    @streams = Hash.new { |h, k| h[k] = [] }
    @expirations = {}
    @sequence = 0
  end

  # @return [String] "PONG"
  def ping
    raise Errno::ECONNREFUSED, "no server" unless @reachable

    "PONG"
  end

  # Ids are `<milliseconds>-<sequence>`, and the sequence is padded so that
  # a plain string sort matches Redis's ordering past nine entries.
  #
  # @return [String] the id minted
  def xadd(key, fields)
    @sequence += 1
    id = "#{Time.now.to_i * 1000}-#{format("%06d", @sequence)}"
    @streams[key] << [id, fields.transform_keys(&:to_s)]
    id
  end

  # @param start [String] an id, or one prefixed `(` for "after this"
  # @param finish [String] "+" for the end, which is all this bus asks for
  # @return [Array<Array(String, Hash)>]
  def xrange(key, start = "-", _finish = "+")
    exclusive = start.start_with?("(")
    from = exclusive ? start[1..] : start
    @streams[key].select do |id, _fields|
      next true if ["-", Agentilda::Bus::BEGINNING].include?(from)

      exclusive ? id > from : id >= from
    end
  end

  # @param minimum [Integer] milliseconds; entries older than this go
  # @return [Integer] how many were dropped
  def xtrim(key, minimum, strategy: "MINID")
    raise ArgumentError, "only MINID is used" unless strategy == "MINID"

    before = @streams[key].size
    @streams[key] = @streams[key].select { |id, _| id.split("-").first.to_i >= minimum }
    before - @streams[key].size
  end

  # @return [Boolean]
  def expire(key, seconds)
    @expirations[key] = seconds
    true
  end
end
