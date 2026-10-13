# frozen_string_literal: true

# An executor that behaves like an agent still at work: it registers a
# control file, as the real one does, and does not return until the example
# lets it. Commands aimed at a running car need a car that is running.
class HeldExecutor
  def initialize(trace_dir)
    @trace_dir = trace_dir
    @gate = Queue.new
    @preferred = {}
    @calls = []
  end

  # @return [Hash] `[ordinal, agent] => model` as the dispatcher asked
  attr_reader :preferred

  # @return [Array<String>] `"<ordinal>/<agent>"` per invocation started
  attr_reader :calls

  def call(agent, subject, handle: nil, **)
    @calls << "#{subject.feature.ordinal}/#{agent.name}"
    handle.control = Agentilda::Execution::Control.register(@trace_dir, "#{subject.feature.ordinal}-#{agent.name}") if handle
    @gate.pop
    Agentilda::Execution::Executor::Result.new(ok: true, note: "completed", up: 10, down: 2, subagents: 0, delegated: 0, seconds: 1.0)
  end

  def prefer_model(ordinal, agent, model) = @preferred[[ordinal.to_s, agent]] = model

  # Let every agent still waiting finish.
  def release_all(count = 8) = count.times { @gate << :go }
end

RSpec.shared_context "with a live run" do
  let(:tree) { Agentilda::Plans::Tree.new(dir: plans_root) }
  let(:agents) { Agentilda::Agents::Registry.new }
  let(:store) { Agentilda::Live.memory_store }
  let(:node) do
    Agentilda::Live::Node.new(id: "3f9a0c7be21d44a8f6031c5d",
      user: "dana",
      host: "studio-mini",
      ip: "10.0.4.12",
      checkout: "~/github/example/agentilda",
      checkout_id: "a1b2c3d4e5f6")
  end
  let(:keys) { Agentilda::Live::Keys.new(repo: "github.com/example/agentilda", node: node.name) }
  let(:claims) { Agentilda::Live::Claims.new(store:, keys:) }
  let(:run_state) { Agentilda::Live::RunState.new }
  let(:traces) { File.join(File.dirname(plans_root), "traces") }
  let(:executor) { HeldExecutor.new(traces) }
  let(:scope) { nil }
  let(:runner) do
    Agentilda::Engine::Runner.new(tree:,
      executor:,
      agents:,
      isolation: :shared,
      plans: scope,
      claims:,
      sleeper: ->(_) {})
  end
  let(:dispatcher) { Agentilda::Engine::Dispatcher.new(runner:, sleeper: ->(_) {}) }

  # 🟡 Building, the state a resync never moves on its own.
  def building(ordinal, slug, files: {})
    plans do |t|
      t.plan ordinal,
        :building,
        slug,
        files: { "spec.md" => spec_body, "plan.md" => "# Plan\n\n## Unit 1\n", "plan-frontend.md" => "## F1\n" }.merge(files)
    end
  end

  # ⭕️ Technical Block, with the questions given.
  def blocked(ordinal, slug, questions)
    plans do |t|
      t.plan ordinal, :blocked, slug, files: { "spec.md" => spec_body, "plan.md" => "# Plan\n\n## Unit 1\n", "blocked.md" => questions }
    end
  end

  def path_of(ordinal) = tree.reload.find(Agentilda::Plans::Ordinal.parse(ordinal)).feature.path

  # One tick, then until every agent it started has its control file: the
  # executor registers it on the agent's own thread, a moment after start.
  def start_agents
    dispatcher.tick
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep(0.01) until dispatcher.running.all? { it.handle.control } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep(0.01) until executor.calls.size >= dispatcher.attempts.size + dispatcher.running.size ||
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  after do
    executor.release_all if executor.respond_to?(:release_all)
    dispatcher.running.each { it.thread.join(2) }
    Agentilda::Execution::Control.reset!
  end
end
