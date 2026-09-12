# frozen_string_literal: true

require_relative "dry/cli/banner"

require "dry/inflector"
require "fileutils"
require "shellwords"
require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  "api"        => "API",
  "cli"        => "CLI",
  "github"     => "GitHub",
  "issue"      => "Issues",
  "list_plans" => "ListPlans",
  "unit"       => "Units",
  "ui"         => "UI"
)
loader.collapse("#{__dir__}/agentilda/cli/create")
loader.collapse("#{__dir__}/agentilda/cli/docs")
loader.collapse("#{__dir__}/agentilda/cli/index")
loader.collapse("#{__dir__}/agentilda/cli/list_plans")
loader.collapse("#{__dir__}/agentilda/cli/run")
loader.collapse("#{__dir__}/agentilda/cli/states")
loader.collapse("#{__dir__}/agentilda/cli/unblock")
loader.collapse("#{__dir__}/agentilda/cli/version")
loader.collapse("#{__dir__}/agentilda/cli/worktree")
loader.collapse("#{__dir__}/agentilda/cli/agents/subcommands")
loader.collapse("#{__dir__}/agentilda/cli/linear/subcommands")
loader.collapse("#{__dir__}/agentilda/cli/mail/subcommands")
loader.collapse("#{__dir__}/agentilda/cli/resync/subcommands")
loader.ignore("#{__dir__}/agentilda/cli/linear/linear.rb")
loader.ignore("#{__dir__}/agentilda/cli/mail/mail.rb")
loader.ignore("#{__dir__}/agentilda/linear/mapping.rb")
loader.ignore("#{__dir__}/dry")
loader.setup

# Spec → Plan → Build.
#
# Three phases, each with a file that proves it happened, and a guarded state
# machine that refuses to let a plan folder claim a phase it has not reached.
#
#   spec   ⚪️ New          spec.md
#   plan   ⭐️ Ready        plan.md
#   build  🟡 → ✅         pull-requests.md
#
# The conventions are not documented anywhere else by hand: the status
# vocabulary, the numbering rules and the transition table live here and are
# emitted by `agentilda docs`. Three hand-maintained copies of that table
# have already drifted apart, which is why there is now exactly one.

# © 2026 Konstantin Gredeskoul
module Agentilda
  # The folder every project keeps its plans in.
  PLANS_DIR = ENV.fetch("PLANS_DIR", ".plans")

  # Prefix for a pull request that deliberately implements no plan —
  # dependency bumps, CI work, hotfixes, developer tooling.
  #
  # Lower case, and not a number, so it cannot be mistaken for one. It used to
  # be `DEV.00`, which read as a plan number and sorted among them.
  NO_PLAN_PREFIX = "dev"

  # What it used to be. Titles still wearing it are rewritten rather than
  # skipped as already-prefixed.
  STALE_NO_PLAN_PREFIX = "DEV.00"

  # Prefix for a pull request that implements *something* nothing could name.
  # Unlike `dev` this asserts nothing; it marks a question left open.
  NONE_PREFIX = "none"

  # @return [Dry::Inflector] shared Inflector
  def self.inflector = @inflector ||= ::Dry::Inflector.new

  # Move a directory, preferring `git mv` so its history follows it.
  #
  # Both the state machine and `resync dirs` move plan folders, and a folder
  # that loses its history because one of them used `FileUtils` is a folder
  # nobody can `git log`.
  #
  # @param source [String] absolute
  # @param target [String] absolute
  # @return [Boolean] false when the target was already occupied
  def self.move_directory(source, target)
    return false if File.exist?(target)

    parent = File.dirname(source)
    tracked = system("git",
      "-C",
      parent,
      "ls-files",
      "--error-unmatch",
      source,
      out: File::NULL,
      err: File::NULL)
    moved = tracked && system("git",
      "-C",
      parent,
      "mv",
      source,
      target,
      out: File::NULL,
      err: File::NULL)
    FileUtils.mv(source, target) unless moved
    true
  end

  # Plan numbers visible in `.plans` on a git ref, without checking it out.
  #
  # A pull request's branch is the only place that knows how far the sequence
  # had got when the work started, and branches are not all rebased onto the
  # same main. Reading the ref directly costs one `ls-tree` and no worktree.
  #
  # @param root [String] repository root
  # @param ref [String] a branch name; `origin/` is tried first
  # @return [Array<Agentilda::Ordinal>] possibly empty
  def self.plans_on_ref(root, ref)
    ["origin/#{ref}", ref].each do |candidate|
      out = `git -C #{root.shellescape} ls-tree -d --name-only #{candidate.shellescape} #{PLANS_DIR}/ 2>/dev/null`
      next if out.to_s.strip.empty?

      return out.lines.filter_map { |line| Ordinal.from_dirname(File.basename(line.strip)) }
    end
    []
  end

  # The agent that writes a specification for work that already shipped.
  # Named here rather than in the CLI so the definition file stays the single
  # source of truth about who does what.
  RETROACTIVE_WRITER = "yoda-writer"

  class Error < StandardError; end
end
