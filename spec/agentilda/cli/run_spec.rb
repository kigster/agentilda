# frozen_string_literal: true

# `agentilda run` is the command that spends money and moves folders, so its
# examples divide sharply: the dry run and the refusals use the real executor
# (which shells nothing out when dry), and every `--commit` example replaces
# {Executor} at its seam so the suite never invokes `claude`.
#
# Everything runs `--isolation shared`: the fixture tree is a bare temp
# directory, not a git repository, and shared mode is the one that needs no
# git — which is itself the first property under test.
RSpec.describe Agentilda::CLI::Run, :tree do
  subject(:command) { described_class.new }

  def run(**options)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      # The log always lands in the example's own temp dir, never in the
      # shared system one where parallel suites would interleave into it.
      command.call(dir: plans_root, isolation: "shared",
                   log: File.join(plans_root, "..", "progress.log"), **options)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def unwrapped(text) = text.tr("║╔╗╚╝═", " ").gsub(/\s+/, " ")

  # 🟡 Building is the cheapest *stable* assignable state: it sits inside a
  # {StateMachine::FAMILIES} group, so the resync each round runs cannot move
  # it on its own. A ⭐️ folder would not do — its contents already best-fit
  # 🟡, so the first round's resync advances it before any agent has run,
  # and every "nothing happened" assertion below would be false.
  def building_plan(ordinal = "001.00", slug = "tax-rule-dsl")
    plans { |t| t.plan(ordinal, :building, slug, files: { "spec.md" => spec_body, "plan.md" => "# Plan" }) }
  end

  # The `--commit` seam. The block sees the subject before answering, so an
  # example can have "the agent" actually change the folder.
  def with_executor(&decide)
    executor = instance_double(Agentilda::Executor)
    allow(executor).to receive(:call) do |_agent, subject, **|
      decide ? decide.call(subject) : [true, "completed"]
    end
    allow(Agentilda::Executor).to receive(:new).and_return(executor)
    executor
  end

  describe "the worktree default against a tree with no git" do
    it "refuses with the alternative spelled out, rather than corrupting later" do
      building_plan
      out = CapturedStream.new
      err = CapturedStream.new
      status = 0

      original_out, original_err = $stdout, $stderr
      $stdout, $stderr = out, err
      begin
        command.call(dir: plans_root)
      rescue SystemExit => e
        status = e.status
      ensure
        $stdout, $stderr = original_out, original_err
      end

      expect(unwrapped(strip_ansi(err.string))).to include("not a git repository", "--isolation shared")
      expect(status).to eq(66)
    end
  end

  describe "a dry run" do
    before { building_plan }

    it "prints which agent would take which plan, and invokes none" do
      out, err, status = run

      expect(out).to include("001.00\tluke-backend\tno change\tdry run — would invoke luke-backend")
      expect(unwrapped(err)).to include("Dry run — no agent was invoked", "--commit")
      expect(status).to eq(0)
    end

    it "spends nothing, so it prints no bill" do
      out, = run

      expect(out).not_to include("tokens")
    end

    it "says where the progress log is going before the loop starts" do
      _out, err, = run

      expect(unwrapped(err)).to include("Progress:")
    end
  end

  describe "--agent" do
    before { building_plan }

    it "narrows the round to the one agent named" do
      out, = run(agent: "luke-backend")

      expect(out).to include("luke-backend")
    end

    it "refuses a name nobody answers to, listing who does" do
      _out, err, status = run(agent: "obi-wan")

      expect(unwrapped(err)).to include("No agent called obi-wan", "luke-backend")
      expect(status).to eq(65)
    end
  end

  describe "--plan" do
    before do
      building_plan
      building_plan("002.00", "schedule-k1")
    end

    it "runs exactly the plans named and no others" do
      out, = run(plan: "002")

      expect(out).to include("002.00")
      expect(out).not_to include("001.00\t")
    end

    # A typo'd number silently running the whole tree is the failure scoping
    # exists to prevent, so an unknown one stops the run outright.
    it "refuses a number the tree does not hold" do
      _out, err, status = run(plan: "002,009")

      expect(unwrapped(err)).to include("No plan 009", "001.00, 002.00")
      expect(status).to eq(66)
    end
  end

  describe "--commit" do
    before { building_plan }

    it "reports each attempt, prints the bill, and exits zero on success" do
      with_executor
      out, err, status = run(commit: true, rounds: 1)

      expect(out).to include("round 1", "001.00\tluke-backend")
      # A committed run spent something, so the tally belongs with the rounds
      # it bills for, on STDOUT, where a redirected run keeps it.
      expect(out).to include("1 round")
      expect(unwrapped(err)).to include("0 advanced")
      expect(status).to eq(0)
    end

    it "shows a plan that actually moved as from -> to" do
      # A ⭐️ folder whose plan.md already exists best-fits 🟡, so the round's
      # own serial resync advances it — which is the property under test: the
      # harness reads the disk after the round rather than trusting what the
      # agent claimed to have done.
      plans { |t| t.plan("002.00", :planned, "moves", files: { "spec.md" => spec_body, "plan.md" => "# Plan" }) }
      with_executor
      out, err, = run(commit: true)

      expect(out).to include("planned -> building")
      expect(unwrapped(err)).to include("1 advanced")
    end

    it "exits non-zero and names the failure when an agent fails" do
      with_executor { [false, "claude exited 1: 401 API key is invalid"] }
      out, err, status = run(commit: true, rounds: 1)

      expect(out).to include("FAIL")
      expect(unwrapped(err)).to include("001.00 luke-backend: claude exited 1: 401 API key is invalid")
      expect(status).to eq(1)
    end

    # The warning has to land before the run, because the failure it predicts
    # arrives three minutes later, once per agent, looking like an agent bug.
    it "warns up front when a credential in the shell will shadow the login" do
      with_executor
      allow(Agentilda::Executor).to receive(:foreign_credentials).and_return(["ANTHROPIC_API_KEY"])
      _out, err, = run(commit: true, rounds: 1)

      expect(unwrapped(err)).to include("ANTHROPIC_API_KEY is set in this shell", "401 API key is invalid")
    end
  end

  describe "worktree isolation with a repository to isolate in" do
    # The real thing shells out to `git worktree add`; the double answers the
    # two questions the command asks — is this a repository, and where does
    # this plan's checkout live — so the wiring to {Publisher} is exercised
    # without git. The checkout is a plain directory, which `dirty?` reads as
    # clean, so the publisher is constructed and then rightly never pushes.
    it "wires a publisher in and labels each attempt with its branch" do
      building_plan
      checkout = Agentilda::Worktree::Checkout.new(
        ordinal: Agentilda::Ordinal.parse("001.00"), branch: "kig/001.00-tax-rule-dsl",
        path: plans_root, created: true,
      )
      worktree = instance_double(Agentilda::Worktree, repository?: true, checkout_for: checkout)
      allow(Agentilda::Worktree).to receive(:new).and_return(worktree)

      out, err, status = run(isolation: "worktree")

      expect(out).to include("(kig/001.00-tax-rule-dsl)")
      expect(unwrapped(err)).to include("one worktree each")
      expect(status).to eq(0)
    end
  end

  describe "a tree with nothing an agent may touch" do
    it "declares the fixed point when every plan is settled" do
      plans { |t| t.plan("001.00", :approved, "shipped", prs: [t.merged(2, "Ship it")]) }
      _out, err, status = run(commit: true)

      expect(unwrapped(err)).to include("Every plan is done or deliberately parked")
      expect(status).to eq(0)
    end

    # ⭕️ is stepped around, never assigned — and stepping around in silence
    # would leave the human unaware they are the bottleneck.
    it "names the plans waiting on a human, with the unblock line to type" do
      plans { |t| t.plan("001.00", :blocked, "stuck", files: { "blocked.md" => "# Blocked\n\n## B1. Which vendor\n" }) }
      _out, err, = run

      expect(unwrapped(err)).to include("1 plan need", "agentilda unblock 001.00 --commit")
    end
  end
end
