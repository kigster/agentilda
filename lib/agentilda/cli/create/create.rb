# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda create <words…>` — backs /spec-create.
    class Create < Base
      desc "Create the next numbered plan folder"

      argument :words, type: :array, required: true,
        desc: "The topic, two to five words; becomes the folder slug"

      option :after, aliases: ["-a"],
        desc: "Create a retroactive plan in the gap after this plan, e.g. 002"
      option :status, aliases: ["-s"],
        desc: "Open in a state other than the default"
      option :prs, aliases: ["--pr"],
        desc: "Document work that already shipped: pull request numbers or URLs, comma separated. Requires --after"
      option :spec, type: :boolean, default: true,
        desc: "With --prs, write spec.md from what the pull requests did. --no-spec records them and stops, which is fast and offline"
      option :draft, type: :boolean, default: true,
        desc: "For a new feature (no --prs), attempt spec.md's four headings from project context via `claude`. --no-draft leaves them bare"
      option :open, type: :boolean, default: true,
        desc: "Open the new spec.md in the system editor when done (macOS `open`). --no-open leaves it for you to open"

      # noinspection RubyMismatchedArgumentType
      example [
        "tax rule dsl                        # 003.00-⚪️--tax-rule-dsl, spec.md scaffolded and drafted",
        "tax rule dsl --no-draft --no-open   # scaffold only, nothing shelled out, nothing opened",
        "--after 002 schedule k1             # 002.01-🕰️-schedule-k1 (documented after the fact)",
        "--after 018 --prs 12,15 verify      # …and write spec.md from what those PRs did",
        "--after 018 --pr https://…/pull/12 verify",
        "--status ready billing sync         # opens at ⭐️ instead of ⚪️"
      ]

      # @param words [Array<String>]
      # @param options [Hash]
      # @return [void]
      def call(words:, **options)
        dir = options.fetch(:dir, Agentilda::PLANS_DIR)
        FileUtils.mkdir_p(dir)

        prs = fetch_prs(options)
        result = Creator.new(dir:).create(words:, after: options[:after],
          status: options[:status], prs:)

        result.either(
          ->(path) { created(path, prs, options) },
          ->(message) { refuse("Could not create the plan:\n#{message}", 65) }
        )
      end

      private

      # A retroactive plan documents work that landed *somewhere* in the
      # sequence, and only its author knows where. Guessing would put the
      # number — the one thing that never changes — in the wrong place.
      #
      # @param options [Hash]
      # @return [Array<Hash>, nil]
      def fetch_prs(options)
        return nil unless options[:prs]

        unless options[:after]
          refuse("--prs documents work that already shipped;\n" \
                 "name the plan it landed after with --after, e.g. --after 018", 64)
        end

        GitHub.new.pull_requests(GitHub.parse_refs(options[:prs]))
      rescue Agentilda::Error => e
        refuse("Could not read the pull requests:\n#{e.message}", 65)
      end

      # A plan with recorded pull requests already has its facts — hand it to
      # the writer that reconstructs a specification from a diff. One without
      # them does not exist yet, and reconstructing is not the job; {#brief} is.
      #
      # @param path [String]
      # @param prs [Array<Hash>, nil]
      # @param options [Hash]
      # @return [void]
      def created(path, prs, options)
        from_prs = prs && !prs.empty?
        path = if from_prs
                 synthesize(path, options) if options.fetch(:spec, true)
               else
                 brief(path, options)
        end || path
        puts path
        return if quiet?(options)

        feature = Feature.parse(path)
        success("Created #{File.basename(path)}\n\n" \
                "#{feature.status.emoji} #{feature.status.label} — #{feature.status.note}\n" \
                "#{next_step(path, feature, from_prs:)}")
      end

      # Hand the folder to the writer that already knows how to write a
      # retroactive specification, then let `resync dirs` decide what the
      # folder has become — 🕰️ is only true while there is no `spec.md`.
      #
      # @param path [String]
      # @param options [Hash]
      # @return [String] the folder's path, which the resync may have renamed
      def synthesize(path, options)
        agent = Agentilda::Agents.new.find(Agentilda::RETROACTIVE_WRITER) or return path
        root = options[:root] || File.dirname(path, 2)

        ok, note = UI.spinning("Writing spec.md from #{File.basename(path)}") {
          Executor.new(root:).call(agent, Subject.new(Feature.parse(path)))
        }
        warn_about(note) unless ok

        settle(path)
      end

      # A folder with no pull requests to reconstruct from is a feature that
      # does not exist yet. {Brief} writes the four headings a human still has
      # to answer, makes a best-effort pass at them from what the project
      # already has on disk, and — unless told not to — opens the result for
      # a human to finish. The folder's state never moves: ⚪️ New only ever
      # claimed that a specification exists, not that it is complete.
      #
      # @param path [String]
      # @param options [Hash]
      # @return [String] +path+, unchanged
      def brief(path, options)
        feature = Feature.parse(path)
        return path if feature.status.key == :retroactive

        root = options[:root] || File.dirname(path, 2)
        brief = Brief.new(path:, title: feature.title, root:)
        brief.write_scaffold!

        if options.fetch(:draft, true)
          ok, note = UI.spinning("Drafting spec.md from project context") { brief.attempt! }
          warn_about_draft(note) unless ok
        end

        open_spec(brief.spec_path) if options.fetch(:open, true)
        path
      end

      # @param spec_path [String]
      # @return [void]
      def open_spec(spec_path)
        return unless macos?

        system("open", spec_path, out: File::NULL, err: File::NULL)
      end

      # `open` is a macOS command; anywhere else the viewer step is skipped
      # rather than failed. A named seam so a spec can assert the viewer was
      # asked for without inheriting the platform CI happens to run on.
      #
      # @return [Boolean]
      def macos? = RbConfig::CONFIG["host_os"].to_s.match?(/darwin/)

      # @param path [String]
      # @return [String] where the folder ended up
      def settle(path)
        tree = Tree.new(dir: File.dirname(path))
        change = Agentilda::Resync::Dirs.new(tree:).call(commit: true)
          .find { |c| c.source == path }
        change ? change.target : path
      end

      # @param note [String]
      # @return [void]
      def warn_about(note)
        error("The folder was created, but spec.md was not written:\n#{note}\n\n" \
              "The pull requests are recorded. Run `agentilda run --commit` to retry.")
      end

      # @param note [String]
      # @return [void]
      def warn_about_draft(note)
        error("spec.md was scaffolded, but the drafting attempt did not finish:\n#{note}\n\n" \
              "The four headings are there, empty. Fill them in by hand, or hand off to leah-researcher.")
      end

      # @param path [String]
      # @param feature [Agentilda::Feature]
      # @return [String]
      def next_step(path, feature, from_prs:)
        spec = File.join(File.basename(path), "spec.md")
        return "Next: write #{spec}" unless feature.status.key == :new && File.file?(File.join(path, "spec.md"))
        return "Next: read #{spec} — it was written from the pull requests, so check it against what actually shipped" if from_prs

        "Next: fill in the four headings in #{spec}, then hand off to leah-researcher"
      end
    end
  end
end
