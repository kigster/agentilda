# frozen_string_literal: true

module Agentilda
  module CLI
    module Mail
      # `agentilda mail ack` — the reader saying it has read one message.
      #
      # Delivery is not reading. Whatever carries a message can report that
      # the bytes arrived; only the agent it was addressed to can say it
      # took the message in, which is why this is a separate call the
      # agent's prompt tells it to make immediately on reading.
      class Ack < Base
        include Locating

        desc "Mark a message in a plan's mailbox as read"

        argument :number, type: :integer, required: true, desc: "The message number, as `mail read` shows it"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"
        option :by, required: true, desc: "The agent acknowledging; must be who the message was addressed to"

        example [
          "7 --plan 003 --by rey-frontend  # rey has read message #7"
        ]

        # @param number [Integer]
        # @param options [Hash]
        # @return [void]
        def call(number:, **options)
          quiet?(options)
          mailbox = synced_mailbox(options)
          message = begin
            mailbox.ack(number.to_i, by: options[:by])
          rescue Agentilda::Error => e
            refuse(e.message, 64)
          end

          return if quiet?(options)

          UI.line("##{message.number} read by #{message.to}")
        end
      end
    end
  end
end
