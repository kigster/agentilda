# frozen_string_literal: true

module Agentilda
  module CLI
    module Mail
      # `agentilda mail send` — leave a message for the other half.
      class Send < Base
        include Locating

        desc "Append a message to a plan's mailbox"

        argument :body, type: :string, required: true, desc: "The message, quoted"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"
        option :from, required: true, desc: "The agent writing"
        option :to, required: true, desc: "The agent it is for"

        example [
          %(--plan 003 --from luke-backend --to rey-frontend "GET /returns/:id is up; errors come back as {error: {code, message}}")
        ]

        # @param body [String]
        # @param options [Hash]
        # @return [void]
        def call(body:, **options)
          quiet?(options)
          mailbox = mailbox_for(options)
          bus = bus_for(options)
          ordinal = Ordinal.parse(options[:plan].to_s)
          message = begin
            validate!(options, body)
            sent = payload(options, body)
            # Published first, folded in second. The bus is what reaches the
            # harness and the partner within the second; folding is how this
            # message gets into the file without waiting for somebody else
            # to do it, and doing both here means a send is complete whether
            # or not a run is watching.
            bus.publish(ordinal, sent)
            mailbox.sync!(bus, ordinal)
            # `sync!` folds in whatever the bus is currently holding, not
            # only this send. When a partner published concurrently,
            # `messages.last` can be theirs, and this command would report
            # somebody else's number and recipient as if it were its own.
            sent_message(mailbox, sent)
          rescue Agentilda::Error => e
            refuse(e.message, 64)
          end

          return if quiet?(options)

          # One line, not a box: an agent runs this between steps, and a
          # four-line frame around "#7 → rey-frontend" is noise it reads.
          UI.line("##{message.number} → #{message.to}, in #{File.basename(mailbox.dir)}/#{Mailbox::FILENAME}")
        end

        private

        # The same two refusals {Agentilda::Mailbox#append} makes, made here
        # because the bus carries a payload straight past it. A message with
        # no body or no recipient would otherwise be published, folded in,
        # numbered, and readable by nobody.
        #
        # @return [void]
        def validate!(options, body)
          raise Agentilda::Error, "a message needs a body" if body.to_s.strip.empty?
          return if [options[:from], options[:to]].all? { |n| n.to_s.match?(/\A\S+\z/) }

          raise Agentilda::Error, "a message needs --from and --to, each one agent name"
        end

        # @return [Hash]
        def payload(options, body)
          { "kind" => Mailbox::MESSAGE_KIND,
            "from" => options[:from],
            "to"   => options[:to],
            "body" => body.to_s.strip,
            "at"   => Time.now.iso8601 }
        end

        # The entry this send folded in, found by the fields it published
        # rather than assumed to be whatever is now last in the file.
        #
        # @param mailbox [Agentilda::Mailbox]
        # @param sent [Hash] this command's own {#payload}
        # @return [Agentilda::Mailbox::Message, nil]
        def sent_message(mailbox, sent)
          mailbox.messages.reverse_each.find do |m|
            m.from == sent["from"] && m.to == sent["to"] && m.body == sent["body"] && m.at == sent["at"]
          end
        end
      end
    end
  end
end
