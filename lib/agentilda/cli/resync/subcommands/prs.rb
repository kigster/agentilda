# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda resync …`
    module Resync
      # `resync prs` — put an [NNN.MM] prefix on every pull request title.
      class Prs < Base
        desc "Add missing [NNN.MM] prefixes to pull request titles"

        option :commit, type: :boolean, default: false,
                        desc: "Actually retitle the pull requests (default: dry run)"
        option :state, default: "all", values: %w[open closed merged all],
                       desc: "Which pull requests to consider"
        option :adopt, type: :boolean, default: true,
                       desc: "Mint a retroactive plan folder for every pull request that resolves to none. --no-adopt flags them for a human instead"

        example [
          "                # show what would be retitled, and what would be adopted",
          "--state open    # only open pull requests",
          "--no-adopt      # never create a folder; flag the unresolvable ones",
          "--commit        # do it",
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          github = GitHub.new
          tree = tree_for(options)
          changes = Agentilda::Resync::Prs.new(tree:, github:,
                                               adopt: options.fetch(:adopt, true), root: File.dirname(tree.dir))
            .call(commit: commit?(options))

          if changes.empty?
            success("Every pull request title already carries a prefix.") unless quiet?(options)
            return
          end

          changes.each do |change|
            puts "#{change.number}\t#{change.new_title || "-"}\t#{change.reason}"
          end

          return if quiet?(options)

          report_pr_changes(changes, options)
        rescue Agentilda::Error => e
          error(e.message)
          exit 69
        end

        private

        # @param changes [Array]
        # @param options [Hash]
        # @return [void]
        def report_pr_changes(changes, options)
          applicable, flagged = changes.partition(&:applicable?)
          assumed = applicable.select(&:assumed?)

          applicable.each do |c|
            note = if c.adopted?
                paint("   (new plan)", :magenta)
              elsif c.assumed?
                paint("   (assumed)", :yellow)
              end
            say("##{c.number}  #{c.new_title}#{note}")
          end

          report_adoptions(applicable.select(&:adopted?), options)

          flagged.each { |c| say("##{c.number}  #{paint("SKIPPED", :red)} — #{c.reason}", bullet: "!") }

          if commit?(options)
            success("Retitled #{applicable.size} pull request#{"s" unless applicable.size == 1}.")
          else
            dry_run_footer(applicable.size, "retitle#{"s" unless applicable.size == 1}")
          end

          return if assumed.empty?

          warn("#{assumed.size} title#{"s" unless assumed.size == 1} would get " \
               "[#{Agentilda::NO_PLAN_PREFIX}] because no plan resolved.\n\n" \
               "That is an assertion about intent, and it is yours to make: check each one\n" \
               "before committing. A pull request that writes a plan's spec belongs to that\n" \
               "plan however its branch was named.")
        end

        # Creating folders is a bigger act than editing a title, so it is
        # reported separately rather than buried in the retitle list.
        #
        # @param adopted [Array]
        # @param options [Hash]
        # @return [void]
        def report_adoptions(adopted, options)
          return if adopted.empty?

          verb = commit?(options) ? "Created" : "Would create"
          info("#{verb} #{adopted.size} plan folder#{"s" unless adopted.size == 1} for pull " \
               "requests that resolved to no plan:\n\n" \
               "#{adopted.map { |c| "  #{c.ordinal}  ##{c.number}  #{c.title}" }.join("\n")}\n\n" \
               "Each holds its pull request and nothing else. Run `agentilda run --commit`\n" \
               "to have the specification written from what the pull request actually did.")
        end
      end
    end
  end
end
