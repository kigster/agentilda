# frozen_string_literal: true

module Agentilda
  # Reconciling what is recorded with what is true.
  #
  # Both resyncs are dry-run by default and both refuse to act where they are
  # not certain, because both write to things other people join on: folder
  # names, and pull request titles.
  module Resync
    # `resync dirs` — makes every folder's name say what the folder is.
    #
    # Two things can be wrong with a name, and both are repaired here:
    #
    # - **The emoji is wrong** — the contents justify a different state. A
    #   folder whose status already holds is left alone, which is what stops
    #   ⭕️ Blocked and 🅱️ Product Blocked — deliberately identical invariants,
    #   distinguished only by the name — from collapsing into one.
    # - **The number is not in `NNN.MM` form** — a folder written `018-⚪️--foo`
    #   before the padding rule, or `18.1-⚪️--foo` by hand. These read fine and
    #   sort wrong, which is the whole reason the rule exists: `018.09` <
    #   `018.1` < `018.10` puts a single mixed-width folder in the middle of
    #   the range. Both are renamed to `018.00-⚪️--foo` and `018.01-⚪️--foo`.
    #
    # The two cases collapse into one rule — **rename any folder that is not
    # already named what it should be named** — which is why the emoji fix and
    # the renumber cannot disagree about the target.
    class Dirs
      # A proposed rename.
      #
      # @!attribute [r] dirname
      #   @return [String] the folder as it stands
      # @!attribute [r] from
      #   @return [Symbol] the state it claims
      # @!attribute [r] to
      #   @return [Symbol] the state its contents justify
      # @!attribute [r] source
      #   @return [String] absolute path now
      # @!attribute [r] target
      #   @return [String] absolute path after
      # @!attribute [r] reason
      #   @return [String] why the current name is wrong
      Change = Data.define(:dirname, :from, :to, :source, :target, :reason) do
        # @return [String] a single auditable line
        def to_s = "#{dirname} → #{File.basename(target)}  (#{reason})"
      end

      # The state a folder's contents justify, or the one it claims when
      # nothing fits. What a rename moves toward, and what the dispatcher
      # reads on a dry run, which renames nothing, so the preview still
      # names the agents a real run would start.
      #
      # @param subject [Agentilda::Subject]
      # @return [Agentilda::Status]
      def self.target(subject) = subject.best_fit || subject.status

      # @param tree [Agentilda::Tree]
      # @param except [Array<String>] ordinals to leave alone however wrong
      #   their names are: the dispatcher passes the plans an agent is
      #   working in right now
      def initialize(tree:, except: [])
        @tree = tree
        @except = except.map(&:to_s)
      end

      # @return [Agentilda::Tree]
      attr_reader :tree

      # What would change, without changing anything.
      #
      # @return [Array<Agentilda::Resync::Dirs::Change>]
      def plan
        tree.subjects.filter_map do |subject|
          change_for(subject) unless @except.include?(subject.feature.ordinal.to_s)
        end
      end

      # @param commit [Boolean] actually rename
      # @return [Array<Agentilda::Resync::Dirs::Change>] what was proposed
      def call(commit: false)
        changes = plan
        return changes unless commit

        UI.stepping(changes, "Renaming") { |change| rename(change) }
        tree.reload
        changes
      end

      private

      # A folder moves when the name it has is not the name it should have.
      # {target} says what that name is.
      #
      # @param subject [Agentilda::Subject]
      # @return [Agentilda::Resync::Dirs::Change, nil]
      def change_for(subject)
        feature = subject.feature
        fit = self.class.target(subject)
        dirname = feature.dirname_as(fit)
        return nil if dirname == feature.dirname

        Change.new(
          dirname: feature.dirname,
          from: subject.status.key,
          to: fit.key,
          source: feature.path,
          target: File.join(File.dirname(feature.path), dirname),
          reason: reason_for(subject, fit)
        )
      end

      # @param subject [Agentilda::Subject]
      # @param fit [Agentilda::Status] the state the folder is moving to
      # @return [String] why the current name is wrong
      def reason_for(subject, fit)
        feature = subject.feature
        return subject.violation || "contents now justify #{fit.label}" unless fit.key == subject.status.key
        return "#{feature.dirname_ordinal} is not padded to #{feature.ordinal}" unless feature.padded?

        "name is not in canonical NNN.MM-<emoji>--<slug> form"
      end

      # A rename that finds its target occupied has not happened, and saying
      # nothing about it would leave the folder misnamed with a report
      # claiming otherwise. Two folders can want the same canonical name —
      # `018-⚪️--foo` and `018.00-⚪️--foo` are the same plan written twice.
      #
      # @param change [Agentilda::Resync::Dirs::Change]
      # @return [void]
      # @raise [Agentilda::Error] when the target name is already taken
      def rename(change)
        return if Agentilda.move_directory(change.source, change.target)

        raise Error, "cannot rename #{change.dirname} — #{File.basename(change.target)} already exists"
      end
    end

    # `resync prs` — files every pull request under the plan it implements.
    #
    # The prefix on a title is the join key between a pull request and a plan:
    # `pull-requests.md` is generated from it, and a wrong number files work
    # under a plan that did not do it while the plan that did looks untouched.
    # So every step here prefers *no answer* to a guessed one, and the only
    # answers applied are the ones that cleared a bar.
    #
    # Two passes. The first is arithmetic and free: the branch name, then the
    # share of changed lines under one plan folder, then the developer-work
    # patterns. The second is a judgment: what survives goes to
    # {Resolver} — `jabba-resolver`, one `claude` process per pull request —
    # and its verdict is read against three thresholds. A confident verdict
    # files the pull request. A weak one places it *beside* its nearest plan
    # in time, as a `.MM` sibling. No verdict at all opens a new plan at the
    # end of the stack. Both of the last two mint a folder.
    #
    # Every prefix this tool ever wrote was written by an algorithm, not a
    # person, so a numbered title is skipped only as a courtesy to the cost
    # of re-judging it: `--force` strips every prefix and runs the lot.
    class Prs
      # Share of changed lines that must fall under one plan folder for the
      # diff alone to file a pull request there.
      FOLDER_SHARE = 0.8

      # Confidence at or above which a verdict files the pull request.
      ASSIGN = 0.8

      # Confidence at or above which a verdict earns a timeline placement
      # beside the plan it named; below it the pull request is a straggler.
      TIMELINE = 0.5

      # A title already filed under a plan.
      NUMBERED = /\A\[(\d{3}(?:\.\d{2})?)\](?:\([A-Z]\))?\s*/

      # A title wearing a marker this tool wrote without looking: the no-plan
      # marker in either spelling, the open-question marker, and the legacy
      # `[XXX]`. Every one of them is re-judged.
      MARKER = /\A\[(?:#{Agentilda::NO_PLAN_PREFIX}|#{Regexp.escape(Agentilda::STALE_NO_PLAN_PREFIX)}|#{Agentilda::NONE_PREFIX}|XXX)\](?:\([A-Z]\))?\s*/i

      # Any prefix at all, for stripping.
      ANY_PREFIX = /\A\[[^\]]+\](?:\([A-Z]\))?\s*/

      # Finds a plan number in a branch name: `kig/018.01-verify`, `002-slug`.
      BRANCH_PATTERN = %r{(?:\A|[/\-_])(\d{3}(?:\.\d{2})?)(?:\z|[-_])}

      # A proposed retitle, or the reason there is none.
      #
      # @!attribute [r] number
      #   @return [Integer] the pull request
      # @!attribute [r] title
      #   @return [String] as it stands
      # @!attribute [r] new_title
      #   @return [String, nil] nil when nothing may safely be done
      # @!attribute [r] ordinal
      #   @return [Agentilda::Ordinal, nil]
      # @!attribute [r] reason
      #   @return [String] how it was resolved, or why it was not
      # @!attribute [r] kind
      #   @return [Symbol] :branch, :folder, :dev, :judged, :timeline,
      #     :straggler, :unchanged or :flagged
      # @!attribute [r] verdict
      #   @return [Agentilda::Resolver::Verdict, nil] when the model was asked
      # @!attribute [r] adopted
      #   @return [Boolean] whether a plan folder was minted for this one
      Change = Data.define(:number, :title, :new_title, :ordinal, :reason, :kind, :verdict, :adopted) do
        def initialize(new_title: nil, ordinal: nil, verdict: nil, adopted: false, **rest) = super

        # @return [Boolean] a human must decide; never edited
        def ambiguous? = kind == :flagged

        # @return [Boolean] the title already says what the pipeline says
        def unchanged? = kind == :unchanged

        # @return [Boolean] whether a plan folder was minted for this one
        def adopted? = adopted

        # @return [Boolean] the model was consulted
        def judged? = !verdict.nil?

        # @return [Boolean] safe to apply without a human looking
        def applicable? = !ambiguous? && !unchanged? && !new_title.nil?
      end

      # @param tree [Agentilda::Tree]
      # @param github [Agentilda::GitHub, Agentilda::FakeGitHub]
      # @param resolver [Agentilda::Resolver, nil] the judge; built on demand
      # @param adopt [Boolean] mint folders for placements and stragglers,
      #   rather than flagging them for a human
      # @param force [Boolean] re-judge numbered titles too
      # @param state [String] which pull requests to fetch
      # @param root [String, nil] repository root
      def initialize(tree:, github: GitHub.new, resolver: nil, adopt: true, force: false, state: "all", root: nil)
        @tree = tree
        @github = github
        @resolver = resolver
        @adopt = adopt
        @force = force
        @state = state
        @root = root || File.dirname(tree.dir)
      end

      # @return [Agentilda::Tree]
      attr_reader :tree

      # @return [Agentilda::GitHub]
      attr_reader :github

      # @return [Boolean]
      def adopt? = @adopt

      # @return [Boolean]
      def force? = @force

      # @return [Agentilda::Resolver]
      def resolver = @resolver ||= Resolver.new(tree:, root: @root)

      # @return [Agentilda::Adoption]
      def adoption = @adoption ||= Adoption.new(tree:)

      # Everything the run proposes, without changing anything. The model is
      # still consulted — a dry run is the same run with the writes withheld.
      #
      # @return [Array<Agentilda::Resync::Prs::Change>]
      def plan = call(commit: false)

      # @param commit [Boolean] retitle, mint folders and rewrite
      #   `pull-requests.md`
      # @return [Array<Agentilda::Resync::Prs::Change>] what was proposed
      def call(commit: false)
        changes = resolve_all
        changes = with_adoptions(changes, create: commit)
        return changes unless commit

        applicable = changes.select(&:applicable?)
        UI.stepping(applicable, "Retitling") { |c| github.retitle(number: c.number, title: c.new_title) }
        rewrite_pull_requests(changes)
        changes
      end

      # @return [Array<Hash>] every pull request fetched, memoized
      def pulls = @pulls ||= github.pulls(state: @state)

      # What the judged pull requests cost, in tokens and dollars.
      #
      # @return [Hash] `up:`, `down:`, `cost:`, `asked:`, `cached:`
      def spent
        verdicts = @verdicts.to_a
        {
          up: verdicts.sum(&:up), down: verdicts.sum(&:down), cost: verdicts.sum(&:cost),
          asked: verdicts.count { |v| !v.cached? }, cached: verdicts.count(&:cached?)
        }
      end

      private

      # @return [Array<Hash>] the pull requests this run may retitle
      def candidates
        @candidates ||= force? ? pulls : pulls.reject { |pr| pr[:title].to_s.match?(NUMBERED) }
      end

      # Pass one for everyone, pass two for the remainder, then the reading
      # of each verdict against the titles pass one and the confident verdicts
      # have already settled — so a plan assigned in this run counts toward
      # its own span on the timeline.
      #
      # @return [Array<Agentilda::Resync::Prs::Change>]
      def resolve_all
        settled = candidates.to_h { |pull| [pull[:number], deterministic(pull)] }
        pending = candidates.reject { |pull| settled[pull[:number]] }
        @verdicts = pending.empty? ? [] : resolver.call(pending)
        by_number = @verdicts.to_h { |v| [v.number, v] }

        pending.each do |pull|
          verdict = by_number.fetch(pull[:number])
          settled[pull[:number]] = confident(pull, verdict)
        end

        timeline = Timeline.new(tree:, pulls: effective_pulls(settled))
        pending.each do |pull|
          next if settled[pull[:number]]

          settled[pull[:number]] = weak(pull, by_number.fetch(pull[:number]), timeline)
        end

        candidates.map { |pull| settled.fetch(pull[:number]) }
      end

      # Every pull request with the title it will carry after this run, for
      # the timeline to read.
      #
      # @param settled [Hash{Integer => Change, nil}]
      # @return [Array<Hash>]
      def effective_pulls(settled)
        pulls.map do |pull|
          change = settled[pull[:number]]
          change&.new_title ? pull.merge(title: change.new_title) : pull
        end
      end

      # Pass one: the branch, the diff, the developer-work patterns.
      #
      # @param pull [Hash]
      # @return [Agentilda::Resync::Prs::Change, nil] nil when the model must decide
      def deterministic(pull)
        from_branch(pull) || from_folder(pull) || from_patterns(pull)
      end

      # 1. The branch name — the one moment the author certainly knew.
      #
      # @param pull [Hash]
      # @return [Agentilda::Resync::Prs::Change, nil]
      def from_branch(pull)
        match = BRANCH_PATTERN.match(pull[:branch].to_s) or return nil
        ordinal = Ordinal.parse(match[1])
        return nil unless ordinal && tree.include?(ordinal)

        filed(pull, ordinal, :branch, "branch #{pull[:branch]}")
      end

      # 2. The diff, when enough of it sits under one plan folder. Lines,
      # not files, so a one-line `CHANGELOG` touch does not outweigh a spec.
      #
      # @param pull [Hash]
      # @return [Agentilda::Resync::Prs::Change, nil]
      def from_folder(pull)
        weights = folder_weights(pull)
        return nil if weights.empty?

        total = weights.values.sum
        return nil unless total.positive?

        ordinal, lines = weights.max_by { |_, n| n }
        share = lines.to_f / total
        return nil if share < FOLDER_SHARE

        filed(pull, ordinal, :folder, "#{(share * 100).round}% of the diff is under #{ordinal}")
      end

      # Changed lines by plan folder, with everything that is not a plan
      # folder pooled under nil so the share has a denominator. Neutral
      # paths — README, CHANGELOG — are left out of it. A diff with no line
      # counts at all falls back to counting files.
      #
      # @param pull [Hash]
      # @return [Hash{Agentilda::Ordinal, nil => Integer}]
      def folder_weights(pull)
        changes = Array(pull[:changes])
        changes = Array(pull[:files]).map { |path| {path:, additions: 1, deletions: 0} } if changes.empty?
        weights = Hash.new(0)
        changes.each do |change|
          ordinal = ordinal_for_path(change[:path])
          next if ordinal.nil? && change[:path].to_s.match?(DevWork::NEUTRAL)

          lines = change[:additions].to_i + change[:deletions].to_i
          weights[ordinal] += lines.zero? ? 1 : lines
        end
        return {} unless weights.keys.any?

        weights
      end

      # @param path [String] a path from the diff
      # @return [Agentilda::Ordinal, nil]
      def ordinal_for_path(path)
        parts = path.to_s.split("/")
        index = parts.index(Agentilda::PLANS_DIR) or return nil
        folder = parts[index + 1] or return nil
        return nil if parts.length <= index + 2 # a file directly under .plans belongs to no plan

        ordinal = Ordinal.from_dirname(folder)
        ordinal if ordinal && tree.include?(ordinal)
      end

      # 3. Work that says what it is: a dependency bump, a CI change.
      #
      # @param pull [Hash]
      # @return [Agentilda::Resync::Prs::Change, nil]
      def from_patterns(pull)
        return nil unless DevWork.developer?(bare(pull[:title]), pull[:files])

        developer(pull, :dev, "developer work by its title or the paths it touches")
      end

      # A verdict that settles the question on its own: developer work, or a
      # plan named at or above {ASSIGN}.
      #
      # @param pull [Hash]
      # @param verdict [Agentilda::Resolver::Verdict]
      # @return [Agentilda::Resync::Prs::Change, nil]
      def confident(pull, verdict)
        return nil unless verdict.valid?
        return developer(pull, :dev, "#{Resolver::AGENT_NAME}: #{verdict.reason}", verdict:) if verdict.dev?
        return nil if verdict.plan.nil? || verdict.confidence < ASSIGN

        filed(pull, verdict.plan, :judged, "#{Resolver::AGENT_NAME} #{pct(verdict)}: #{verdict.reason}", verdict:)
      end

      # A verdict that did not settle it: a placement beside the nearest plan
      # in time, or a straggler at the end of the stack. Both need a folder,
      # so both are returned flagged here and turned into adoptions after.
      #
      # @param pull [Hash]
      # @param verdict [Agentilda::Resolver::Verdict]
      # @param timeline [Agentilda::Timeline]
      # @return [Agentilda::Resync::Prs::Change]
      def weak(pull, verdict, timeline)
        unless verdict.valid?
          return placement(pull, nil, "no verdict — #{verdict.error}", verdict:)
        end
        if verdict.plan && verdict.confidence >= TIMELINE
          major = timeline.place(pull) || verdict.plan.major
          return placement(pull, major, "#{Resolver::AGENT_NAME} #{pct(verdict)} for #{verdict.plan}, placed by time after #{format("%03d", major)}", verdict:)
        end

        placement(pull, nil, "#{Resolver::AGENT_NAME} #{pct(verdict)}: #{verdict.reason}", verdict:)
      end

      # Mint (or, on a dry run, only name) a folder for every placement and
      # straggler, and rewrite their changes to point at it.
      #
      # @param changes [Array<Agentilda::Resync::Prs::Change>]
      # @param create [Boolean]
      # @return [Array<Agentilda::Resync::Prs::Change>]
      def with_adoptions(changes, create: false)
        pending = changes.select { |c| c.kind == :timeline || c.kind == :straggler }
        return changes if pending.empty?

        unless adopt?
          return changes.map { |c| pending.include?(c) ? c.with(kind: :flagged, new_title: nil, reason: "#{c.reason} (no folder minted under --no-adopt)") : c }
        end

        by_number = pulls.to_h { |pr| [pr[:number], pr] }
        placements = pending.map { |c| [by_number.fetch(c.number), (c.kind == :timeline) ? c.ordinal&.major : nil] }
        adoptees = create ? adoption.call(placements) : adoption.plan(placements)
        minted = adoptees.to_h { |a| [a.pull[:number], a] }

        changes.map do |c|
          adoptee = minted[c.number]
          next c unless pending.include?(c)
          next c.with(kind: :flagged, new_title: nil, reason: "#{c.reason} — no slot free") unless adoptee

          c.with(ordinal: adoptee.ordinal, new_title: retitled(c.title, adoptee.ordinal.to_prefix),
            reason: "#{c.reason} — #{create ? "adopted into" : "would adopt into"} #{adoptee.dirname}", adopted: true)
        end
      end

      # Every plan that gained or lost a pull request gets its table rebuilt
      # from every title that carries its prefix, prose below the table kept.
      #
      # Rebuilt from what GitHub returned, which is not always everything:
      # `--state open` fetches no merged pull request, and the fetch has a
      # limit. A row already in the table whose number this run never saw is
      # therefore kept, not dropped — the table matches GitHub for every
      # pull request GitHub was asked about, and forgets none it was not.
      #
      # @param changes [Array<Agentilda::Resync::Prs::Change>]
      # @return [void]
      def rewrite_pull_requests(changes)
        applied = changes.select(&:applicable?).to_h { |c| [c.number, c.new_title] }
        return if applied.empty?

        titled = pulls.map { |pr| applied.key?(pr[:number]) ? pr.merge(title: applied[pr[:number]]) : pr }
        seen = titled.map { |pr| pr[:number].to_s }
        touched = changes.filter_map(&:ordinal).uniq
        touched |= pulls.filter_map { |pr| applied.key?(pr[:number]) && pr[:title][NUMBERED, 1] }.map { |n| Ordinal.parse(n) }
        tree.reload

        touched.each do |ordinal|
          subject = tree.find(ordinal) or next
          path = File.join(subject.feature.path, PullRequests::FILENAME)
          rows = titled.select { |pr| filed_under?(pr[:title], ordinal) }.map { |pr|
            {number: pr[:number], title: pr[:title], url: pr[:url], state: pr[:state], body: pr[:body].to_s}
          }
          rows += subject.pull_requests.reject { |pr| seen.include?(pr.number.to_s) }.map { |pr|
            {number: pr.number, title: pr.title, url: pr.url, state: pr.state, body: ""}
          }
          PullRequests.upsert(path, rows.sort_by { |pr| pr[:number].to_i })
        end
      end

      # @param title [String]
      # @param ordinal [Agentilda::Ordinal]
      # @return [Boolean] whether the title carries this plan's prefix
      def filed_under?(title, ordinal)
        number = title.to_s[NUMBERED, 1] or return false

        Ordinal.parse(number) == ordinal
      end

      # @param verdict [Agentilda::Resolver::Verdict]
      # @return [String]
      def pct(verdict) = "#{(verdict.confidence * 100).round}%"

      # @param title [String]
      # @return [String] the title with any prefix removed
      def bare(title) = title.to_s.sub(ANY_PREFIX, "")

      # @param title [String]
      # @param prefix [String]
      # @return [String]
      def retitled(title, prefix) = "#{prefix} #{bare(title)}"

      # @param pull [Hash]
      # @param ordinal [Agentilda::Ordinal]
      # @param kind [Symbol]
      # @param why [String]
      # @param verdict [Agentilda::Resolver::Verdict, nil]
      # @return [Agentilda::Resync::Prs::Change]
      def filed(pull, ordinal, kind, why, verdict: nil)
        change_for(pull, retitled(pull[:title], ordinal.to_prefix), kind, why, ordinal:, verdict:)
      end

      # @param pull [Hash]
      # @param kind [Symbol]
      # @param why [String]
      # @param verdict [Agentilda::Resolver::Verdict, nil]
      # @return [Agentilda::Resync::Prs::Change]
      def developer(pull, kind, why, verdict: nil)
        change_for(pull, retitled(pull[:title], "[#{Agentilda::NO_PLAN_PREFIX}]"), kind, why, verdict:)
      end

      # A title that comes out the same as it went in is not a change.
      #
      # @return [Agentilda::Resync::Prs::Change]
      def change_for(pull, new_title, kind, why, ordinal: nil, verdict: nil)
        kind = :unchanged if new_title == pull[:title].to_s
        Change.new(number: pull[:number], title: pull[:title], new_title:, ordinal:, reason: why, kind:, verdict:)
      end

      # @param pull [Hash]
      # @param major [Integer, nil] the plan to land after; nil for a straggler
      # @param why [String]
      # @param verdict [Agentilda::Resolver::Verdict, nil]
      # @return [Agentilda::Resync::Prs::Change]
      def placement(pull, major, why, verdict: nil)
        Change.new(number: pull[:number], title: pull[:title], reason: why, verdict:,
          kind: major ? :timeline : :straggler,
          ordinal: major ? Ordinal.new(major:, minor: 0) : nil)
      end
    end
  end
end
