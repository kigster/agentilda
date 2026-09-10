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
  Agent = Data.define(:name,
    :description,
    :handles,
    :advances_to,
    :model,
    :allowed_tools,
    :may,
    :network,
    :timeout,
    :prompt,
    :path,
    :ledger,
    :rounds,
    :effort,
    :starts_as,
    :holds_at) do
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
end
