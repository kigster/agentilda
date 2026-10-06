# frozen_string_literal: true

module Agentilda
  # Everything a person reads: the live dashboard, the status table, the
  # generated conventions and the state diagram. These render strings and
  # draw on STDERR; none of them changes a plan.
  module Presentation
    module_function

    # @return [String] the conventions document, derived
    def documentation = Documentation.new.render

    # @return [String] the state machine, drawn for a terminal
    def diagram = Diagram.new.render

    # @param tree [Agentilda::Plans::Tree]
    # @return [Agentilda::Presentation::Reporter]
    def reporter(tree:) = Reporter.new(tree:)

    # @return [Agentilda::Presentation::Viewer]
    def viewer = Viewer.new
  end
end
