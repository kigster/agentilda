# frozen_string_literal: true

# `agentilda mail` is what a paired agent shells out to between steps, so
# the two commands are exercised the way an agent uses them: one sends, the
# other reads, against a real plan folder.
RSpec.describe "agentilda mail", :tree do
  # The one place a client is built, so nothing here opens a socket. The
  # fake keeps entries and mints ordered ids, because what these examples
  # are really testing is that a send reaches the file through the bus.
  let(:redis) { FakeRedis.new }
  let!(:folder) do
    path = nil
    plans { |t| path = t.plan "001.00", :building, "paired", files: { "spec.md" => spec_body, "plan.md" => "# P" } }
    path
  end

  before { allow(Agentilda::Bus).to receive(:client).and_return(redis) }

  def run(command, **)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      command.call(dir: plans_root, **)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def send(**) = run(Agentilda::CLI::Mail::Send.new, **)

  def read(**) = run(Agentilda::CLI::Mail::Read.new, **)

  def ack(**) = run(Agentilda::CLI::Mail::Ack.new, **)

  def render(**) = run(Agentilda::CLI::Mail::Render.new, **)

  def poll(**) = run(Agentilda::CLI::Mail::Poll.new, **)

  def state(**) = run(Agentilda::CLI::Mail::State.new, **)

  it "delivers a message from one half to the other" do
    _out, err, status = send(body: "GET /returns/:id is up", plan: "001.00", from: "luke-backend", to: "rey-frontend")
    out, = read(plan: "001.00", for: "rey-frontend")

    aggregate_failures do
      expect(status).to eq(0)
      expect(err).to include("#1 → rey-frontend")
      expect(out).to include("luke-backend → rey-frontend", "GET /returns/:id is up")
    end
  end

  it "writes JSON into the plan's own folder, for the next poll to read without parsing prose" do
    send(body: "hello", plan: "001", from: "luke-backend", to: "rey-frontend")

    expect(JSON.parse(File.read(File.join(folder, "mailbox.json"))).dig("messages", 0))
      .to include("number" => 1, "body" => "hello", "read" => "no")
  end

  it "shows a reader nothing that was addressed to somebody else" do
    send(body: "for rey", plan: "001.00", from: "luke-backend", to: "rey-frontend")
    out, err, status = read(plan: "001.00", for: "luke-backend")

    aggregate_failures do
      expect(out).to be_empty
      expect(err).to include("Nothing for luke-backend")
      expect(status).to eq(0)
    end
  end

  it "shows only what arrived after the number the reader last saw" do
    3.times { |i| send(body: "message #{i + 1}", plan: "001.00", from: "luke-backend", to: "rey-frontend") }
    out, = read(plan: "001.00", for: "rey-frontend", after: "2")

    aggregate_failures do
      expect(out).to include("message 3")
      expect(out).not_to include("message 1", "message 2")
    end
  end

  # A poll that finds nothing is the ordinary case, not a failure: the
  # command is run before every significant step.
  it "prints nothing and exits zero before anybody has written" do
    out, _err, status = read(plan: "001.00", for: "rey-frontend")

    aggregate_failures do
      expect(out).to be_empty
      expect(status).to eq(0)
    end
  end

  it "refuses a plan the tree does not hold, naming the ones it does" do
    _out, err, status = send(body: "hello", plan: "009", from: "luke-backend", to: "rey-frontend")

    aggregate_failures do
      expect(err).to include("No plan 009", "001.00")
      expect(status).to eq(66)
    end
  end

  it "refuses a send with no recipient, rather than writing an entry nobody can read" do
    _out, err, status = send(body: "hello", plan: "001.00", from: "luke-backend")

    aggregate_failures do
      expect(err).to include("--to")
      expect(status).to eq(64)
      expect(File).not_to exist(File.join(folder, "mailbox.json"))
    end
  end

  # Redis is the transport, not the record. What proves a send worked is
  # that it came back out of the file the partner reads.
  it "carries the message out through the bus" do
    send(body: "the endpoint is up", plan: "001.00", from: "luke-backend", to: "rey-frontend")

    expect(redis.streams.values.flatten(1).size).to eq(1)
  end

  it "names the stream after the checkout as well as the plan, so two worktrees do not cross" do
    send(body: "hello", plan: "001.00", from: "luke-backend", to: "rey-frontend")

    expect(redis.streams.keys.first).to eq(Agentilda::Bus.key(plans_root, "001.00"))
  end

  # A stream keeps what was added, so a reader that was not there when the
  # message was sent still gets it. This is the failure pub/sub has and a
  # stream does not.
  it "folds an entry nobody was there for into the file at the next read" do
    Agentilda::Bus.new(root: plans_root, redis:)
                  .publish("001.00",
                    { "kind" => "message", "from" => "luke-backend",
                                                           "to" => "rey-frontend", "body" => "sent while nobody listened",
                                                           "at" => Time.now.iso8601 })
    out, = read(plan: "001.00", for: "rey-frontend")

    expect(out).to include("sent while nobody listened")
  end

  it "folds each entry in once, however many times it is read" do
    send(body: "once", plan: "001.00", from: "luke-backend", to: "rey-frontend")
    3.times { read(plan: "001.00", for: "rey-frontend") }

    expect(JSON.parse(File.read(File.join(folder, "mailbox.json")))["messages"].size).to eq(1)
  end

  it "refuses to pretend when Redis is not there" do
    allow(Agentilda::Bus).to receive(:client).and_return(FakeRedis.new(reachable: false))
    _out, err, status = send(body: "hello", plan: "001.00", from: "luke-backend", to: "rey-frontend")

    aggregate_failures do
      expect(err).to include("Redis is not answering")
      expect(status).to eq(69)
    end
  end

  it "refuses an empty message" do
    _out, err, status = send(body: "  ", plan: "001.00", from: "luke-backend", to: "rey-frontend")

    aggregate_failures do
      expect(err).to include("body")
      expect(status).to eq(64)
    end
  end

  # An agent asked to stop used to leave prose the next round had to read
  # and believe. This is the same thing in fields, which the next round can
  # check against the files it names.
  describe "state" do
    subject(:recorded) do
      JSON.parse(File.read(File.join(folder, "mailbox.json"))).dig("last-known-state", "luke-backend")
    end

    before do
      state(plan: "001.00",
        agent: "luke-backend",
        round: "2",
        status: "Interrupted",
        done: "schema; specs green",
        remaining: "wire the dispatcher",
        next_step: "bundle exec rspec spec/agentilda/ledger_spec.rb")
    end

    it "records what the agent finished, as a list rather than a sentence" do
      expect(recorded["done"]).to eq(["schema", "specs green"])
    end

    it "records what it did not" do
      expect(recorded["remaining"]).to eq(["wire the dispatcher"])
    end

    it "records the exact next thing to do" do
      expect(recorded["next_step"]).to eq("bundle exec rspec spec/agentilda/ledger_spec.rb")
    end

    it "records which round it was cut off in" do
      expect(recorded["round"]).to eq(2)
    end

    # The precedence: the harness only fills in for an agent that never got
    # this far, and must not overwrite one that did.
    it "is marked as the agent's own, which beats anything the harness writes" do
      aggregate_failures do
        expect(recorded["source"]).to eq("agent")
        expect(Agentilda::Mailbox.new(dir: folder).record_state("luke-backend",
          source: Agentilda::Mailbox::BY_HARNESS,
          round:  2)).to be_nil
      end
    end

    it "leaves the messages alone" do
      expect(JSON.parse(File.read(File.join(folder, "mailbox.json")))["messages"]).to be_empty
    end
  end

  # A hook runs this after every one of an agent's tool calls, so it is
  # subordinate to not disrupting the agent: little output, and never a
  # failure, whatever is wrong underneath.
  describe "poll" do
    it "says nothing when there is nothing waiting" do
      out, _err, status = poll(plan: "001.00", for: "luke-backend")

      aggregate_failures do
        expect(out).to be_empty
        expect(status).to eq(0)
      end
    end

    it "names what is unread, and tells the agent to acknowledge it" do
      send(body: "the endpoint is up", plan: "001.00", from: "luke-backend", to: "rey-frontend")
      out, = poll(plan: "001.00", for: "rey-frontend")

      expect(out).to include("1 unread", "#1 from luke-backend", "the endpoint is up", "acknowledge")
    end

    it "stops naming a message once its recipient has acknowledged it" do
      send(body: "seen already", plan: "001.00", from: "luke-backend", to: "rey-frontend")
      ack(number: 1, plan: "001.00", by: "rey-frontend")
      out, = poll(plan: "001.00", for: "rey-frontend")

      expect(out).to be_empty
    end

    it "keeps to one line each, whatever the message is" do
      send(body: "first line\n\nand a great deal more prose after it",
        plan: "001.00",
        from: "luke-backend",
        to: "rey-frontend")
      out, = poll(plan: "001.00", for: "rey-frontend")

      aggregate_failures do
        expect(out.lines.last).to include("first line")
        expect(out).not_to include("great deal")
      end
    end

    it "shows at most the limit it was given, keeping the newest" do
      3.times { |i| send(body: "m#{i}", plan: "001.00", from: "luke-backend", to: "rey-frontend") }
      out, = poll(plan: "001.00", for: "rey-frontend", limit: "2")

      aggregate_failures do
        expect(out).to include("m1", "m2")
        expect(out).not_to include("m0")
      end
    end

    # A hook that raises breaks each of an agent's steps rather than one of
    # them, so nothing here may escape.
    it "stays quiet and exits zero when Redis is gone" do
      allow(Agentilda::Bus).to receive(:client).and_return(FakeRedis.new(reachable: false))
      out, _err, status = poll(plan: "001.00", for: "rey-frontend")

      aggregate_failures do
        expect(out).to be_empty
        expect(status).to eq(0)
      end
    end

    it "stays quiet and exits zero for a plan that is not there" do
      out, _err, status = poll(plan: "009", for: "rey-frontend")

      aggregate_failures do
        expect(out).to be_empty
        expect(status).to eq(0)
      end
    end
  end

  # Delivery is not reading. The recipient says so itself, in its own call,
  # because nothing else on the machine can honestly say it.
  describe "ack" do
    before { send(body: "the endpoint is up", plan: "001.00", from: "luke-backend", to: "rey-frontend") }

    it "marks the message read on the recipient's word" do
      _out, err, status = ack(number: 1, plan: "001.00", by: "rey-frontend")

      aggregate_failures do
        expect(status).to eq(0)
        expect(err).to include("#1 read by rey-frontend")
        expect(JSON.parse(File.read(File.join(folder, "mailbox.json"))).dig("messages", 0, "read")).to eq("yes")
      end
    end

    it "refuses an agent acking its partner's mail" do
      _out, err, status = ack(number: 1, plan: "001.00", by: "luke-backend")

      aggregate_failures do
        expect(err).to include("for rey-frontend")
        expect(status).to eq(64)
      end
    end

    it "refuses a number nobody wrote" do
      _out, err, status = ack(number: 9, plan: "001.00", by: "rey-frontend")

      aggregate_failures do
        expect(err).to include("no message #9")
        expect(status).to eq(64)
      end
    end
  end

  # The mailbox is JSON so an agent does no parsing; this is the other half
  # of that trade, and it goes to STDOUT because STDOUT carries whatever is
  # being asked for.
  describe "render" do
    before do
      send(body: "the endpoint is up", plan: "001.00", from: "luke-backend", to: "rey-frontend")
      send(body: "seen", plan: "001.00", from: "rey-frontend", to: "luke-backend")
    end

    it "prints the exchange as Markdown" do
      out, _err, status = render(plan: "001.00")

      aggregate_failures do
        expect(status).to eq(0)
        expect(out).to include("# Mailbox", "## 1 · ", "luke-backend → rey-frontend", "the endpoint is up", "seen")
      end
    end

    it "says so when nothing has been sent" do
      plans { |t| t.plan "002.00", :building, "quiet", files: { "spec.md" => spec_body, "plan.md" => "# P" } }
      out, = render(plan: "002.00")

      expect(out).to include("Nothing has been sent")
    end
  end
end
