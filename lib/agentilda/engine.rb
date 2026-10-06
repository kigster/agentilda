# frozen_string_literal: true

module Agentilda
  # The run loop: which agent works which plan, in what order, until a round
  # changes nothing. It decides; {Execution} carries the decision out.
  module Engine
    module_function

    # @return [Agentilda::Engine::Runner]
    def runner(**) = Runner.new(**)

    # @param tree [Agentilda::Plans::Tree]
    # @return [Agentilda::Engine::StateFile]
    def state_file(tree) = StateFile.new(path: StateFile.for(tree))

    # @return [Agentilda::Engine::Tally]
    def tally(**) = Tally.new(**)
  end
end
