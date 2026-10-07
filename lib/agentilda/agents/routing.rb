# frozen_string_literal: true

module Agentilda
  module Agents
    # Whether an agent that handles a plan's state should actually be given
    # the plan. Handling the state is necessary, not sufficient: the plan's
    # lane may route around the agent, its spec.md may switch it off, or the
    # files it builds from may hold nothing for it to do.
    #
    # The front end is the case that motivated this. rey-frontend used to be
    # started on every planned folder, and spent ten minutes and five dollars
    # on a plan whose interface was three lines of terminal output.
    module Routing
      # A work unit in a plan file: a second- or third-level heading. A title
      # line does not count, so a `plan-frontend.md` that is only a heading
      # and "no front-end units" starts nobody.
      UNIT_HEADING = /^[ \t]{0,3}\#{2,3}[ \t]+\S/

      module_function

      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject]
      # @param spec [Agentilda::Plans::Spec]
      # @return [Boolean]
      def allows?(agent, subject, spec = Plans::Spec.for(subject))
        return false unless agent.serves?(spec.lane)

        switch = toggled(agent, spec)
        return switch unless switch.nil?

        agent.needs.all? { |file| units?(subject, file) }
      end

      # The agents in +agents+ this plan should get, in their given order.
      #
      # {Agent#needs} only ever chooses between agents. When lanes and
      # switches leave one candidate, that one runs: a plan parked at 🎨 is
      # rey-frontend's to finish whatever `plan-frontend.md` says, and an
      # operator who typed `--agent rey-frontend` meant it.
      #
      # @param agents [Array<Agentilda::Agents::Agent>]
      # @param subject [Agentilda::Plans::Subject]
      # @return [Array<Agentilda::Agents::Agent>]
      def filter(agents, subject)
        spec = Plans::Spec.for(subject)
        routed = agents.select { |agent| agent.serves?(spec.lane) && toggled(agent, spec) != false }
        return routed if routed.size <= 1

        routed.select { |agent| toggled(agent, spec) || agent.needs.all? { |file| units?(subject, file) } }
      end

      # What the spec's switch for this agent says: true forces it, false
      # forbids it, nil leaves the decision to {Agent#needs}.
      #
      # @return [Boolean, nil]
      def toggled(agent, spec)
        return nil if agent.toggle.nil?
        return nil unless spec.respond_to?(agent.toggle)

        spec.public_send(agent.toggle)
      end

      # @param subject [Agentilda::Plans::Subject]
      # @param file [String]
      # @return [Boolean]
      def units?(subject, file) = Plans::Ledger.stripped(subject.read(file)).match?(UNIT_HEADING)
    end
  end
end
