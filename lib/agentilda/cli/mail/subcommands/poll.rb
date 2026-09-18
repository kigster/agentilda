# frozen_string_literal: true

module Agentilda
  module CLI
    module Mail
      # `agentilda mail poll` — what a Claude Code hook runs after every one
      # of an agent's tool calls.
      #
      # `mail read` is a request in a prompt: the agent runs it when it
      # decides a step was significant, and "significant" is its own call.
      # This is the same drain, run by the runtime instead, so a message
      # reaches an agent at its next tool call whether or not it remembered
      # to look. It does not replace the control file — an agent four
      # minutes into one `Bash` call is unreachable either way, which is
      # what {Agentilda::Control::GRACE} is for.
      #
      # Everything here is subordinate to not disrupting the agent. It runs
      # after every tool call, so it prints little, and it never fails:
      # a hook that raises or floods is a hook that breaks each of an
      # agent's steps rather than one of them.
      class Poll < Base
        include Locating

        # Shown when `--limit` is not given. `dry-cli` fills its own default
        # in only when it parses a command line, and a hook is not the only
        # caller, so the number lives here as well.
        LIMIT = 5

        desc "Print an agent's waiting messages, for a hook to run after every tool call"

        option :plan, required: true, desc: "Which plan: NNN or NNN.MM"
        option :for, required: true, desc: "The agent being polled for"
        option :limit, default: LIMIT.to_s, desc: "At most this many messages, newest last"

        example [
          "--plan 003 --for luke-backend  # what a PostToolUse hook runs"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          waiting = unread(options)
          return if waiting.empty?

          puts "#{waiting.size} unread in this plan's mailbox. Read and acknowledge each one:"
          waiting.each { |m| puts "  ##{m.number} from #{m.from}: #{summarize(m.body)}" }
        rescue StandardError, SystemExit
          # A hook's job is to be ignorable. Anything wrong here — no Redis,
          # no plan, a file half-written — costs the agent one notification,
          # and must not cost it the tool call it just made. `SystemExit` is
          # caught with the rest because the refusals underneath this raise
          # it, and a hook that exits non-zero is one the runtime reports
          # against every tool call the agent makes.
          nil
        end

        private

        # @param options [Hash]
        # @return [Array<Agentilda::Mailbox::Message>]
        def unread(options)
          limit = options.fetch(:limit, LIMIT).to_i
          synced_mailbox(options).unread(options[:for]).last(limit.positive? ? limit : LIMIT)
        end

        # One line each. The agent reads the message itself with `mail
        # read`; this only has to be enough to make it want to.
        #
        # @param body [String]
        # @return [String]
        def summarize(body)
          first = body.to_s.lines.first.to_s.strip
          first.length > 120 ? "#{first[0, 119]}…" : first
        end
      end
    end
  end
end
