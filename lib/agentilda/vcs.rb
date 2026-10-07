# frozen_string_literal: true

module Agentilda
  # Git and GitHub: a checkout per plan, pushing a branch, and reading
  # pull requests. Everything that leaves the machine leaves through here.
  module Vcs
    module_function

    # @return [Agentilda::Vcs::GitHub]
    def github = GitHub.new

    # @param root [String] repository root
    # @return [Agentilda::Vcs::Worktree]
    def worktree(root:, **) = Worktree.new(root:, **)

    # @return [Agentilda::Vcs::Publisher]
    def publisher(**) = Publisher.new(**)
  end
end
