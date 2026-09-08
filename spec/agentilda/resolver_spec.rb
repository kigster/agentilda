# frozen_string_literal: true

# `jabba-resolver` through `claude -p --json-schema`. The process is a fake
# that plays back one JSON envelope, so the contract under test is the argv
# we build, the prompt we send, and how strictly we read what comes back.
RSpec.describe Agentilda::Resolver, :tree do
  subject(:resolver) { described_class.new(tree:, spawn:, cache_dir:, root: File.dirname(plans_root), jobs: 1) }

  let(:tree) { Agentilda::Tree.new(dir: plans_root) }
  let(:cache_dir) { File.join(plans_root, "..", "cache") }
  let(:output) { JSON.generate(envelope) }
  let(:exit_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:fake_child) do
    child = instance_double(Agentilda::Child, pid: 4242, alive?: false, kill: nil, wait: exit_status)
    allow(child).to receive(:each_chunk) { |&block| block.call(output) unless output.empty? }
    child
  end
  let(:spawned) { [] }
  let(:spawn) {
    ->(argv, chdir: nil) {
      spawned << argv
      fake_child
    }
  }

  let(:envelope) do
    {"type" => "result", "subtype" => "success", "is_error" => false,
     "result" => "{\"plan\":\"001.00\"}",
     "structured_output" => {"plan" => "001.00", "confidence" => 0.85, "reason" => "The spec asks for exactly this.", "dev" => false},
     "usage" => {"input_tokens" => 1200, "cache_read_input_tokens" => 300, "output_tokens" => 40},
     "total_cost_usd" => 0.0021}
  end

  let!(:built) do
    plans do |t|
      t.plan "001.00", :new, "tax-rule-dsl", files: {"spec.md" => spec_body(title: "Tax Rule DSL", goal: "Rules as data.")}
      t.plan "002.00", :new, "second", files: {"spec.md" => spec_body(title: "Second", goal: "Another thing.")}
    end
  end

  let(:pull) do
    {number: 7, title: "Add the DSL", branch: "kig/dsl", body: "Adds a rule DSL.", state: "Open 🟡",
     files: ["lib/dsl.rb"], changes: [{path: "lib/dsl.rb", additions: 120, deletions: 3}], head_sha: "0123456789abcdef"}
  end

  describe "#invocation" do
    let(:argv) { resolver.invocation(pull) }
    let(:flags) { argv.each_cons(2).to_a }

    it "asks for a single JSON result that conforms to the verdict schema" do
      aggregate_failures do
        expect(flags).to include(["--output-format", "json"])
        expect(flags).to include(["--json-schema", JSON.generate(described_class::SCHEMA)])
        expect(flags).to include(["--max-turns", "1"])
      end
    end

    it "takes model, effort and budget from the agent's frontmatter" do
      aggregate_failures do
        expect(flags).to include(["--model", "haiku"])
        expect(flags).to include(["--effort", "xhigh"])
        expect(flags).to include(["--max-budget-usd", "0.50"])
      end
    end

    it "lets a typed model beat the frontmatter" do
      typed = described_class.new(tree:, spawn:, root: File.dirname(plans_root), model: "sonnet")

      expect(typed.invocation(pull).each_cons(2).to_a).to include(["--model", "sonnet"])
    end

    it "withholds every tool: the judge reads its prompt and nothing else" do
      expect(flags.to_h["--disallowedTools"]).to include("Bash", "Read", "WebFetch")
    end

    it "refuses to run without a definition file" do
      nameless = described_class.new(tree:, spawn:, agent: nil, root: File.dirname(plans_root))
      allow(Agentilda::Agents).to receive(:new).and_return(instance_double(Agentilda::Agents, find: nil))

      expect { nameless.agent }.to raise_error(Agentilda::Error, /jabba-resolver/)
    end
  end

  describe "#prompt_for" do
    let(:prompt) { resolver.prompt_for(pull) }

    it "carries the agent's own definition first" do
      expect(prompt).to start_with(resolver.agent.prompt[0, 40])
    end

    it "carries every plan with the opening of its spec" do
      expect(prompt).to include("001.00 — Tax Rule DSL", "Rules as data.", "002.00 — Second", "Another thing.")
    end

    it "carries the pull request's description and its files with line counts" do
      expect(prompt).to include("#7", "Add the DSL", "Adds a rule DSL.", "`lib/dsl.rb`  (+120 −3)")
    end

    it "says when a plan has no spec rather than sending an empty heading" do
      plans { |t| t.plan "003.00", :retroactive, "bare" }

      expect(described_class.new(tree: tree.reload, spawn:, root: File.dirname(plans_root)).prompt_for(pull)).to include("(no spec.md)")
    end
  end

  describe "#judge" do
    it "reads the structured answer into a verdict with what it cost" do
      verdict = resolver.judge(pull)

      aggregate_failures do
        expect(verdict).to be_valid
        expect(verdict.plan.to_s).to eq("001.00")
        expect(verdict.confidence).to eq(0.85)
        expect(verdict.reason).to eq("The spec asks for exactly this.")
        expect(verdict).not_to be_dev
        expect(verdict.up).to eq(1500)
        expect(verdict.down).to eq(40)
        expect(verdict.cost).to eq(0.0021)
      end
    end

    it "runs the process in the repository root" do
      chdirs = []
      described_class.new(tree:, spawn: ->(_argv, chdir: nil) {
        chdirs << chdir
        fake_child
      }, root: File.dirname(plans_root)).judge(pull)

      expect(chdirs).to eq([File.dirname(plans_root)])
    end

    context "when the CLI puts the object in result instead" do
      let(:envelope) { super().merge("structured_output" => nil, "result" => JSON.generate(super()["structured_output"])) }

      it "still reads it" do
        expect(resolver.judge(pull).plan.to_s).to eq("001.00")
      end
    end

    context "when claude does not report a cost" do
      let(:envelope) { super().merge("total_cost_usd" => nil) }

      it "estimates one from the model's published rate" do
        expect(resolver.judge(pull).cost).to be_within(1e-9).of((1500 * 1.0 + 40 * 5.0) / 1_000_000.0)
      end
    end

    context "when the answer names a plan that is not in the tree" do
      let(:envelope) { super().merge("structured_output" => super()["structured_output"].merge("plan" => "099.00")) }

      it "is no verdict, never a guess" do
        verdict = resolver.judge(pull)

        aggregate_failures do
          expect(verdict).not_to be_valid
          expect(verdict.error).to include("099.00")
          expect(verdict.plan).to be_nil
        end
      end
    end

    context "when the answer is missing a field" do
      let(:envelope) { super().merge("structured_output" => {"plan" => "001.00"}) }

      it "is no verdict" do
        expect(resolver.judge(pull).error).to include("missing a required field")
      end
    end

    context "when claude reports an error" do
      let(:envelope) { super().merge("is_error" => true, "result" => "Budget exceeded", "structured_output" => nil) }

      it "carries the message and still counts what was spent" do
        verdict = resolver.judge(pull)

        aggregate_failures do
          expect(verdict.error).to include("Budget exceeded")
          expect(verdict.up).to eq(1500)
        end
      end
    end

    context "when the process prints nothing" do
      let(:output) { "" }
      let(:exit_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

      it "names the usual cause rather than failing to parse" do
        expect(resolver.judge(pull).error).to include("no output", "exit 1", "login")
      end
    end

    context "when the output is not JSON" do
      let(:output) { "Segmentation fault" }

      it "is no verdict" do
        expect(resolver.judge(pull).error).to include("unreadable")
      end
    end

    context "when the process cannot start" do
      let(:spawn) { ->(_argv, chdir: nil) { raise Errno::ENOENT, "claude" } }

      it "is no verdict" do
        expect(resolver.judge(pull).error).to include("could not start claude")
      end
    end

    it "clamps a confidence outside the unit interval" do
      envelope["structured_output"]["confidence"] = 1.7

      expect(resolver.judge(pull).confidence).to eq(1.0)
    end
  end

  describe "the cache" do
    it "writes a valid verdict and reads it back without asking again" do
      first = resolver.judge(pull)
      second = resolver.judge(pull)

      aggregate_failures do
        expect(first).not_to be_cached
        expect(second).to be_cached
        expect(second.plan).to eq(first.plan)
        expect(spawned.size).to eq(1)
      end
    end

    it "keys on the head commit, so a new push is judged afresh" do
      resolver.judge(pull)
      resolver.judge(pull.merge(head_sha: "fedcba9876543210"))

      expect(spawned.size).to eq(2)
    end

    it "keys on the plan index, so a new plan folder invalidates every verdict" do
      resolver.judge(pull)
      plans { |t| t.plan "003.00", :new, "third", files: {"spec.md" => spec_body} }
      described_class.new(tree: Agentilda::Tree.new(dir: plans_root), spawn:, cache_dir:, root: File.dirname(plans_root)).judge(pull)

      expect(spawned.size).to eq(2)
    end

    it "does not cache a failure" do
      envelope["structured_output"] = nil
      envelope["result"] = "nope"
      resolver.judge(pull)

      expect(Dir.glob(File.join(cache_dir, "*.json"))).to be_empty
    end

    it "drops a cached verdict whose plan has since vanished" do
      resolver.judge(pull)
      FileUtils.rm_rf(File.join(plans_root, "001.00-⚪️--tax-rule-dsl"))
      fresh = described_class.new(tree: Agentilda::Tree.new(dir: plans_root), spawn:, cache_dir:, root: File.dirname(plans_root))
      path = fresh.cache_path(pull)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate("plan" => "001.00", "confidence" => 0.9, "reason" => "", "dev" => false))

      expect(fresh.judge(pull)).not_to be_cached
    end

    it "is off when no directory is given" do
      uncached = described_class.new(tree:, spawn:, root: File.dirname(plans_root))

      expect(uncached.cache_path(pull)).to be_nil
    end
  end

  describe "#call" do
    it "judges every pull request and keeps input order" do
      verdicts = resolver.call([pull, pull.merge(number: 8, head_sha: "8888")])

      expect(verdicts.map(&:number)).to eq([7, 8])
    end

    it "is empty for nothing" do
      expect(resolver.call([])).to eq([])
    end
  end
end
