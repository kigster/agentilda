# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda api` — the OpenAPI documents plans carry, collected.
    #
    # A plan that exposes HTTP endpoints writes an `openapi.yaml` beside its
    # `contract.md`. Most plans do not, and should not: see
    # {Agentilda::OpenAPI} for why OpenAPI is a companion to the contract
    # rather than the contract itself.
    module API
      # Shared by both subcommands.
      module Collecting
        private

        # @param options [Hash]
        # @return [Array<Agentilda::OpenAPI::Document>]
        def documents_for(options) = Agentilda::OpenAPI.documents(tree_for(options))
      end
    end
  end
end
