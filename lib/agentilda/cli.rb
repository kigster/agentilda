# frozen_string_literal: true

require "dry/cli/autocomplete/command"

# One file per command, `subcommands/` under the prefixed ones. Base carries
# the shared flags and plumbing, so it loads first; the rest only meet each
# other here, at registration.
require_relative "cli/base"
require_relative "cli/create/create"
require_relative "cli/index/index"
require_relative "cli/list_plans/list_plans"
require_relative "cli/resync/subcommands/dirs"
require_relative "cli/resync/subcommands/prs"
require_relative "cli/linear/linear"
require_relative "cli/linear/subcommands/projects"
require_relative "cli/linear/subcommands/import"
require_relative "cli/docs/docs"
require_relative "cli/run/run"
require_relative "cli/unblock/unblock"
require_relative "cli/version/version"
require_relative "cli/states/states"
require_relative "cli/agents/subcommands/list"
require_relative "cli/agents/subcommands/describe"

module Agentilda
  # The command line. Every command is a thin shell over one library class:
  # it parses flags, calls one object, and prints the result.
  #
  # Two conventions hold throughout:
  #
  #   * The deliverable goes to STDOUT, progress and boxes go to STDERR, so
  #     every command composes in a pipe.
  #   * Anything that writes to disk or to GitHub is DRY RUN by default and
  #     needs `--commit`. Folder names and pull request titles are joined on by
  #     branches, `pull-requests.md` and merged history; changing one silently
  #     is how a plan ends up filed under work it did not do.
  module CLI
    extend Dry::CLI::Registry

    register "create", Create, aliases: %w[new c]
    # Renamed from `status`, which read as "is the tool OK?" rather than "what
    # plans are there?". The old spellings stay registered: other repos, agent
    # prompts and scripts call this by name.
    register "list-plans", ListPlans, aliases: %w[status st]
    register "run", Run
    register "unblock", Unblock
    register "docs", Docs
    register "states", States, aliases: %w[diagram]
    register "index", Index, aliases: %w[idx]
    register "version", Version, aliases: %w[--version -v]

    register "agents" do |prefix|
      prefix.register "list", Agents::List, aliases: %w[ls]
      prefix.register "describe", Agents::Describe, aliases: %w[show]
    end

    # `describe <name>` without the `agents` in front of it. The bare verb is
    # how people ask for this out loud, and a near miss that prints usage is a
    # worse answer than the thing they wanted.
    register "describe", Agents::Describe

    register "resync" do |prefix|
      prefix.register "dirs", Resync::Dirs
      prefix.register "prs", Resync::Prs
    end

    register "linear" do |prefix|
      prefix.register "import", Linear::Import
      prefix.register "projects", Linear::Projects
    end

    register "completion", ::Dry::CLI::Autocomplete::Command[::Agentilda::CLI]
  end
end
