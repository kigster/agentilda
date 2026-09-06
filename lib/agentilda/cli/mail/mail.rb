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
      end
    end
  end
end
