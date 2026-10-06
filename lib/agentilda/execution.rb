# frozen_string_literal: true

module Agentilda
  # One agent invocation: the child process, its clock, the control file it
  # polls, and the transcript it streams back. The autonomy boundary lives
  # here, because this is the only place a coding agent is started.
  module Execution
    module_function

    # @return [Agentilda::Execution::Executor]
    def executor(**) = Executor.new(**)

    # Run the block with Ctrl-C turned into a cooperative interrupt.
    #
    # @return [Object] whatever the block returns
    def on_interrupt(&) = Control.on_interrupt(&)
  end
end
