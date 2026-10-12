# frozen_string_literal: true

require "dry/cli"

module Agentilda
  module CLI
    # Shared flags and the plumbing every command needs.
    class Base < Dry::CLI::Command
      include UI

      # dry-cli gathers every token a command did not declare an argument for
      # into :args, and hands it over without a word. `tilda docs
      # .plans/README.md` — the `-o` forgotten — therefore ran with every
      # default, wrote the conventions to the default path, and printed
      # success for a file the caller never named.
      #
      # Prepended rather than called from each `call`, because the command
      # that forgets this check is the one that needed it.
      module RefuseStrayArguments
        # @param options [Hash]
        # @return [void]
        def call(**options)
          stray = Array(options[:args]) - self.class.arguments.flat_map { Array(options[it.name.to_sym]) }
          unless stray.empty?
            refuse("This command takes no argument like #{stray.join(" ")}.\n" \
                   "An option it does take may be the one you meant: run it with -h.",
              64)
          end

          super
        end
      end

      def self.inherited(klass)
        super
        klass.prepend(RefuseStrayArguments)
        klass.option :dir,
          default: Agentilda::PLANS_DIR,
          aliases: ["-D"],
          desc:    "The .plans directory"
        klass.option :quiet,
          type:    :boolean,
          default: false,
          aliases: ["-q"],
          desc:    "Suppress progress output on STDERR"
      end

      # Declares `-n` / `--dry-run` on a command that changes something.
      #
      # @param desc [String] what the preview prints instead of doing
      # @return [void]
      def self.dry_run_option(desc)
        option :dry_run,
          type:    :boolean,
          default: false,
          aliases: ["-n"],
          desc:
      end

      private

      # @param options [Hash]
      # @return [Agentilda::Plans::Tree]
      def tree_for(options)
        tree = Plans.tree(options.fetch(:dir, Agentilda::PLANS_DIR))
        unless tree.exist?
          refuse("No #{Agentilda::PLANS_DIR} directory at\n#{tree.dir}\n\n" \
                 "Run this from the project root, or pass -D.",
            66)
        end
        tree
      end

      # Report and stop, in the shape every refusal here takes. The statuses
      # follow sysexits where one fits: 64 usage, 65 bad data, 66 no input,
      # 69 a service (GitHub, Linear) refused us.
      #
      # @param message [String]
      # @param status [Integer]
      # @return [void] never returns
      def refuse(message, status)
        error(message)
        exit status
      end

      # @param options [Hash]
      # @return [Boolean]
      def quiet?(options)
        quiet = options.fetch(:quiet, false)
        UI.quiet = quiet
        quiet
      end

      # `-n` / `--dry-run`. A command does the work it is named for, so the
      # preview is what has to be asked for, never the work itself.
      #
      # @param options [Hash]
      # @return [Boolean]
      def dry_run?(options) = options.fetch(:dry_run, false)

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
        names = Execution::Executor.foreign_credentials
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

        warn("#{count} #{what} pending — nothing was changed.\nRe-run without --dry-run to apply.")
      end
    end
  end
end
