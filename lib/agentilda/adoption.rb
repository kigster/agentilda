# frozen_string_literal: true

module Agentilda
  # Gives a plan folder to every pull request that has no plan to point at.
  #
  # `resync prs` files most pull requests under a plan that already exists.
  # Two kinds cannot be filed that way, and both are given a folder rather
  # than a shrug, because work that appears in no folder appears in no index:
  #
  #   - **Timeline placements.** The resolver named a plan but not confidently.
  #     The pull request goes *beside* that plan as its next `.MM` sibling,
  #     which is what the decimal has always meant — work in the gap after
  #     NNN, documented afterwards.
  #   - **Stragglers.** Nothing in the tree describes the work at all. The
  #     pull request opens a new whole number at the end of the stack.
  #
  # A minted folder holds `pull-requests.md`, and `spec.md` and `plan.md`
  # both carrying the pull request's own description. No agent is involved:
  # the description is the only account of the work that exists, and copying
  # it is faster and more honest than paraphrasing it.
  #
  # == Why the numbering is allocated serially
  #
  # The obvious parallel design — every worker reads the highest number and
  # adds one — is deterministic but not unique, and the collision is the
  # common case rather than the rare one. Fifteen stragglers all see the same
  # highest number and all compute the same slot. Determinism is not the
  # property that matters here; distinctness is. So slots are handed out in
  # one serial pass over an array already in memory, and the folders are
  # written in parallel afterwards, each worker owning a number nobody else
  # can want.
  class Adoption
    # One pull request and the plan it is being given.
    #
    # @!attribute [r] pull
    #   @return [Hash] as returned by {GitHub#pulls}
    # @!attribute [r] ordinal
    #   @return [Agentilda::Ordinal] the slot it was allocated
    # @!attribute [r] kind
    #   @return [Symbol] :timeline or :straggler
    # @!attribute [r] path
    #   @return [String, nil] the folder, once created
    Adoptee = Data.define(:pull, :ordinal, :kind, :path) do
      # @return [String] the folder name this pull request earns
      def dirname = Agentilda.plan_dirname(ordinal, STATUS_BY_KEY.fetch(:retroactive), slug)

      # The PR title, stripped of any prefix, as the folder's tail.
      #
      # @return [String]
      def slug = Creator.slugify(pull[:title].to_s.sub(/\A\[[^\]]+\](?:\([A-Z]\))?\s*/, ""))

      # @return [Boolean]
      def straggler? = kind == :straggler

      # @return [String] a single auditable line
      def to_s = "##{pull[:number]} → #{dirname}"
    end

    # @param tree [Agentilda::Tree]
    # @param jobs [Integer] workers for writing the folders
    def initialize(tree:, jobs: UI.default_jobs)
      @tree = tree
      @jobs = jobs
    end

    # @return [Agentilda::Tree]
    attr_reader :tree

    # @return [Integer]
    attr_reader :jobs

    # Work out what each pull request would be given, without creating anything.
    #
    # @param placements [Array<Array(Hash, Integer, nil)>] each pull request
    #   with the major it lands after, or nil for a straggler
    # @return [Array<Agentilda::Adoption::Adoptee>] in pull request order
    def plan(placements)
      allocate(placements.sort_by { |pull, _| pull[:number].to_i })
    end

    # Adopt every pull request: create its folder and write its documents.
    #
    # @param placements [Array<Array(Hash, Integer, nil)>]
    # @return [Array<Agentilda::Adoption::Adoptee>] with `path` filled in
    def call(placements)
      adoptees = plan(placements)
      return adoptees if adoptees.empty?

      created = Parallel.map(adoptees, in_threads: jobs) { |adoptee| adopt(adoptee) }
      tree.reload
      created
    end

    private

    # Serial, and deliberately so: minors continue past every slot the tree
    # holds under each major, majors continue past the furthest plan, and
    # both advance in pull request order so the numbers follow the order the
    # work was opened in.
    #
    # @param placements [Array<Array(Hash, Integer, nil)>]
    # @return [Array<Agentilda::Adoption::Adoptee>]
    def allocate(placements)
      taken = tree.ordinals.dup

      placements.filter_map do |pull, major|
        ordinal =
          if major.nil?
            Ordinal.next_major(taken)
          else
            begin
              Ordinal.next_minor(taken, major:)
            rescue Agentilda::Error
              next
            end
          end
        taken << ordinal
        Adoptee.new(pull:, ordinal:, kind: major.nil? ? :straggler : :timeline, path: nil)
      end
    end

    # Each worker owns a number nobody else can want, so it creates its
    # folder without coordinating with anyone.
    #
    # @param adoptee [Agentilda::Adoption::Adoptee]
    # @return [Agentilda::Adoption::Adoptee]
    def adopt(adoptee)
      path = File.join(tree.dir, adoptee.dirname)
      return adoptee if File.exist?(path)

      pull = adoptee.pull
      FileUtils.mkdir_p(path)
      File.write(File.join(path, PullRequests::FILENAME), PullRequests.render([row_for(pull)]))
      %w[spec.md plan.md].each do |name|
        File.write(File.join(path, name), document(name, pull))
      end

      adoptee.with(path:)
    end

    # @param pull [Hash]
    # @return [Hash] the row `pull-requests.md` renders
    def row_for(pull)
      {number: pull[:number], title: pull[:title], url: pull[:url],
       state: pull[:state] || "Unknown", body: pull[:body].to_s}
    end

    # The pull request's own words, under a heading that says where they came
    # from. Written to both documents so the folder is never half-explained.
    #
    # @param name [String] "spec.md" or "plan.md"
    # @param pull [Hash]
    # @return [String]
    def document(name, pull)
      title = pull[:title].to_s.sub(/\A\[[^\]]+\](?:\([A-Z]\))?\s*/, "")
      body = pull[:body].to_s.strip
      body = "_No description was written on the pull request._" if body.empty?
      heading = (name == "spec.md") ? "Goal" : "Plan"

      <<~MARKDOWN
        # #{title}

        > [!NOTE]
        > Written by `agentilda resync prs` from pull request ##{pull[:number]},
        > which implemented no plan in this tree. The text below is the pull
        > request's own description, copied rather than paraphrased.

        ## #{heading}

        #{body}
      MARKDOWN
    end
  end
end
