# frozen_string_literal: true

module Agentilda
  module CLI
    module Resync
      # `agentilda resync` — folders, then titles, then folders again.
      #
      # The order is the dependency order. `prs` reads plan numbers out of
      # folder names, so the folders must be canonical first. `prs` then
      # rewrites `pull-requests.md`, and a folder's state is derived from the
      # files it holds, so its name may be wrong again afterwards — hence
      # the second `dirs`. Either subcommand still runs alone.
      class All < Base
        desc "Run resync dirs, then resync prs, then resync dirs again"

        option :commit, type: :boolean, default: false,
          desc: "Actually rename, retitle and rewrite (default: dry run)"
        option :state, default: "all", values: %w[open closed merged all],
          desc: "Which pull requests to consider"
        option :adopt, type: :boolean, default: true,
          desc: "Mint a plan folder for every pull request that resolves to none"
        option :force, type: :boolean, default: false,
          desc: "Strip every existing prefix and re-judge the lot"
        option :fake_github_path, aliases: ["--fake-github-path"],
          desc: "A folder of markdown files standing in for GitHub"
        option :model, desc: "Model for jabba-resolver, overriding its frontmatter"
        option :jobs, type: :integer, aliases: ["-j"], desc: "How many judgments run at once"
        option :cache, type: :boolean, default: true, desc: "Reuse cached verdicts; --no-cache asks afresh"

        example [
          "                # preview all three steps",
          "--commit        # do it"
        ]

        # Flags each child understands. Anything else typed here is refused
        # by dry-cli before this runs.
        DIRS_OPTIONS = %i[dir quiet commit].freeze
        PRS_OPTIONS = %i[dir quiet commit state adopt force fake_github_path model jobs cache].freeze

        # @param options [Hash]
        # @return [void]
        def call(**options)
          step("resync dirs") { Dirs.new.call(**options.slice(*DIRS_OPTIONS)) }
          step("resync prs") { Prs.new.call(**options.slice(*PRS_OPTIONS)) }
          step("resync dirs, again") { Dirs.new.call(**options.slice(*DIRS_OPTIONS)) }
        end

        private

        # A child that exits has refused; the composite stops there rather
        # than matching titles against a half-renamed tree.
        #
        # @param name [String]
        # @return [void]
        def step(name)
          say(paint("── #{name} ──", :bold), bullet: " ") unless UI.quiet
          yield
        rescue SystemExit => e
          raise if e.success?

          error("#{name} failed; the remaining steps were not run.")
          raise
        end
      end
    end
  end
end
