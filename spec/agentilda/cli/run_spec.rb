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

  # A suite run from a terminal must never have the listener put that
  # terminal into raw mode and eat the developer's keys byte by byte.
  before { allow(Agentilda::Keyboard).to receive(:listen).and_return(nil) }

  # The loop sleeps a second between ticks. Every example hands the runner
  # the no-op sleeper runner_spec uses, or each `--commit` example is two
  # seconds of waiting for nothing. The same spy serves the --rounds examples.
  before do
    allow(Agentilda::Runner).to receive(:new).and_wrap_original do |original, **keywords|
      original.call(**keywords, sleeper: ->(_) {})
    end
  end

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
    plans { |t| t.plan(ordinal, :building, slug, files: {"spec.md" => spec_body, "plan.md" => "# Plan"}) }
  end

  # The `--commit` seam. The block sees the subject and the agent before
  # answering, so an example can have "the agent" actually change the folder
  # and sign its own ledger. It answers `[ok, note]`, wrapped here into the
  # {Agentilda::Executor::Result} the dispatcher reads.
  def with_executor(&decide)
    executor = instance_double(Agentilda::Executor)
    allow(executor).to receive(:call) do |agent, subject, **|
      ok, note = decide ? decide.call(subject, agent) : [true, "completed"]
      Agentilda::Executor::Result.new(ok:, note:, up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
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

  describe "--timeout and the config file" do
    before { building_plan }

    it "hands --timeout to the executor" do
      with_executor
      run(commit: true, timeout: "1800")

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(timeout: 1800))
    end

    it "reads the default timeout from ~/.local/config/agentilda.json" do
      allow(Agentilda::Config).to receive(:for).with(:run).and_return(timeout: 2400)
      with_executor
      run(commit: true)

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(timeout: 2400))
    end

    it "lets the typed flag beat the config file" do
      allow(Agentilda::Config).to receive(:for).with(:run).and_return(timeout: 2400)
      with_executor
      run(commit: true, timeout: "600")

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(timeout: 600))
    end

    # The executor falls back to 900 only for an agent with no clock of its
    # own; a flag defaulting to 900 here silently cut every longer agent.
    it "leaves each agent to its own clock when neither names one" do
      with_executor
      run(commit: true)

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(timeout: nil))
    end

    it "refuses an unreadable config file rather than silently ignoring it" do
      allow(Agentilda::Config).to receive(:for)
        .and_raise(Agentilda::Error, "config.json is not valid JSON")
      _out, err, status = run

      expect(unwrapped(err)).to include("not valid JSON")
      expect(status).to eq(66)
    end
  end

  describe "--rounds" do
    before { building_plan }

    it "reaches the runner as a cap on every agent's own rounds" do
      run(rounds: 1)

      expect(Agentilda::Runner).to have_received(:new).with(hash_including(rounds: 1))
    end

    it "leaves each agent to its own count when none is given" do
      run

      expect(Agentilda::Runner).to have_received(:new).with(hash_including(rounds: nil))
    end
  end

  describe "a dry run" do
    before { building_plan }

    it "prints which agent would take which plan, and invokes none" do
      out, err, status = run

      expect(out).to include("001.00\tluke-backend\t[R:1]\tno change\tdry run - would invoke luke-backend")
      expect(unwrapped(err)).to include("Dry run — no agent was invoked", "--commit")
      expect(status).to eq(0)
    end

    it "spends nothing, so it prints no bill" do
      out, = run

      expect(out).not_to include("tokens")
    end

    # The per-round resync used to run with commit: true even here, so a
    # "dry" run renamed a ⭐️ folder whose plan.md already existed. A preview
    # that moves folders is not a preview.
    it "renames nothing, even a folder the resync would promote" do
      plans { |t| t.plan("002.00", :planned, "stays-put", files: {"spec.md" => spec_body, "plan.md" => "# Plan"}) }
      run

      expect(Dir.children(plans_root).grep(/stays-put/)).to eq(["002.00-⭐️ → stays-put"])
    end

    it "says where the progress log is going before the loop starts" do
      _out, err, = run

      expect(unwrapped(err)).to include("Progress:")
    end
  end

  describe "--agent" do
    before { building_plan }

    it "narrows the round to the one agent named, leaving other states unassigned" do
      plans { |t| t.plan("003.00", :new, "raw-idea", files: {"spec.md" => spec_body}) }
      out, = run(agent: "luke-backend")

      expect(out).to include("luke-backend")
      expect(out).not_to include("leah-researcher")
    end

    it "refuses a name nobody answers to, listing who does" do
      _out, err, status = run(agent: "obi-wan")

      expect(unwrapped(err)).to include("No agent called obi-wan", "luke-backend")
      expect(status).to eq(65)
    end

    # The bug this kills: `--agent palpatine-planner --plan NNN` on a plan in
    # a state palpatine does not handle produced an empty round, a green box
    # and exit 0 — a silent no-op wearing a success. The pairing that cannot
    # happen is now refused up front, naming who would take the plan.
    it "refuses an agent that handles no in-scope plan's state, naming who does" do
      _out, err, status = run(agent: "leah-researcher")

      expect(unwrapped(err)).to include("leah-researcher handles", "🟡 Building", "luke-backend and rey-frontend take it")
      expect(status).to eq(65)
    end
  end

  describe "--max-tokens" do
    before { building_plan }

    it "hands the budget to the executor" do
      with_executor
      run(commit: true, max_tokens: "50000")

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(max_tokens: 50_000))
    end

    it "reads a default budget from the config file" do
      allow(Agentilda::Config).to receive(:for).with(:run).and_return(max_tokens: 80_000)
      with_executor
      run(commit: true)

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(max_tokens: 80_000))
    end

    it "meters nothing when neither names a budget" do
      with_executor
      run(commit: true)

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(max_tokens: nil))
    end
  end

  describe "--prompt" do
    before { building_plan }

    it "hands the extra instructions to the executor, alongside --agent" do
      with_executor
      run(commit: true, agent: "luke-backend", prompt: "Focus on the parser")

      expect(Agentilda::Executor).to have_received(:new)
        .with(hash_including(instructions: "Focus on the parser"))
    end

    # Without the restriction the steer would reach every agent in the round,
    # which is never what a sentence aimed at one specialist means.
    it "refuses --prompt without --agent" do
      _out, err, status = run(prompt: "Focus on the parser")

      expect(unwrapped(err)).to include("--prompt only works with --agent")
      expect(status).to eq(64)
    end
  end

  describe "--model" do
    before { building_plan }

    it "hands the override to the executor" do
      with_executor
      run(commit: true, model: "opus")

      expect(Agentilda::Executor).to have_received(:new).with(hash_including(model: "opus"))
    end
  end

  describe "--skip" do
    before { building_plan }

    it "never assigns the skipped agent, so its plans simply wait" do
      out, _err, status = run(skip: "luke-backend")

      expect(out).not_to include("luke-backend")
      expect(status).to eq(0)
    end

    it "leaves the rest of the round to everyone else" do
      plans { |t| t.plan("003.00", :new, "raw-idea", files: {"spec.md" => spec_body}) }
      out, = run(skip: "luke-backend")

      expect(out).to include("leah-researcher")
      expect(out).not_to include("luke-backend")
    end

    # A typo'd skip silently skipping nobody is the same failure --plan
    # refuses for numbers.
    it "refuses a name nobody answers to" do
      _out, err, status = run(skip: "obi-wan")

      expect(unwrapped(err)).to include("No agent called obi-wan", "luke-backend")
      expect(status).to eq(65)
    end

    it "refuses --agent and --skip naming the same agent" do
      _out, err, status = run(agent: "luke-backend", skip: "luke-backend")

      expect(unwrapped(err)).to include("contradict")
      expect(status).to eq(64)
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

    # The stub answers ok and signs nothing, so the dispatcher looks for the
    # work on disk, finds no pull request to justify 🟢, and marks the attempt
    # Interrupted with no rounds left. Both of the pair get their turn at 🟡,
    # which is why one plan makes two invocations and two failures.
    it "reports each attempt, prints the bill, and exits non-zero when nothing was signed" do
      with_executor
      out, err, status = run(commit: true, rounds: 1)

      expect(out).to include("attempts", "001.00\tluke-backend")
      # A committed run spent something, so the tally belongs with the
      # attempts it bills for, on STDOUT, where a redirected run keeps it.
      expect(out).to include("2 invocations")
      expect(unwrapped(err)).to include("0 advanced", "2 failed")
      expect(status).to eq(1)
    end

    # Narrowed to luke: once he moves the plan to 🟢, hansolo would take it
    # next, sign nothing, and fail the run for a reason this example is not
    # about.
    it "exits zero when the agent signs Completed and the folder moves" do
      with_executor { |subject|
        File.write(File.join(subject.feature.path, "plan-backend.md"), "> [2026-09-04 11:29:20 AM PDT] [ agent: luke-backend   status: Completed, round 1 ]\n")
        File.write(File.join(subject.feature.path, "plan-frontend.md"), "> [2026-09-04 11:29:20 AM PDT] [ agent: rey-frontend   status: Completed, round 1 ]\n")
        File.write(File.join(subject.feature.path, "pull-requests.md"), "| Pull Request Number | Pull Request Name | Status |\n| --: | :-- | --: |\n| 1 | [x](https://github.com/example/repo/pull/1) | Open 🟡 |\n")
        [true, "completed"]
      }
      out, _err, status = run(commit: true, agent: "luke-backend")
      expect(out).to include("building -> ready_for_review")
      expect(status).to eq(0)
    end

    # luke `starts_as` 🟡, so a ⭐️ folder moves the moment he is dispatched.
    # The stub signs Almost completed rather than Completed: the attempt is
    # then ok without claiming 🟢, and the plan sits at 🟡 where it landed.
    it "shows a plan that actually moved as from -> to" do
      plans { |t| t.plan("002.00", :planned, "moves", files: {"spec.md" => spec_body, "plan.md" => "# Plan"}) }
      with_executor { |subject, agent|
        File.write(File.join(subject.feature.path, agent.ledger.first),
          "> [2026-09-04 11:29:20 AM PDT] [ agent: #{agent.name}   status: Almost completed, round 1 ]\n")
        [true, "paused"]
      }
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

  describe "the state file" do
    before { building_plan }

    # The run's memory lives under .plans/tmp/, which is about one machine and
    # must not ride along in a commit. Somebody's .gitignore is edited once,
    # and the edit is announced once.
    it "adds .plans/tmp/ to .gitignore once and says so" do
      root = File.dirname(plans_root)
      system("git", "-C", root, "init", "-q")
      with_executor
      _out, first, = run(commit: true)
      _out, second, = run(commit: true)

      aggregate_failures do
        expect(unwrapped(first)).to include("Added .plans/tmp/ to .gitignore")
        expect(unwrapped(second)).not_to include("Added .plans/tmp/")
        expect(File.read(File.join(root, ".gitignore")).scan(".plans/tmp/").size).to eq(1)
      end
    end

    it "touches neither .gitignore nor .plans/tmp on a dry run" do
      root = File.dirname(plans_root)
      system("git", "-C", root, "init", "-q")
      run

      aggregate_failures do
        expect(File).not_to exist(File.join(root, ".gitignore"))
        expect(File).not_to exist(File.join(plans_root, "tmp"))
      end
    end
  end

  describe "worktree isolation with a repository to isolate in" do
    # The real thing shells out to `git worktree add`; the double answers the
    # two questions the command asks — is this a repository, and where does
    # this plan's checkout live — so the wiring to {Publisher} is exercised
    # without git. The checkout is a plain directory, which `dirty?` reads as
    # clean, so the publisher is constructed and then rightly never pushes.
    it "wires a publisher in and runs each plan in its own checkout" do
      building_plan
      checkout = Agentilda::Worktree::Checkout.new(
        ordinal: Agentilda::Ordinal.parse("001.00"), branch: "kig/001.00-tax-rule-dsl",
        path: plans_root, created: true
      )
      worktree = instance_double(Agentilda::Worktree, repository?: true, checkout_for: checkout)
      allow(Agentilda::Worktree).to receive(:new).and_return(worktree)

      out, err, status = run(isolation: "worktree")

      expect(out).to include("001.00\tluke-backend")
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
      plans { |t| t.plan("001.00", :blocked, "stuck", files: {"blocked.md" => "# Blocked\n\n## B1. Which vendor\n"}) }
      _out, err, = run

      expect(unwrapped(err)).to include("1 plan need", "agentilda unblock 001.00 --commit")
    end
  end
end
