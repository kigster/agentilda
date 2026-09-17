# frozen_string_literal: true

module Agentilda
  module CLI
    module Mail
      # `agentilda mail state` — where an agent got to, recorded so the run
      # that picks the plan up can act on it.
      #
      # An agent asked to stop used to leave a `RESUME:` message, which is
      # prose the next round had to read and believe. This is the same thing
      # in fields, so the next round can check what it names rather than
      # take it on trust.
      #
      # It is the agent's own account, which always beats the harness's.
      # The harness writes one only for an agent that was terminated before
      # it could run this, or that died outright.
      class State < Base
        include Locating

        # Between items in `--done` and `--remaining`. A semicolon, because
        # a comma is ordinary inside a sentence about what was finished.
        SEPARATOR = ";"

        desc "Record where an agent got to, for the round that picks this plan up"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"
        option :agent, required: true, desc: "The agent describing itself"
        option :round, required: true, desc: "Which round, as the harness counts them"
        option :status,
          default: "Interrupted",
          values:  Agentilda::Ledger::STATUSES,
          desc:    "What the agent is claiming"
        option :done, desc: "What is finished, items separated by #{SEPARATOR}"
        option :remaining, desc: "What is not, items separated by #{SEPARATOR}"
        option :next_step, desc: "The exact next thing to do, one line"

        example [
          %(--plan 003 --agent luke-backend --round 1 --done "schema;specs green" ) +
          %(--remaining "wire the dispatcher" --next-step "bundle exec rspec spec/agentilda/ledger_spec.rb")
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          quiet?(options)
          mailbox = mailbox_for(options)
          bus = bus_for(options)
          ordinal = Ordinal.parse(options[:plan].to_s)
          bus.publish(ordinal, payload(options))
          mailbox.sync!(bus, ordinal)

          return if quiet?(options)

          UI.line("#{options[:agent]}: #{options[:status]}, round #{options[:round]} recorded for the next run")
        end

        private

        # @param options [Hash]
        # @return [Hash]
        def payload(options)
          { "kind"      => Mailbox::STATE_KIND,
            "agent"     => options[:agent],
            "source"    => Mailbox::BY_AGENT,
            "at"        => Time.now.iso8601,
            "round"     => options[:round].to_i,
            "status"    => options.fetch(:status, "Interrupted"),
            "done"      => items(options[:done]),
            "remaining" => items(options[:remaining]),
            "next_step" => options[:next_step].to_s }
        end

        # @param text [String, nil]
        # @return [Array<String>]
        def items(text) = text.to_s.split(SEPARATOR).map(&:strip).reject(&:empty?)
      end
    end
  end
end
