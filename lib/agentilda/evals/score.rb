# frozen_string_literal: true

module Agentilda
  module Evals
    # Every verdict for one case against one folder.
    #
    # @!attribute [r] kase
    #   @return [Agentilda::Evals::Case] at the depth it was scored
    # @!attribute [r] verdicts
    #   @return [Array<Agentilda::Evals::Verdict>]
    Score = Data.define(:kase, :verdicts) do
      # A case with no checks has proved nothing, so it does not pass.
      #
      # @return [Boolean]
      def passed? = !verdicts.empty? && verdicts.all?(&:ok?)

      # @return [Array<Agentilda::Evals::Verdict>]
      def failures = verdicts.reject(&:ok?)

      # @return [String] `7/8`
      def tally = "#{verdicts.count(&:ok?)}/#{verdicts.size}"
    end
  end
end
