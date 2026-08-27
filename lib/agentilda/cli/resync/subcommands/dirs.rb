# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda resync …`
    module Resync
      # `resync dirs` — reconcile folder names with folder contents.
      class Dirs < Base
        desc "Rename plan folders so the name matches the contents and the NNN.MM form"

        option :commit, type: :boolean, default: false,
                        desc: "Actually rename the folders (default: dry run)"

        example [
          "                # show what would be renamed",
          "--commit        # do it",
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          changes = Agentilda::Resync::Dirs.new(tree: tree_for(options))
            .call(commit: commit?(options))

          if changes.empty?
            success("Every folder is already named NNN.MM-<emoji>-<slug> and the emoji matches.") unless quiet?(options)
            return
          end

          changes.each do |change|
            puts "#{change.dirname}\t#{File.basename(change.target)}\t#{change.reason}"
            next if quiet?(options)

            say("#{paint(change.dirname, :bright_black)} → #{File.basename(change.target)}")
            say("  #{paint(change.reason, :yellow)}", bullet: " ")
          end

          return if quiet?(options)

          if commit?(options)
            success("Renamed #{changes.size} folder#{"s" unless changes.size == 1}.")
          else
            dry_run_footer(changes.size, "rename#{"s" unless changes.size == 1}")
          end
        end
      end
    end
  end
end
