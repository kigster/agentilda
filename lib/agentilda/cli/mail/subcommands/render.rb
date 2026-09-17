# frozen_string_literal: true

module Agentilda
  module CLI
    module Mail
      # `agentilda mail render` — the exchange as a person reads it.
      #
      # The mailbox is JSON so that an agent does no parsing. This is the
      # other half of that trade: the Markdown nobody has to store, made on
      # demand. It goes to STDOUT, which carries the deliverable, so it
      # pipes into a file or a pager without a flag for either.
      class Render < Base
        include Locating

        desc "Print a plan's mailbox as Markdown"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"

        example [
          "--plan 003                       # the whole exchange",
          "--plan 003 > mailbox.md          # keep a copy beside the plan"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          quiet?(options)
          puts synced_mailbox(options).render
        end
      end
    end
  end
end
