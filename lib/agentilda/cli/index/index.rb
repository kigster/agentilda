# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda index` — the plans as one browsable page.
    class Index < Base
      desc "Write .plans/INDEX.md: every plan, its goal, its pull requests and its documents"

      option :output, aliases: ["-o"],
                      desc: "Write somewhere other than <plans>/INDEX.md; - for STDOUT"
      option :project, aliases: ["-p"],
                       desc: "Heading for the page, default: the repository's directory name"

      example [
        "                     # write .plans/INDEX.md",
        "-o -                 # print it instead",
        "-p 'Equilibris App'  # override the heading",
      ]

      # @param options [Hash]
      # @return [void]
      def call(**options)
        index = Agentilda::Index.new(tree: tree_for(options), project: options[:project])

        if options[:output] == "-"
          $stdout.write(index.render)
          return
        end

        path = index.write(options[:output])
        puts path
        return if quiet?(options)

        success("Wrote #{path}\n\nRegenerate it after any `resync dirs`, which renames folders\nand would otherwise leave every link here pointing at nothing.")
      end
    end
  end
end
