# frozen_string_literal: true

require "json"

RSpec.describe Agentilda::Mailbox, :tree do
  subject(:mailbox) { described_class.new(dir: folder) }

  let(:folder) do
    path = nil
    plans { |t| path = t.plan "001.00", :building, "paired", files: { "spec.md" => spec_body, "plan.md" => "# P" } }
    path
  end

  let(:document) { JSON.parse(File.read(File.join(folder, described_class::FILENAME))) }

  def luke_to_rey(body) = mailbox.append(from: "luke-backend", to: "rey-frontend", body:)

  def rey_to_luke(body) = mailbox.append(from: "rey-frontend", to: "luke-backend", body:)

  it "is empty before anybody has written" do
    aggregate_failures do
      expect(mailbox).not_to exist
      expect(mailbox.messages).to be_empty
      expect(mailbox.for("luke-backend")).to be_empty
    end
  end

  it "numbers messages from one, in the order they were written" do
    luke_to_rey("The endpoint is up.")
    rey_to_luke("Seen; wiring the screen.")

    expect(mailbox.messages.map { |m| [m.number, m.from, m.to] })
      .to eq([[1, "luke-backend", "rey-frontend"], [2, "rey-frontend", "luke-backend"]])
  end

  describe "the file it writes" do
    before do
      luke_to_rey("first")
      luke_to_rey("second")
    end

    it "is JSON, in named sections, so one can be read without parsing the others" do
      expect(document.keys).to contain_exactly("stream", "messages", "last-known-state")
    end

    it "holds every field a reader needs without parsing prose" do
      expect(document["messages"].first.keys).to contain_exactly("number", "at", "from", "to", "body", "read")
    end

    it "is named mailbox.json in the plan folder" do
      expect(File.basename(mailbox.path)).to eq("mailbox.json")
    end
  end

  # A message is prose. It may carry paragraphs, a heading of its own and
  # code, and all of it has to come back as written or the reader acts on
  # half a sentence.
  describe "a message with paragraphs, a heading and code in it" do
    subject(:read_back) { mailbox.messages.first }

    let(:body) { "Two things.\n\n## Not a message heading\n\n    curl -s /returns/1\n\nThat is all." }
    let!(:written) { luke_to_rey(body) }

    it "comes back exactly as written" do
      aggregate_failures do
        expect(read_back).to eq(written)
        expect(read_back.body).to eq(body)
      end
    end

    it "is stamped in ISO 8601, as the rest of the run's records are" do
      expect(read_back.at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/)
    end
  end

  it "answers a reader with only the messages addressed to them" do
    luke_to_rey("for rey")
    rey_to_luke("for luke")
    luke_to_rey("for rey again")

    expect(mailbox.for("rey-frontend").map(&:body)).to eq(["for rey", "for rey again"])
  end

  it "skips what a reader says they have already seen" do
    luke_to_rey("one")
    luke_to_rey("two")
    luke_to_rey("three")

    expect(mailbox.for("rey-frontend", after: 2).map(&:body)).to eq(["three"])
  end

  it "refuses a message with nothing in it" do
    expect { luke_to_rey("   \n") }.to raise_error(Agentilda::Error, /body/)
  end

  # `dry-cli` does not enforce `required:` on an option, so a send typed
  # without `--to` reached here with nil. The entry it wrote had an empty
  # recipient, which no reader could ever match: written, numbered, and
  # invisible to everybody.
  it "refuses a sender or recipient no reader could match" do
    aggregate_failures do
      expect { mailbox.append(from: "luke-backend", to: nil, body: "x") }.to raise_error(Agentilda::Error, /--to/)
      expect { mailbox.append(from: "", to: "rey-frontend", body: "x") }.to raise_error(Agentilda::Error, /--from/)
      expect { mailbox.append(from: "luke backend", to: "rey-frontend", body: "x") }.to raise_error(Agentilda::Error)
      expect(mailbox).not_to exist
    end
  end

  # Delivery is not reading. Nothing but the recipient may say it read a
  # message, because an agent that stopped reading its mail is otherwise
  # indistinguishable from an agent with no mail.
  describe "#ack" do
    let!(:sent) { luke_to_rey("the endpoint is up") }

    it "starts a message unread" do
      expect(sent).not_to be_read
    end

    it "marks it read on the recipient's word" do
      expect(mailbox.ack(sent.number, by: "rey-frontend")).to be_read
    end

    it "persists that, so the next poll sees it too" do
      mailbox.ack(sent.number, by: "rey-frontend")
      expect(mailbox.messages.first).to be_read
    end

    it "changes nothing else about the message" do
      expect(mailbox.ack(sent.number, by: "rey-frontend").body).to eq("the endpoint is up")
    end

    it "refuses an agent acking mail addressed to its partner" do
      expect { mailbox.ack(sent.number, by: "luke-backend") }.to raise_error(Agentilda::Error, /for rey-frontend/)
    end

    it "refuses a number nobody wrote" do
      expect { mailbox.ack(99, by: "rey-frontend") }.to raise_error(Agentilda::Error, /no message #99/)
    end
  end

  describe "#unread" do
    before do
      luke_to_rey("one")
      luke_to_rey("two")
      rey_to_luke("three")
      mailbox.ack(1, by: "rey-frontend")
    end

    it "counts what one agent has been sent and not acknowledged" do
      expect(mailbox.unread("rey-frontend").map(&:body)).to eq(["two"])
    end

    it "counts the whole plan's when asked for nobody in particular" do
      expect(mailbox.unread.map(&:body)).to eq(["two", "three"])
    end
  end

  describe "#render" do
    subject(:markdown) { mailbox.render }

    it "says so when nothing has been sent" do
      expect(markdown).to include("Nothing has been sent")
    end

    context "with an exchange in it" do
      before do
        luke_to_rey("The endpoint is up.")
        rey_to_luke("Seen.")
        mailbox.ack(1, by: "rey-frontend")
      end

      it "titles the page once" do
        expect(markdown.scan(/^# Mailbox$/).size).to eq(1)
      end

      it "gives each message a numbered heading naming both ends" do
        expect(markdown).to include("luke-backend → rey-frontend", "rey-frontend → luke-backend")
      end

      it "marks what the recipient has not acknowledged" do
        aggregate_failures do
          expect(markdown).to include("## 2 · ", " · unread")
          expect(markdown.scan(/· unread/).size).to eq(1)
        end
      end

      it "carries the bodies through" do
        expect(markdown).to include("The endpoint is up.", "Seen.")
      end
    end
  end

  # An agent polls this file between steps. A crash there costs the round,
  # so a file caught mid-write, or one a person has edited into nonsense,
  # reads as no messages rather than raising.
  describe "a file that is not a mailbox" do
    before { File.write(File.join(folder, described_class::FILENAME), text) }

    context "when it is truncated JSON" do
      let(:text) { '{"messages": [{"number": 1,' }

      it "reads as empty" do
        expect(mailbox.messages).to be_empty
      end
    end

    context "when messages holds something that is not a message" do
      let(:text) { '{"messages": [{"number": 1, "from": "luke-backend", "to": "rey-frontend"}, 7, null]}' }

      it "keeps the entries it can read and drops the rest" do
        expect(mailbox.messages.map(&:number)).to eq([1])
      end
    end

    context "when it is JSON but not an object" do
      let(:text) { "[]" }

      it "reads as empty" do
        expect(mailbox.messages).to be_empty
      end
    end
  end

  # This is what replaces a broker process: any reader may fold the bus
  # into the file, because flock makes the write safe and the watermark
  # makes it idempotent.
  describe "#sync!" do
    let(:redis) { FakeRedis.new }
    let(:bus) { Agentilda::Bus.new(root: plans_root, redis:) }

    let(:payload) do
      { "kind" => "message", "from" => "luke-backend", "to" => "rey-frontend",
        "body" => "the endpoint is up", "at" => Time.now.iso8601 }
    end

    it "folds what the bus carried into the file" do
      bus.publish("001.00", payload)
      mailbox.sync!(bus, "001.00")

      expect(mailbox.messages.map(&:body)).to eq(["the endpoint is up"])
    end

    it "numbers a folded message as if it had been appended" do
      luke_to_rey("written straight in")
      bus.publish("001.00", payload)
      mailbox.sync!(bus, "001.00")

      expect(mailbox.messages.map(&:number)).to eq([1, 2])
    end

    it "folds each entry once, however often it runs" do
      bus.publish("001.00", payload)
      3.times { mailbox.sync!(bus, "001.00") }

      expect(mailbox.messages.size).to eq(1)
    end

    it "says how many it folded, and nothing when there was nothing" do
      bus.publish("001.00", payload)
      aggregate_failures do
        expect(mailbox.sync!(bus, "001.00")).to eq(1)
        expect(mailbox.sync!(bus, "001.00")).to eq(0)
      end
    end

    it "drops an entry with no recipient rather than writing one nobody can read" do
      bus.publish("001.00", payload.merge("to" => ""))
      mailbox.sync!(bus, "001.00")

      expect(mailbox.messages).to be_empty
    end

    # Leaving the watermark where it was would make every later sync read
    # the same unusable entry again, forever.
    it "still moves past an entry it could not use" do
      bus.publish("001.00", { "kind" => "something-later" })
      mailbox.sync!(bus, "001.00")

      expect(mailbox.sync!(bus, "001.00")).to eq(0)
    end

    # Same reasoning, one layer lower: an entry the bus itself could not
    # decode at all still has to move the watermark, or a `PostToolUse`
    # poll re-fetches and re-skips it on every tool call until it expires.
    it "still moves past an entry the bus could not decode" do
      redis.xadd(bus.key_for("001.00"), { "json" => "{not json" })
      mailbox.sync!(bus, "001.00")

      expect(mailbox.sync!(bus, "001.00")).to eq(0)
    end
  end

  # Two writers, and a precedence between them. An agent asked to stop
  # writes the better entry, because it knows what it finished. One killed
  # when the grace period expired writes nothing, and the harness's account
  # is all the next round gets.
  describe "#record_state" do
    it "keeps what an agent says about itself" do
      mailbox.record_state("luke-backend",
        source:    described_class::BY_AGENT,
        round:     1,
        status:    "Interrupted",
        next_step: "wire the dispatcher")

      expect(mailbox.last_known_state.dig("luke-backend", "next_step")).to eq("wire the dispatcher")
    end

    it "stamps who wrote it, so the next round knows what it is reading" do
      mailbox.record_state("luke-backend", source: described_class::BY_HARNESS, round: 1, status: "Interrupted")

      expect(mailbox.last_known_state.dig("luke-backend", "source")).to eq("harness")
    end

    it "lets the harness fill in for an agent that never got to write" do
      mailbox.record_state("rey-frontend",
        source: described_class::BY_HARNESS,
        round:  1,
        status: "Interrupted",
        note:   "harness died")

      expect(mailbox.last_known_state.dig("rey-frontend", "note")).to eq("harness died")
    end

    it "does not let the harness overwrite what the agent said itself" do
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 1, note: "mine")
      mailbox.record_state("luke-backend", source: described_class::BY_HARNESS, round: 1, note: "guessed")

      expect(mailbox.last_known_state.dig("luke-backend", "note")).to eq("mine")
    end

    it "says so when it declined, rather than reporting a write it did not make" do
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 1)

      expect(mailbox.record_state("luke-backend", source: described_class::BY_HARNESS, round: 1)).to be_nil
    end

    it "lets an agent replace the harness's guess with its own account" do
      mailbox.record_state("luke-backend", source: described_class::BY_HARNESS, round: 1, note: "guessed")
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 1, note: "mine")

      expect(mailbox.last_known_state.dig("luke-backend", "note")).to eq("mine")
    end

    it "keeps one entry per agent, the last of them" do
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 1, status: "Interrupted")
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 3, status: "Interrupted")

      expect(mailbox.last_known_state["luke-backend"]["round"]).to eq(3)
    end

    it "leaves the messages alone" do
      luke_to_rey("still here")
      mailbox.record_state("luke-backend", source: described_class::BY_AGENT, round: 1)

      expect(mailbox.messages.map(&:body)).to eq(["still here"])
    end
  end

  # Both halves finish units at their own pace and write when they do. Two
  # appends landing in the same instant used to be able to read the same
  # last number, and one message then carried the other's number.
  describe "both halves writing at once" do
    subject(:messages) { mailbox.messages }

    # `mailbox` is touched here, on this thread, before any other one runs.
    # RSpec memoizes a `let` without a lock, and the fixture under this one
    # builds the plan folder, so two threads arriving at it first is a race
    # this example is not about and would rather not lose to.
    before do
      mailbox.path
      %w[luke-backend rey-frontend]
        .map { |name| Thread.new { 20.times { |i| mailbox.append(from: name, to: "other", body: "#{name} #{i}") } } }
        .each(&:join)
    end

    it "keeps every message" do
      expect(messages.size).to eq(40)
    end

    it "numbers them without a collision" do
      expect(messages.map(&:number)).to eq((1..40).to_a)
    end

    it "loses none of the bodies" do
      expect(messages.map(&:body).uniq.size).to eq(40)
    end
  end
end
