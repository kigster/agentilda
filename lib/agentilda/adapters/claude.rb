# frozen_string_literal: true

module Agentilda
  module Adapters
    # `claude -p`, streaming JSON.
    class Claude < Base
      # Models by capability, cheapest first. Anything ranked above
      # {CEILING} is asked for as the ceiling instead: a run that quietly
      # spends Fable money on a task Opus does fine is a run nobody budgeted.
      LADDER = %w[haiku sonnet opus fable].freeze

      # The most expensive model any agent may run on.
      CEILING = "opus"

      # Flags that keep the operator's personal setup out of the agent. The
      # project's CLAUDE.md and settings still load. Measured on a one-word
      # prompt: 143 tools, 60 MCP servers, 358 skills and 17 hook events
      # without these; 28 tools and none of the rest with them, at three
      # quarters of the context and half the start-up time.
      LEAN = ["--setting-sources", "project,local",
              "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
              "--disable-slash-commands"].freeze

      # @param invocation [Agentilda::Adapters::Invocation]
      # @return [Array<String>]
      def argv(invocation)
        # `--include-partial-messages` is what the token meter runs on. Without
        # it the stream reports a settled input count and a placeholder output
        # count — 2 for a four-thousand-token answer — and a spinner counting
        # what came back would read zero all run.
        argv = ["claude", "-p", invocation.prompt, "--add-dir", invocation.root,
                "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--brief"]
        argv += LEAN if invocation.lean
        argv += ["--disallowedTools", invocation.denied_tools.join(",")] unless invocation.denied_tools.empty?
        argv += ["--allowedTools", invocation.allowed_tools.join(",")] unless invocation.allowed_tools.empty?
        model = model(invocation.model)
        argv += ["--model", model] if model
        argv += ["--effort", invocation.effort] if invocation.effort
        argv
      end

      # @return [Agentilda::Execution::Transcript]
      def transcript(trace: nil, &) = Execution::Transcript.new(trace:, &)

      # @param model [String, nil] an alias (`sonnet`) or a full id
      #   (`claude-fable-5-1`)
      # @return [String, nil]
      def model(model)
        return model if model.nil? || model.to_s.empty?

        rank = LADDER.index { |tier| model.to_s.include?(tier) }
        rank && rank > LADDER.index(CEILING) ? CEILING : model.to_s
      end

      # @return [Boolean]
      def enforces_tool_denial? = true
    end
  end
end
