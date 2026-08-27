# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda version`
    class Version < Dry::CLI::Command
      desc "Print the version and exit"

      # @return [void]
      def call(**) = puts("agentilda #{Agentilda::VERSION}")
    end
  end
end
