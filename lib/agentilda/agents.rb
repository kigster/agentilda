# frozen_string_literal: true

module Agentilda
  # The specialists: their definitions in `agents/*.md`, the registry that
  # loads and filters them, and the roster that reports on them.
  module Agents
    module_function

    # @param dir [String] where the definitions live
    # @return [Agentilda::Agents::Registry]
    def registry(dir: Registry::DEFAULT_DIR) = Registry.new(dir:)

    # @param name [String]
    # @return [Agentilda::Agents::Agent, nil]
    def find(name, dir: Registry::DEFAULT_DIR) = registry(dir:).find(name)

    # @return [Agentilda::Agents::Roster]
    def roster(**) = Roster.new(**)
  end
end
