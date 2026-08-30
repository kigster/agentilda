# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda docs` — regenerate the conventions document.
    class Docs < Base
      desc "Generate the conventions document from the state machine itself"

      option :output, aliases: ["-o"], desc: "Write here instead of STDOUT",
        default: "#{ENV["HOME"]}/docs/WORKFLOW.md"

      example ["", "-o tentative-new-plan.md"]

      # @param options [Hash]
      # @return [void]
      def call(**options)
        document = Documentation.new.render

        if (path = options[:output])
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, document)
          system("command -v mdformat>/dev/null 2>&1 && mdformat --wrap no #{path} 2>/dev/null")
          success("created workflow description in [#{path}]") unless quiet?(options)
        else
          $stdout.write(document)
        end
      end
    end
  end
end
