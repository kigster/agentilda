# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda ledger` — an agent signing the document it owns.
    #
    # Agents used to write these lines by hand, with their editing tool, and
    # that was safe only while each agent owned a document nobody else
    # touched. Both halves of a pair now sign the same `plan.md`, and the
    # harness signs into it as well, so a read-then-write from two processes
    # loses whichever lands second — silently, and a lost `Completed` reads
    # as an agent that never finished. {Agentilda::Ledger.append} takes a
    # lock; this is how an agent reaches it.
    module Ledger
      # The subcommand names a plan and an agent, and needs both resolved.
      module Locating
        private

        # @param options [Hash]
        # @return [Agentilda::Subject]
        def subject_for(options)
          tree = tree_for(options)
          ordinal = Ordinal.parse(options[:plan].to_s)
          subject = ordinal && tree.find(ordinal)
          refuse("No plan #{options[:plan]} in #{tree.dir}.\n\nKnown: #{tree.ordinals.join(", ")}", 66) unless subject

          subject
        end

        # The document the agent's own definition says it signs. Passing
        # `--file` overrides it, for an agent run outside its definition.
        #
        # @param options [Hash]
        # @return [String] a file name, not a path
        def document_for(options)
          return options[:file] if options[:file]

          agent = Agentilda::Agents.new.find(options[:agent])
          refuse("No agent #{options[:agent]}, and no --file to sign instead.", 64) unless agent

          first = agent.ledger.first
          refuse("#{agent.name} signs no document; pass --file.", 64) unless first

          first
        end
      end
    end
  end
end
