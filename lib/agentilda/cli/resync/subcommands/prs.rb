# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda resync …`
    module Resync
      # `resync prs` — file every pull request under the plan it implements.
      class Prs < Base
        desc "File every pull request title under its plan, judged by jabba-resolver where the branch and diff do not say"

        option :commit, type: :boolean, default: false,
          desc: "Actually retitle, mint folders and rewrite pull-requests.md (default: dry run, which still consults the model)"
        option :state, default: "all", values: %w[open closed merged all],
          desc: "Which pull requests to consider"
        option :adopt, type: :boolean, default: true,
          desc: "Mint a plan folder for every pull request that resolves to none. --no-adopt flags them for a human instead"
        option :force, type: :boolean, default: false,
          desc: "Strip every existing prefix, numbered ones included, and re-judge the lot"
        option :fake_github_path, aliases: ["--fake-github-path"],
          desc: "Read pull requests from a folder of markdown files instead of `gh`, and write retitles back into them"
        option :jobs, type: :integer, aliases: ["-j"],
          desc: "How many judgments run at once (default: cores minus two)"

        example [
          "                          # judge, and show what would change and what it cost",
          "--state open              # only open pull requests",
          "--force                   # re-judge titles that already carry a number",
          "--no-adopt                # never create a folder; flag the unresolvable ones",
          "--fake-github-path .prs   # a folder of markdown files stands in for GitHub",
          "--commit                  # do it"
        ]

        # @param options [Hash]
        # @return [void]
        def call(**options)
          tree = tree_for(options)
          resync = build(tree, options)
          credentials_warning unless quiet?(options)
          changes = resync.call(commit: commit?(options))

          if changes.empty?
            success("Every pull request title already carries a prefix.") unless quiet?(options)
            return
          end

          changes.each do |change|
            puts "#{change.number}\t#{change.new_title || "-"}\t#{change.reason}"
          end

          return if quiet?(options)

          report_pr_changes(changes, options)
          report_spend(resync.spent)
        rescue Agentilda::Error => e
          refuse(e.message, 69)
        end

        private

        # @param tree [Agentilda::Tree]
        # @param options [Hash]
        # @return [Agentilda::Resync::Prs]
        def build(tree, options)
          github = github_for(options)
          root = File.dirname(tree.dir)
          resolver = Agentilda::Resolver.new(tree:, root:, model: options[:model],
            jobs: options[:jobs] || UI.default_jobs,
            cache_dir: options.fetch(:cache, true) ? File.join(Agentilda::Resolver::CACHE_ROOT, github.slug, "verdicts") : nil)
          Agentilda::Resync::Prs.new(tree:, github:, resolver:, root:,
            adopt: options.fetch(:adopt, true), force: options.fetch(:force, false),
            state: options.fetch(:state, "all"))
        end

        # @param options [Hash]
        # @return [Agentilda::GitHub, Agentilda::FakeGitHub]
        def github_for(options)
          path = options[:fake_github_path]
          path ? FakeGitHub.new(dir: path) : GitHub.new
        end

        # @param changes [Array]
        # @param options [Hash]
        # @return [void]
        def report_pr_changes(changes, options)
          applicable, rest = changes.partition(&:applicable?)
          flagged = rest.select(&:ambiguous?)
          unchanged = rest.select(&:unchanged?)

          applicable.each do |c|
            say("##{c.number}  #{c.new_title}#{note_for(c)}")
            say("  #{paint(c.reason, :bright_black)}", bullet: " ")
          end

          report_adoptions(applicable.select(&:adopted?), options)
          flagged.each { |c| say("##{c.number}  #{paint("SKIPPED", :red)} — #{c.reason}", bullet: "!") }
          unless unchanged.empty?
            say("#{unchanged.size} title#{"s" unless unchanged.size == 1} already say#{"s" if unchanged.size == 1} what the pipeline says; left alone.", bullet: "·")
          end

          if commit?(options)
            success("Retitled #{applicable.size} pull request#{"s" unless applicable.size == 1}.")
          else
            dry_run_footer(applicable.size, "retitle#{"s" unless applicable.size == 1}")
          end
        end

        # @param change [Agentilda::Resync::Prs::Change]
        # @return [String]
        def note_for(change)
          case change.kind
          when :timeline then paint("   (new sibling plan)", :magenta)
          when :straggler then paint("   (new plan)", :magenta)
          when :dev then paint("   (developer work)", :yellow)
          when :judged then paint("   (judged)", :cyan)
          else ""
          end
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
          info("#{verb} #{adopted.size} plan folder#{"s" unless adopted.size == 1}:\n\n" \
               "#{adopted.map { |c| "  #{c.ordinal}  ##{c.number}  #{c.title}" }.join("\n")}\n\n" \
               "Each holds its pull request, and a spec.md and plan.md carrying the pull\n" \
               "request's own description.")
        end

        # A command that spends money says how much.
        #
        # @param spent [Hash]
        # @return [void]
        def report_spend(spent)
          return if spent[:asked].zero? && spent[:cached].zero?

          info(format("%s judged %d pull request%s (%d from cache): %s tokens in, %s out, $%.4f",
            Agentilda::Resolver::AGENT_NAME, spent[:asked] + spent[:cached],
            (spent[:asked] + spent[:cached] == 1) ? "" : "s", spent[:cached],
            spent[:up].to_s.reverse.scan(/\d{1,3}/).join(",").reverse,
            spent[:down].to_s.reverse.scan(/\d{1,3}/).join(",").reverse, spent[:cost]))
        end
      end
    end
  end
end
