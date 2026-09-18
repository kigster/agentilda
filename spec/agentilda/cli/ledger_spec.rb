# frozen_string_literal: true

# `agentilda ledger sign` is what an agent shells out to instead of editing
# a ledger by hand, so it is exercised the way an agent uses it: against a
# real plan folder, with the entry read back through {Agentilda::Ledger}.
RSpec.describe "agentilda ledger", :tree do
  let!(:folder) do
    path = nil
    plans { |t| path = t.plan "001.00", :building, "paired", files: { "spec.md" => spec_body, "plan.md" => "# P" } }
    path
  end

  let(:reading) { Agentilda::Ledger.read(folder, ["plan.md"]) }

  let(:entry) { reading.entries.first }

  def sign(**)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      Agentilda::CLI::Ledger::Sign.new.call(dir: plans_root, **)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  describe "a Started signature" do
    before { sign(plan: "001.00", agent: "luke-backend", status: "Started", round: "1") }

    it "lands in the document the agent's own definition names" do
      expect(entry.file).to eq("plan.md")
    end

    it "carries the agent, the status and the round" do
      expect(entry).to have_attributes(agent: "luke-backend", status: "Started", round: 1)
    end

    it "renders as a NOTE alert, so it reads as a callout rather than a paragraph" do
      expect(File.read(File.join(folder, "plan.md"))).to include("> [!NOTE]")
    end

    it "says what it did" do
      _out, err, = sign(plan: "001.00", agent: "luke-backend", status: "Completed", round: "1")
      expect(err).to include("luke-backend: Completed, round 1 in plan.md")
    end
  end

  it "keeps the note an agent explains itself with" do
    sign(plan: "001.00", agent: "rey-frontend", status: "Completed", round: "1", note: "no front end")
    expect(entry.note).to eq("no front end")
  end

  it "writes the handoff line under a Completed signature" do
    sign(plan: "001.00", agent: "luke-backend", status: "Completed", round: "1", next: "rey-frontend")
    expect(reading.handoffs.map(&:next)).to eq(["rey-frontend"])
  end

  # A `next:` under anything else is read by the dispatcher as a handoff
  # from an agent that has not finished, which starts the next agent on work
  # that is not on disk yet.
  it "refuses a handoff from an agent that is not signing Completed" do
    _out, err, status = sign(plan: "001.00", agent: "luke-backend", status: "Started", round: "1", next: "rey-frontend")

    aggregate_failures do
      expect(err).to include("--next names who follows a Completed agent")
      expect(status).to eq(64)
    end
  end

  it "signs a document named outright, for an agent run outside its definition" do
    sign(plan: "001.00", agent: "luke-backend", status: "Started", round: "1", file: "spec.md")
    expect(Agentilda::Ledger.read(folder, ["spec.md"]).entries.map(&:agent)).to eq(["luke-backend"])
  end

  it "refuses a plan the tree does not hold, naming the ones it does" do
    _out, err, status = sign(plan: "009", agent: "luke-backend", status: "Started", round: "1")

    aggregate_failures do
      expect(err).to include("No plan 009", "001.00")
      expect(status).to eq(66)
    end
  end

  it "refuses a name no agent definition answers to" do
    _out, err, status = sign(plan: "001.00", agent: "nobody-at-all", status: "Started", round: "1")

    aggregate_failures do
      expect(err).to include("No agent nobody-at-all")
      expect(status).to eq(64)
    end
  end

  # Both halves of a pair sign `plan.md` now, and the harness signs into it
  # too. Read-then-write from two processes loses whichever lands second,
  # and a lost Completed reads as an agent that never finished.
  describe "both halves signing at once" do
    subject(:entries) { reading.entries }

    before do
      folder
      [%w[luke-backend 1], %w[rey-frontend 1], %w[luke-backend 2], %w[rey-frontend 2]]
        .map { |agent, round|
          Thread.new { sign(plan: "001.00", agent:, status: "Started", round:) }
        }
        .each(&:join)
    end

    it "keeps every signature" do
      expect(entries.size).to eq(4)
    end

    it "loses neither half's rounds" do
      expect(entries.map { |e| [e.agent, e.round] }.sort)
        .to eq([["luke-backend", 1], ["luke-backend", 2], ["rey-frontend", 1], ["rey-frontend", 2]])
    end

    it "leaves every line readable, with nothing interleaved mid-entry" do
      expect(reading.problems).to be_empty
    end
  end
end
