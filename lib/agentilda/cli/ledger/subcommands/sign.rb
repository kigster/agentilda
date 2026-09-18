# frozen_string_literal: true

module Agentilda
  module CLI
    module Ledger
      # `agentilda ledger sign` — one dated entry in the document an agent
      # owns, appended under a lock.
      class Sign < Base
        include Locating

        desc "Append a dated ledger entry to the document an agent signs"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"
        option :agent, required: true, desc: "The agent signing"
        option :status,
          required: true,
          values:   Agentilda::Ledger::STATUSES,
          desc:     "What the agent is claiming"
        option :round, required: true, desc: "Which round, as the harness counts them"
        option :note, desc: "The parenthesised tail, such as 'no front end'"
        option :next, desc: "The agent to hand to; only after Completed"
        option :file, desc: "Sign this document instead of the one the agent's definition names"

        example [
          "--plan 003 --agent luke-backend --status Started --round 1",
          "--plan 003 --agent luke-backend --status Completed --round 1 --next rey-frontend",
          "--plan 003 --agent rey-frontend --status Completed --round 1 --note 'no front end'"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          quiet?(options)
          subject = subject_for(options)
          document = document_for(options)
          refuse(handoff_refusal(options), 64) if options[:next] && options[:status] != "Completed"

          Agentilda::Ledger.append(File.join(subject.feature.path, document), *lines(options))

          return if quiet?(options)

          UI.line("#{options[:agent]}: #{options[:status]}, round #{options[:round]} in #{document}")
        end

        private

        # @param options [Hash]
        # @return [Array<String>] the quoted lines of one block
        def lines(options)
          entry = Agentilda::Ledger::Entry.new(at:     Time.now,
            agent:  options[:agent],
            status: options[:status],
            round:  options[:round].to_i,
            note:   options[:note],
            file:   nil,
            line:   0)
          written = [Agentilda::Ledger.render(entry)]
          return written unless options[:next]

          written << Agentilda::Ledger.render_handoff(
            Agentilda::Ledger::Handoff.new(at: Time.now, next: options[:next], file: nil, line: 0)
          )
        end

        # A `next:` under anything but `Completed` is the one shape the
        # dispatcher reads as a handoff from an agent that has not finished,
        # which starts the next agent on work that is not there yet.
        #
        # @param options [Hash]
        # @return [String]
        def handoff_refusal(options)
          "--next names who follows a Completed agent; #{options[:agent]} is signing #{options[:status]}."
        end
      end
    end
  end
end
