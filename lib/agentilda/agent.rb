# frozen_string_literal: true

module Agentilda
  # One specialist, loaded from `~/.agents/agents/<name>.md`.
  #
  # The definition files are the single source of truth for who does what: the
  # frontmatter says which plan states this agent handles and what it may write,
  # and the body is the prompt. Nothing about a specialty is duplicated in Ruby.
  #
  # @!attribute [r] name
  #   @return [String]
  # @!attribute [r] description
  #   @return [String]
  # @!attribute [r] handles
  #   @return [Array<Symbol>] plan states this agent is offered work from
  # @!attribute [r] advances_to
  #   @return [Symbol, nil] the state it is expected to reach; nil = read-only
  # @!attribute [r] model
  #   @return [String, nil]
  # @!attribute [r] allowed_tools
  #   @return [Array<String>]
  # @!attribute [r] may
  #   @return [Array<String>] commands lifted from {Executor::FORBIDDEN_COMMANDS}
  #     for this agent alone. Nothing in {Executor::UNGRANTABLE} can be lifted.
  # @!attribute [r] timeout
  #   @return [Integer, nil] seconds before this agent is abandoned; nil
  #     defers to the executor's run-wide default
  # @!attribute [r] ledger
  #   @return [Array<String>] the documents this agent signs, in the order
  #     it reaches them; the last entry it wrote is where it stands
  # @!attribute [r] rounds
  #   @return [Integer] how many times it may be invoked on one plan in one
  #     state before the plan parks; a Completed never earns another
  # @!attribute [r] effort
  #   @return [String, nil] passed to `claude --effort`
  # @!attribute [r] starts_as
  #   @return [Symbol, nil] the state the harness renames the plan into the
  #     moment this agent is dispatched, where the topology permits it
  # @!attribute [r] holds_at
  #   @return [Symbol, nil] the state the plan takes when this agent completes
  #     while its partner on the same plan is still running
  Agent = Data.define(:name, :description, :handles, :advances_to, :model,
    :allowed_tools, :may, :network, :timeout, :prompt, :path,
    :ledger, :rounds, :effort, :starts_as, :holds_at) do
    def initialize(ledger: [], rounds: 1, effort: nil, starts_as: nil, holds_at: nil, **rest) = super

    # @return [Boolean] whether this agent changes anything on disk
    def read_only? = advances_to.nil?

    # @param status [Agentilda::Status]
    # @return [Boolean]
    def handles?(status) = handles.include?(status.key)

    # The word after the hyphen: `researcher`, `backend`. What the screen's
    # agent column shows, the name being too long for it.
    #
    # @return [String]
    def role = name.split("-", 2).last.to_s
  end

  # More rounds than this costs tokens and buys nothing: an agent that has
  # not finished in five tries is not going to on the sixth.
  Agent::MAX_ROUNDS = 5

  # Loads and indexes the agent definitions.
  class Agents
    # Where definitions live, unless told otherwise.
    DEFAULT_DIR = File.expand_path("../../agents", __dir__)

    # @param dir [String]
    # @param roster [Array<Agentilda::Agent>, nil] a pre-selected list, used
    #   by {#only} and {#without} to derive a narrower roster; nil (the
    #   default) loads every definition in `dir`
    def initialize(dir: DEFAULT_DIR, roster: nil)
      @dir = File.expand_path(dir)
      @all = roster
    end

    # @return [String]
    attr_reader :dir

    # @return [Array<Agentilda::Agent>] in name order
    def all
      @all ||= Dir.glob(File.join(dir, "*.md")).sort.filter_map { |path| parse(path) }
    end

    # @param name [String]
    # @return [Agentilda::Agent, nil]
    def find(name) = all.find { |a| a.name == name.to_s }

    # A roster holding only the agents named — what `run --agent` hands the
    # loop, so a restriction typed at the command line restricts assignments
    # and not merely chaining.
    #
    # @param names [Array<String>]
    # @return [Agentilda::Agents]
    def only(*names)
      wanted = names.flatten.map(&:to_s)
      self.class.new(dir:, roster: all.select { |a| wanted.include?(a.name) })
    end

    # A roster without the agents named — what `run --skip` hands the loop.
    # A plan sitting in a skipped agent's state is simply never assigned, the
    # same way a state no agent handles is stepped around.
    #
    # @param names [Array<String>]
    # @return [Agentilda::Agents]
    def without(*names)
      unwanted = names.flatten.map(&:to_s)
      self.class.new(dir:, roster: all.reject { |a| unwanted.include?(a.name) })
    end

    # Every agent the query could mean. An exact name wins outright; failing
    # that the query matches as a prefix, and failing that anywhere in the
    # name, so `leah` finds leah-researcher and `review` finds
    # hansolo-reviewer. A directory or a trailing `.md` is stripped first,
    # because tab completion hands those in.
    #
    # @param query [String]
    # @return [Array<Agentilda::Agent>]
    def match(query)
      wanted = File.basename(query.to_s, ".md")
      exact = all.select { |a| a.name == wanted }
      return exact unless exact.empty?

      prefixed = all.select { |a| a.name.start_with?(wanted) }
      return prefixed unless prefixed.empty?

      all.select { |a| a.name.include?(wanted) }
    end

    # Every agent that will act on a plan in this state, in definition order.
    # A read-only agent is never offered work by the loop — it has nothing to
    # advance, so including it would make every round look productive.
    #
    # @param status [Agentilda::Status]
    # @return [Array<Agentilda::Agent>]
    def for_status(status) = all.select { |a| a.handles?(status) && !a.read_only? }

    private

    # @param path [String]
    # @return [Agentilda::Agent, nil]
    def parse(path)
      meta, body = Frontmatter.split(File.read(path, encoding: "UTF-8"))
      return nil if meta["name"].to_s.empty?

      Agent.new(
        name: meta["name"].to_s,
        description: meta["description"].to_s,
        handles: Array(meta["handles"]).map { |s| s.to_s.to_sym },
        advances_to: meta["advances_to"]&.to_s&.then { |s| s.empty? ? nil : s.to_sym },
        model: meta["model"],
        allowed_tools: Array(meta["allowed_tools"]).map(&:to_s),
        may: Array(meta["may"]).map { |c| c.to_s.strip.squeeze(" ") },
        network: meta["network"] == true,
        timeout: meta["timeout"].to_i.then { |s| s.positive? ? s : nil },
        prompt: body.strip,
        path: path,
        ledger: Array(meta["ledger"]).map(&:to_s),
        rounds: meta["rounds"].to_i.clamp(1, Agent::MAX_ROUNDS),
        effort: meta["effort"]&.to_s,
        starts_as: symbol_or_nil(meta["starts_as"]),
        holds_at: symbol_or_nil(meta["holds_at"])
      )
    end

    # @param value [Object, nil]
    # @return [Symbol, nil]
    def symbol_or_nil(value) = value.to_s.empty? ? nil : value.to_s.to_sym
  end
end
