# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda agents …` — the specialist roster.
    module Agents
      # `agentilda agents list`
      class List < Dry::CLI::Command
        include UI

        desc "List every specialist, what it handles, and what it advances to"

        example ["", "| less -R"]

        # @return [void]
        def call(**) = $stdout.write(Roster.new.list)
      end
    end
  end
end
