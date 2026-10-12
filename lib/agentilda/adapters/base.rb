# frozen_string_literal: true

module Agentilda
  module Adapters
    # What every adapter answers. A subclass overrides {#argv}; the rest has a
    # default that is right for a CLI with no opinions of its own.
    class Base
      # @return [String] the name agent frontmatter uses
      def name = self.class.name.split("::").last.downcase

      # @return [String] the executable, for messages
      def executable = name

      # @param invocation [Agentilda::Adapters::Invocation]
      # @return [Array<String>]
      def argv(invocation) = raise NotImplementedError, "#{self.class} must build an argv for #{invocation.class}"

      # A parser for what this CLI prints, with the same interface as
      # {Agentilda::Execution::Transcript}.
      #
      # @param trace [String, nil] where to keep every line verbatim
      # @return [#push, #finish, #up, #down, #failed?]
      def transcript(trace: nil, &) = Stream.new(trace:, &)

      # The model to ask for, after any ceiling this CLI imposes.
      #
      # @param model [String, nil]
      # @return [String, nil]
      def model(model) = model

      # @param effort [String, nil] one of {EFFORTS}
      # @return [String, nil] this CLI's word for it
      def effort(effort) = effort

      # Whether the CLI itself refuses the denied tools, rather than only being
      # asked not to use them. The prompt says which, because telling an agent
      # a guard exists when it does not is how it stops being careful.
      #
      # @return [Boolean]
      def enforces_tool_denial? = false
    end
  end
end
