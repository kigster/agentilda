# frozen_string_literal: true

module Agentilda
  # The plan model: what a `.plans` folder is, which state it claims, and
  # which transitions it may take. Nothing in here spawns a process or talks
  # to a network; it reads and renames folders, and that is all.
  #
  # The module methods below are the front door. Callers outside this
  # namespace go through them rather than constructing the classes, so the
  # classes can be split or renamed without touching the CLI.
  module Plans
    module_function

    # @param dir [String] the `.plans` directory
    # @return [Agentilda::Plans::Tree]
    def tree(dir = Agentilda::PLANS_DIR) = Tree.new(dir:)

    # @param feature [Agentilda::Plans::Feature]
    # @return [Agentilda::Plans::Subject]
    def subject(feature) = Subject.new(feature)

    # @param path [String] a plan folder
    # @return [Agentilda::Plans::Feature, nil]
    def feature(path) = Feature.parse(path)

    # @param text [String]
    # @return [Agentilda::Plans::Ordinal, nil]
    def ordinal(text) = Ordinal.parse(text)

    # @param dir [String] a plan folder
    # @return [Agentilda::Plans::Mailbox]
    def mailbox(dir) = Mailbox.new(dir:)

    # @param tree [Agentilda::Plans::Tree]
    # @param project [String, nil]
    # @return [Agentilda::Plans::Index]
    def index(tree:, project: nil) = Index.new(tree:, project:)
  end
end
