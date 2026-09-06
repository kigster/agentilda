# frozen_string_literal: true

module Agentilda
  # Drives specialist agents over a `.plans` tree until nothing is left to
  # dispatch.
  #
  # The loop itself is {Dispatcher}. This holds what the loop needs about
  # the run: the tree and its scope, the roster, the executor, how many run
  # at once, where each plan is checked out, and how a finished plan is
  # published. Blocked plans (⭕️ 🅱️) are stepped around, never assigned.
  class Runner
    # What one agent did to one plan.
    Attempt = Data.define(:ordinal, :agent, :from, :to, :ok, :note, :up, :down, :subagents,
      :delegated, :seconds, :round, :file, :model, :status) do
      def initialize(round: 1, file: "", model: nil, status: nil, **rest) = super

      # @return [Boolean] whether the plan actually moved
      def advanced? = ok && from != to
    end

    # One unit of work: an agent, a plan, and the checkout it happens in.
    Task = Data.define(:agent, :subject, :root, :checkout, :round) do
      # @return [Hash] columns for the log
      def log_fields
        {plan: subject.feature.ordinal.to_s, status: subject.status.to_s,
         agent: agent.name, round: format("%02d", round)}
      end
    end

    # @param rounds [Integer, nil] `--rounds`, capping each agent's own
    # @param state [Agentilda::StateFile, nil]
    # @param sleeper [Proc]
    # @param on_board [Proc, nil]
    def initialize(tree:, executor:, agents: Agents.new, isolation: :shared, jobs: 1, worktree: nil,
      plans: nil, publisher: nil, dry_run: false, rounds: nil, state: nil,
      sleeper: ->(seconds) { sleep(seconds) }, on_board: nil)
      @tree = tree
      @executor = executor
      @agents = agents
      @isolation = isolation
      @worktree = worktree
      @plans = plans
      @publisher = publisher
      @dry_run = dry_run
      @rounds = rounds
      @state = dry_run ? nil : state
      @sleeper = sleeper
      @on_board = on_board
      @attempts = []
      @jobs = isolated? ? jobs : 1
    end

    attr_reader :jobs, :worktree, :tree, :attempts, :executor, :agents

    # @return [Boolean]
    def isolated? = @isolation == :worktree

    # @return [Boolean]
    def dry_run? = @dry_run

    # @return [String] the repository root
    def root = isolated? ? worktree.root : shared_root

    # @param subject [Agentilda::Subject]
    # @return [Boolean]
    def in_scope?(subject) = @plans.nil? || @plans.include?(subject.feature.ordinal)

    # @return [Array<Agentilda::Subject>]
    def in_scope = tree.subjects.select { |s| in_scope?(s) }

    # Run until nothing is dispatchable.
    #
    # @yieldparam dispatcher [Agentilda::Dispatcher] before it runs, so a
    #   console can attach itself and reach the running jobs
    # @return [Array<Agentilda::Runner::Attempt>]
    def call
      dispatcher = Dispatcher.new(runner: self, state: @state, rounds: @rounds, sleeper: @sleeper, on_board: @on_board)
      yield dispatcher if block_given?
      @attempts = dispatcher.run
    end

    # @return [Array<Agentilda::Subject>]
    def blocked = in_scope.select { |s| %i[blocked product_blocked].include?(s.status.key) }

    # @return [Boolean]
    def settled? = in_scope.all? { |s| StateMachine::SETTLED.include?(s.status.key) }

    # A dry run gets the shared root whatever the isolation says: nothing
    # runs in the checkout, and `git worktree add` is a side effect a
    # preview must not have. It also fails outright when the plan's branch
    # is the one checked out where the run was typed, which is where a dry
    # run of that plan is typed.
    #
    # @return [Agentilda::Runner::Task]
    def prepare(agent, subject, round)
      return Task.new(agent:, subject:, root: shared_root, checkout: nil, round:) if !isolated? || dry_run?

      checkout = worktree.checkout_for(subject.feature)
      Task.new(agent:, subject:, root: checkout.path, checkout:, round:)
    end

    # @return [Agentilda::Publisher::Publication, nil]
    def publish(task, subject)
      return nil unless @publisher && task.checkout&.dirty?

      publication = @publisher.publish(checkout: task.checkout, subject:)
      record_pull_request(subject.feature.path, publication) if publication.published?
      publication
    end

    private

    # @return [String]
    def shared_root = File.dirname(tree.dir)

    # @return [void]
    def record_pull_request(path, publication)
      number = publication.url.to_s[%r{/pull/(\d+)}, 1]
      rows = PullRequests.new(dir: path).all.map { |pr|
        {number: pr.number, title: pr.title, url: pr.url, state: pr.state, body: ""}
      }
      rows << {number:, title: publication.title, url: publication.url, state: "Open 🟡", body: ""}
      PullRequests.upsert(File.join(path, PullRequests::FILENAME), rows)
    end
  end
end
