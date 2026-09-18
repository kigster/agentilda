# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda mail` — the two halves of a pair talking through the plan
    # folder. See {Agentilda::Mailbox} for why a file rather than a session.
    module Mail
      # Both subcommands name a plan and need its folder.
      module Locating
        private

        # An unknown number is refused rather than given an empty mailbox:
        # an agent polling the wrong plan for a whole round would read
        # silence as "my partner has nothing to say".
        #
        # @param options [Hash]
        # @return [Agentilda::Mailbox]
        def mailbox_for(options)
          tree = tree_for(options)
          ordinal = Ordinal.parse(options[:plan].to_s)
          subject = ordinal && tree.find(ordinal)
          unless subject
            refuse("No plan #{options[:plan]} in #{tree.dir}.\n\nKnown: #{tree.ordinals.join(", ")}", 66)
          end

          Mailbox.new(dir: subject.feature.path)
        end

        # An unknown number is refused rather than given an empty mailbox,
        # and so is an unreachable Redis. A transport that quietly is not
        # there looks exactly like a partner with nothing to say, which is
        # the one thing a mailbox must never look like.
        #
        # @param options [Hash]
        # @return [Agentilda::Bus]
        def bus_for(options)
          bus = Bus.new(root: tree_for(options).dir)
          unless bus.reachable?
            refuse("Redis is not answering at #{ENV.fetch("REDIS_URL", "its default address")}.\n\n" \
                   "Agents reach each other through it; start it and run this again.",
              69)
          end

          bus
        rescue LoadError => e
          refuse("The redis gem is not installed: #{e.message}", 69)
        end

        # Everything the bus has carried since the last read, folded into
        # the file before anybody reads it.
        #
        # @param options [Hash]
        # @return [Agentilda::Mailbox]
        def synced_mailbox(options)
          mailbox_for(options).tap { |mailbox| mailbox.sync!(bus_for(options), Ordinal.parse(options[:plan].to_s)) }
        end
      end
    end
  end
end
