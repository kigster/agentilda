# frozen_string_literal: true

module Agentilda
  module CLI
    # Shared flags and the plumbing every command needs.
    class Base < Dry::CLI::Command
      include UI

      def self.inherited(klass)
        super
        klass.option :dir, default: Agentilda::PLANS_DIR, aliases: ["-D"],
                           desc: "The .plans directory"
        klass.option :quiet, type: :boolean, default: false, aliases: ["-q"],
                             desc: "Suppress progress output on STDERR"
      end

      private

      # @param options [Hash]
      # @return [Agentilda::Tree]
      def tree_for(options)
        tree = Tree.new(dir: options.fetch(:dir, Agentilda::PLANS_DIR))
        unless tree.exist?
          error("No #{Agentilda::PLANS_DIR} directory at\n#{tree.dir}\n\n" \
                "Run this from the project root, or pass -D.")
          exit 66
        end
        tree
      end

      # @param options [Hash]
      # @return [Boolean]
      def quiet?(options)
        quiet = options.fetch(:quiet, false)
        UI.quiet = quiet
        quiet
      end

      # @param options [Hash]
      # @return [Boolean]
      def commit?(options) = options.fetch(:commit, false)

      # `claude` prefers a credential in the environment to a claude.ai login,
      # so a project `.env` that direnv loads on `cd` can redirect every agent
      # a run spawns to a key meant for the application itself.
      #
      # Say it once, before the run starts, because the failure arrives three
      # minutes later, once per agent, and reads like an agent problem rather
      # than an environment one.
      #
      # @return [void]
      def credentials_warning
        names = Executor.foreign_credentials
        return if names.empty?

        one = names.size == 1
        warn("#{names.join(" and ")} #{one ? "is" : "are"} set in this shell, so every agent authenticates " \
             "with #{one ? "it" : "them"} rather than with your claude.ai login.\n" \
             "A stale one fails every agent in the run with `401 API key is invalid`, " \
             "three minutes at a time.\n" \
             "If it came from a project .env, run `unset #{names.join(" ")}` first.")
      end

      # The line every dry run ends with, so nobody mistakes a preview for the
      # thing having happened.
      #
      # @param count [Integer] how much work is pending
      # @param what [String]
      # @return [void]
      def dry_run_footer(count, what)
        return if count.zero?

        warn("#{count} #{what} pending — nothing was changed.\nRe-run with --commit to apply.")
      end
    end
  end
end
