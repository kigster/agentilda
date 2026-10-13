# frozen_string_literal: true

module Agentilda
  module Adapters
    # One model an adapter offers: what the page lists in a car's dropdown,
    # and what a token costs on it.
    #
    # @!attribute [r] id
    #   @return [String] the full model id, e.g. `claude-sonnet-5-5`
    # @!attribute [r] label
    #   @return [String] e.g. `Sonnet 5.5`
    # @!attribute [r] rate_in
    #   @return [Numeric] dollars per million tokens sent
    # @!attribute [r] rate_out
    #   @return [Numeric] dollars per million tokens generated
    Model = Data.define(:id, :label, :rate_in, :rate_out) do
      # @param up [Integer] tokens in
      # @param down [Integer] tokens out
      # @return [Float] dollars
      def cost(up, down) = ((up.to_i * rate_in) + (down.to_i * rate_out)) / 1_000_000.0

      # The `ModelChoice` of `web/src/api/types.ts`.
      #
      # @return [Hash]
      def wire = { id:, label:, rates: { in: rate_in, out: rate_out } }
    end
  end
end
