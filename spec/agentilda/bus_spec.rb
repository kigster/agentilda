# frozen_string_literal: true

RSpec.describe Agentilda::Bus do
  subject(:bus) { described_class.new(root: "/checkout/one", redis:) }

  let(:redis) { FakeRedis.new }

  let(:payload) { { "kind" => "message", "from" => "luke-backend", "to" => "rey-frontend", "body" => "up" } }

  describe ".key" do
    it "names the plan" do
      expect(described_class.key("/checkout/one", "001.00")).to end_with(":001.00")
    end

    it "is prefixed, so a shared development Redis can be searched and nothing else touched" do
      expect(described_class.key("/checkout/one", "001.00")).to start_with("agentilda:")
    end

    # Ten sessions run at once here. Two worktrees of one repository both
    # running 001.00 would otherwise read each other's mail.
    it "differs between two checkouts running the same plan" do
      expect(described_class.key("/checkout/one", "001.00")).not_to eq(described_class.key("/checkout/two", "001.00"))
    end

    it "is the same for one checkout however its path was spelled" do
      expect(described_class.key("/checkout/one/../one", "001.00")).to eq(described_class.key("/checkout/one", "001.00"))
    end
  end

  describe "#publish" do
    it "returns the id the server minted, which is the reader's watermark" do
      expect(bus.publish("001.00", payload)).to match(/\A\d+-\d+\z/)
    end

    it "puts the entry in this plan's stream" do
      bus.publish("001.00", payload)
      expect(redis.streams[bus.key_for("001.00")].size).to eq(1)
    end

    # The committed JSON is the durable record, so nothing is lost by
    # bounding what the stream still holds.
    it "gives the stream an hour to live" do
      bus.publish("001.00", payload)
      expect(redis.expirations[bus.key_for("001.00")]).to eq(described_class::TTL)
    end
  end

  describe "#drain" do
    before { payload.each_key { nil } }

    it "gives back nothing from a stream nobody has written" do
      expect(bus.drain("001.00")).to be_empty
    end

    it "gives back what was published, decoded" do
      bus.publish("001.00", payload)
      expect(bus.drain("001.00").map(&:last)).to eq([payload])
    end

    it "keeps the order it was written in" do
      3.times { |i| bus.publish("001.00", payload.merge("body" => "m#{i}")) }
      expect(bus.drain("001.00").map { |_id, entry| entry["body"] }).to eq(%w[m0 m1 m2])
    end

    # Without this a reader re-reads its last entry on every poll, and the
    # same message is folded into the file again and again.
    it "excludes the entry the reader already has" do
      bus.publish("001.00", payload)
      expect(bus.drain("001.00", after: bus.drain("001.00").last.first)).to be_empty
    end

    it "reads no other plan's stream" do
      bus.publish("002.00", payload)
      expect(bus.drain("001.00")).to be_empty
    end

    # One stray entry, from an older version or a person with redis-cli,
    # must not cost an agent its round.
    it "gives back nil, not the entry, for one it cannot decode rather than raising" do
      redis.xadd(bus.key_for("001.00"), { "json" => "{not json" })
      bus.publish("001.00", payload)

      expect(bus.drain("001.00").map(&:last)).to eq([nil, payload])
    end

    # A caller folds `drain`'s ids into its own watermark. Omitting a bad
    # entry's id along with its payload would leave the watermark exactly
    # where it was, so the same unreadable entry gets fetched and skipped on
    # every later drain until it ages out of the stream.
    it "keeps the id of an entry it cannot decode, so a caller can still move its watermark past it" do
      redis.xadd(bus.key_for("001.00"), { "json" => "{not json" })

      ids = bus.drain("001.00").map(&:first)
      expect(ids).not_to be_empty
    end
  end

  describe "#reachable?" do
    it "is true when the server answers" do
      expect(bus).to be_reachable
    end

    # Reported once, where somebody can act on it, rather than from inside
    # an agent's thread twenty minutes into a run.
    it "is false when it does not, rather than raising at the caller" do
      expect(described_class.new(root: "/checkout/one", redis: FakeRedis.new(reachable: false))).not_to be_reachable
    end
  end
end
