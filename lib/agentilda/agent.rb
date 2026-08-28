# frozen_string_literal: true

require "yaml"

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
  Agent = Data.define(:name, :description, :handles, :advances_to, :model,
    :allowed_tools, :may, :network, :prompt, :path) do
    # @return [Boolean] whether this agent changes anything on disk
    def read_only? = advances_to.nil?

    # @param status [Agentilda::Status]
    # @return [Boolean]
    def handles?(status) = handles.include?(status.key)
  end

  # Loads and indexes the agent definitions.
  class Agents
    # Where definitions live, unless told otherwise.
    DEFAULT_DIR = File.expand_path("../../agents", __dir__)

    # Frontmatter, then body.
    FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n(.*)\z/m

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
      match = FRONTMATTER.match(File.read(path, encoding: "UTF-8")) or return nil
      meta = YAML.safe_load(match[1]) || {}
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
        prompt: match[2].strip,
        path: path
      )
    end
  end
end
