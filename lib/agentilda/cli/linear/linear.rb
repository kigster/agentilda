# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda linear …`
    module Linear
      # Shared by both linear commands: the team is which workspace this is
      # about, so it is an argument rather than a flag. There is no default —
      # a tool that picks a team for you when you forget to say which is a
      # tool that files a quarter of somebody's work in the wrong place.
      class Team < Base
        def self.inherited(klass)
          super
          klass.argument :team, required: true,
            desc: "The Linear team key that prefixes its issues, e.g. TAX"
        end

        private

        # The key is checked before anything reaches for a token, so a typo in
        # the team name reports the typo rather than an authentication
        # problem the user does not have.
        #
        # @param team [String]
        # @return [Agentilda::Linear::Survey]
        def survey_for(team, tree)
          key = Agentilda::Linear.key!(team)
          api = Agentilda::Linear::API.new(token: Agentilda::Linear::API.token_from_env)
          projects = UI.spinning("Listing #{key} projects") { api.projects(api.team(key)[:id]) }
          [api, Agentilda::Linear::Survey.new(tree:, projects:)]
        end
      end
    end
  end
end
