# frozen_string_literal: true

RSpec.describe Agentilda::Dispatcher, :tree do
  let(:tree) { Agentilda::Tree.new(dir: plans_root) }
  let(:agents) { Agentilda::Agents.new }
  let(:state) { Agentilda::StateFile.new(path: Agentilda::StateFile.for(tree)) }
  let(:calls) { [] }
  let(:stamp) { "2026-09-04 11:29:20 AM PDT" }

  # An executor that behaves like a real agent: signs Started, does its
  # work, signs its outcome. Each fake is keyed by agent name.
  def executor_with(&behaviour)
    lambda { |agent, subject, round: 1, **|
      calls << [agent.name, subject.feature.ordinal.to_s, round]
      file = File.join(subject.feature.path, agent.ledger.first)
      Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: #{agent.name}   status: Started, round #{round} ]")
      outcome = behaviour.call(agent, subject, round)
      Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: #{agent.name}   status: #{outcome}, round #{round} ]") if outcome
      Agentilda::Executor::Result.new(ok: true, note: "completed", up: 10, down: 2, subagents: 0, delegated: 0, seconds: 1.0)
    }
  end

  def runner_with(executor, **options)
    Agentilda::Runner.new(tree:, executor:, agents:, isolation: :shared, jobs: 2, state:,
      sleeper: ->(_) {}, **options)
  end

  def path_of(ordinal) = tree.reload.find(Agentilda::Ordinal.parse(ordinal)).feature.path

  describe "the 020.00 regression" do
    let!(:built) do
      plans { |t| t.plan "020.00", :researched, "qualified-at", files: {"spec.md" => "#{spec_body}\n## Research\n\nFound.\n"} }
    end

    # yoda finishes, leaves a blank plan.md, signs Completed and names
    # palpatine. The harness renames to 📋, starts palpatine, palpatine
    # writes a plan and signs, the harness renames to ⭐️, luke and rey
    # start. Nobody is invoked twice and the run does not exit green with
    # the plan unmoved.
    it "moves yoda's finished work to 📋 and starts palpatine, then the pair" do
      executor = executor_with do |agent, subject, _round|
        case agent.name
        when "yoda-writer"
          File.write(File.join(subject.feature.path, "plan.md"), "")
          "Completed"
        when "palpatine-planner"
          File.write(File.join(subject.feature.path, "plan.md"), "# Plan\n\n## Unit 1\n")
          "Completed"
        end
      end
      runner_with(executor).call

      aggregate_failures do
        expect(calls.map(&:first)).to eq(%w[yoda-writer palpatine-planner luke-backend rey-frontend])
        expect(calls.count { |name, _, _| name == "yoda-writer" }).to eq(1)
        expect(tree.reload.find(Agentilda::Ordinal.parse("020.00")).status.key).to eq(:building)
      end
    end

    it "records each promotion on the attempt that earned it" do
      executor = executor_with do |agent, subject, _|
        File.write(File.join(subject.feature.path, "plan.md"), "") if agent.name == "yoda-writer"
        (agent.name == "yoda-writer") ? "Completed" : nil
      end
      attempts = runner_with(executor).call
      yoda = attempts.find { |a| a.agent == "yoda-writer" }
      expect([yoda.from, yoda.to]).to eq(%i[researched ready_for_planning])
    end
  end

  # The 001.00 transcript, the other way round: a folder still named ⚪️
  # whose spec.md carries its research and whose plan.md already holds work
  # units. The old loop read the name, offered it to leah-researcher, and
  # she researched a plan that was ready to build.
  describe "a folder whose name lags its contents" do
    let!(:built) do
      plans do |t|
        t.plan "001.00", :new, "already-planned",
          files: {"spec.md" => "#{spec_body}\n## Research\n\nWhat was found.\n", "plan.md" => "# P\n\n## Unit 1\n"}
      end
    end

    it "renames it first and offers it to the pair, never to leah-researcher" do
      runner_with(executor_with { |*| nil }).call

      aggregate_failures do
        expect(calls.map(&:first)).not_to include("leah-researcher")
        expect(calls.map(&:first).first(2)).to contain_exactly("luke-backend", "rey-frontend")
      end
    end

    it "previews the same pair on a dry run, and renames nothing" do
      runner_with(executor_with { |*| nil }, dry_run: true).call

      aggregate_failures do
        expect(calls.map(&:first)).to contain_exactly("luke-backend", "rey-frontend")
        expect(Dir.children(plans_root)).to include("001.00-⚪️--already-planned")
      end
    end
  end

  describe "handoffs" do
    let!(:built) { plans { |t| t.plan "001.00", :new, "relay", files: {"spec.md" => spec_body} } }

    it "starts the named successor only after the predecessor exited" do
      order = []
      executor = lambda { |agent, subject, round: 1, **|
        order << [:start, agent.name]
        file = File.join(subject.feature.path, "spec.md")
        if agent.name == "leah-researcher"
          File.write(file, "#{spec_body}\n## Research\n\nFound.\n")
          Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: leah-researcher   status: Completed, round 1 ]",
            "> [#{stamp}] [ next: yoda-writer ]")
        end
        order << [:end, agent.name]
        Agentilda::Executor::Result.new(ok: true, note: "completed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
      }
      runner_with(executor).call
      expect(order.first(3)).to eq([[:start, "leah-researcher"], [:end, "leah-researcher"], [:start, "yoda-writer"]])
    end

    # hansolo is on the roster, so the refusal is about what he handles and
    # not about whether he exists; nobody left handles 🔎, so the run stops.
    it "refuses a next: that names an agent who does not handle the new state, and says so" do
      executor = lambda { |agent, subject, round: 1, **|
        file = File.join(subject.feature.path, "spec.md")
        File.write(file, "#{spec_body}\n## Research\n\nFound.\n")
        Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: leah-researcher   status: Completed, round 1 ]",
          "> [#{stamp}] [ next: hansolo-reviewer ]")
        Agentilda::Executor::Result.new(ok: true, note: "completed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
      }
      attempts = runner_with(executor, agents: agents.only("leah-researcher", "hansolo-reviewer")).call
      expect(attempts.first.note).to include("next: names hansolo-reviewer", "does not handle")
    end
  end

  describe "outcomes other than Completed" do
    let!(:built) { plans { |t| t.plan "001.00", :new, "again", files: {"spec.md" => spec_body} } }

    it "re-runs an Almost completed agent while it has rounds, then parks the plan" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "leah.md"), "---\nname: leah-researcher\nhandles: [new]\nadvances_to: researched\nrounds: 2\nledger: [spec.md]\n---\nbody")
        two = Agentilda::Agents.new(dir:)
        executor = executor_with { |_, _, _| "Almost completed" }
        attempts = Agentilda::Runner.new(tree:, executor:, agents: two, isolation: :shared, jobs: 1, state:, sleeper: ->(_) {}).call
        aggregate_failures do
          expect(calls.map(&:last)).to eq([1, 2])
          expect(attempts.last.note).to include("no rounds left")
        end
      end
    end

    it "never re-runs a Completed agent whose promotion was refused, and reports the refusal" do
      executor = executor_with { |_, _, _| "Completed" } # no Research chapter written
      attempts = runner_with(executor, agents: agents.only("leah-researcher")).call
      aggregate_failures do
        expect(calls.size).to eq(1)
        expect(attempts.first.ok).to be(false)
        expect(attempts.first.note).to include("Researched", "no `## Research` chapter")
      end
    end

    it "parks a Blocked plan at ⭕️ when blocked.md names a question" do
      executor = executor_with do |_, subject, _|
        File.write(File.join(subject.feature.path, "blocked.md"), "## B1\n\nWhich?\n")
        "Blocked"
      end
      runner_with(executor, agents: agents.only("leah-researcher")).call
      expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:blocked)
    end

    it "parks a product block at 🅱️ when the note says so" do
      executor = lambda { |agent, subject, round: 1, **|
        File.write(File.join(subject.feature.path, "blocked.md"), "## B1\n\nWhich colour?\n")
        Agentilda::Ledger.append(File.join(subject.feature.path, "spec.md"),
          "> [#{stamp}] [ agent: leah-researcher   status: Blocked, round 1 (product) ]")
        Agentilda::Executor::Result.new(ok: true, note: "completed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
      }
      runner_with(executor, agents: agents.only("leah-researcher")).call
      expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:product_blocked)
    end
  end

  describe "verify and sign" do
    let!(:built) { plans { |t| t.plan "001.00", :new, "cut-off", files: {"spec.md" => spec_body} } }

    # The agent did the work and was killed before its closing line. The
    # invariant of 🔎 holds, so the harness signs on its behalf, in bold,
    # and the plan moves.
    it "signs Completed for a killed agent whose work is on disk" do
      executor = lambda { |agent, subject, round: 1, **|
        file = File.join(subject.feature.path, "spec.md")
        File.write(file, "#{spec_body}\n## Research\n\nFound.\n")
        Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: leah-researcher   status: Started, round 1 ]")
        Agentilda::Executor::Result.new(ok: false, note: "killed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0, killed: :key)
      }
      attempts = runner_with(executor, agents: agents.only("leah-researcher")).call
      text = File.read(File.join(path_of("001.00"), "spec.md"))
      aggregate_failures do
        expect(text).to include("status: **Interrupted, round 1 (killed by harness after 15s grace)**")
        expect(text).to include("status: Completed, round 1 (signed by harness: work verified on disk)")
        expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:researched)
        expect(attempts.first.to).to eq(:researched)
      end
    end

    it "writes only Interrupted, and re-runs, when the work is not there" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "leah.md"), "---\nname: leah-researcher\nhandles: [new]\nadvances_to: researched\nrounds: 2\nledger: [spec.md]\n---\nbody")
        two = Agentilda::Agents.new(dir:)
        executor = lambda { |agent, subject, round: 1, **|
          calls << round
          Agentilda::Executor::Result.new(ok: false, note: "timed out", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0, killed: :timeout)
        }
        Agentilda::Runner.new(tree:, executor:, agents: two, isolation: :shared, jobs: 1, state:, sleeper: ->(_) {}).call
        text = File.read(File.join(path_of("001.00"), "spec.md"))
        aggregate_failures do
          expect(calls).to eq([1, 2])
          expect(text.scan("Interrupted").size).to eq(2)
          expect(text).not_to include("signed by harness")
        end
      end
    end
  end

  describe "the pair" do
    # 🟢 Ready for Review needs an open pull request recorded. A real run has
    # the publisher write that row; this example has no publisher, so the
    # fixture carries it from the start.
    let!(:built) do
      plans { |t|
        t.plan "001.00", :planned, "both", files: {"spec.md" => spec_body, "plan.md" => "# Plan\n\n## U1\n"},
          prs: [t.open(7, "[001.00](A) Both")]
      }
    end

    # Two doubles share one folder here, which a real run never allows
    # (shared isolation is serial), so they keep out of each other's way:
    # one signs at a time, and luke does not return until rey has signed,
    # so rey's line is on disk before the fold to 🎨 moves the folder.
    it "renames to 🟡 when luke starts, holds at 🎨 when luke finishes first, and goes 🟢 when rey does" do
      seen = []
      signing = Mutex.new
      rey_signed = Queue.new
      executor = lambda { |agent, subject, round: 1, **|
        seen << [agent.name, subject.status.key]
        file = File.join(subject.feature.path, "pull-requests.md")
        signing.synchronize do
          Agentilda::Ledger.append(file, "> [#{stamp}] [ agent: #{agent.name}   status: Completed, round 1 ]")
        end
        if agent.name == "rey-frontend"
          rey_signed << true
          sleep(0.2) # rey takes longer, so luke completes while rey is still running
        else
          rey_signed.pop
        end
        Agentilda::Executor::Result.new(ok: true, note: "completed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
      }
      runner = Agentilda::Runner.new(tree:, executor:, agents: agents.only("luke-backend", "rey-frontend"),
        isolation: :shared, jobs: 2, state:, sleeper: ->(s) { sleep(0.05) })
      allow(runner).to receive(:jobs).and_return(2) # let two run at once without a worktree
      runner.call
      aggregate_failures do
        expect(seen.map(&:last)).to eq(%i[building building])
        expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:ready_for_review)
      end
    end
  end

  describe "the reviewer's verdicts" do
    let!(:built) do
      plans { |t|
        t.plan "001.00", :ready_for_review, "judged", files: {"spec.md" => spec_body, "plan.md" => "# P\n\n## U\n"},
          prs: [t.open(7, "[001.00](A) Judged")]
      }
    end

    def hansolo(note)
      lambda { |agent, subject, round: 1, **|
        Agentilda::Ledger.append(File.join(subject.feature.path, "pull-requests.md"),
          "> [#{stamp}] [ agent: hansolo-reviewer   status: Completed, round #{round} (#{note}) ]")
        Agentilda::Executor::Result.new(ok: true, note: "completed", up: 0, down: 0, subagents: 0, delegated: 0, seconds: 0.0)
      }
    end

    it "moves a rejection to 🔴" do
      runner_with(hansolo("rejected 1/2"), agents: agents.only("hansolo-reviewer")).call
      expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:rejected)
    end

    it "leaves an approval at 👀 and treats the plan as finished for this run" do
      attempts = runner_with(hansolo("approved"), agents: agents.only("hansolo-reviewer")).call
      aggregate_failures do
        expect(tree.reload.find(Agentilda::Ordinal.parse("001.00")).status.key).to eq(:in_review)
        expect(attempts.size).to eq(1)
        expect(attempts.first.note).to include("approved")
      end
    end
  end

  describe "restarting after a dead harness" do
    let!(:built) { plans { |t| t.plan "001.00", :new, "resumed", files: {"spec.md" => spec_body} } }

    # The stranded stage is an Interrupted round, so the re-run is the
    # agent's second, and leah needs two to have it.
    it "writes the harness Interrupted line for a stranded stage and re-runs the agent" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "leah.md"), "---\nname: leah-researcher\nhandles: [new]\nadvances_to: researched\nrounds: 2\nledger: [spec.md]\n---\nbody")
        two = Agentilda::Agents.new(dir:)
        dead = Agentilda::StateFile.new(path: Agentilda::StateFile.for(tree), pid: 999_999_999)
        dead.begin_run!(root: File.dirname(plans_root))
        dead.record("001.00", agent: "leah-researcher", round: 1, status: "Started", state: "new")
        dead.save

        executor = executor_with { |_, _, _| nil }
        runner_with(executor, agents: two, state: Agentilda::StateFile.new(path: dead.path)).call
        text = File.read(File.join(path_of("001.00"), "spec.md"))
        aggregate_failures do
          expect(text).to include("Interrupted, round 1 (harness died)")
          expect(calls.map(&:last)).to eq([2])
        end
      end
    end
  end

  describe "a dry run" do
    let!(:built) { plans { |t| t.plan "001.00", :new, "preview", files: {"spec.md" => spec_body} } }

    it "invokes each eligible agent once, writes no ledger, renames nothing, saves no state" do
      executor = Agentilda::Executor.new(root: File.dirname(plans_root), dry_run: true)
      attempts = runner_with(executor, dry_run: true).call
      aggregate_failures do
        expect(attempts.map(&:agent)).to eq(%w[leah-researcher])
        expect(File.read(File.join(path_of("001.00"), "spec.md"))).not_to include("[ agent:")
        expect(File).not_to exist(state.path)
      end
    end
  end
end
