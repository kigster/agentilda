# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda unblock NNN…` — hand a stopped plan to the agent that
    # drains its `blocked.md`.
    #
    # Deliberately not part of `run`. ⭕️ and 🅱️ are {StateMachine::SETTLED}, so
    # the loop never offers a blocked plan to anybody, and that is the property
    # that makes the state mean anything: the plan waits for a human, and no
    # agent quietly decides otherwise. Answers arriving is not a fact the tool
    # can observe, so a human typing this command *is* the signal, and there is
    # nothing else that could produce it.
    class Unblock < Base
      # The agent that knows the shape of `blocked.md`.
      DEFAULT_AGENT = "lando-broker"

      # What each token turned out to be, for whoever has to fix it.
      PROBLEMS = {
        missing: "no plan of that number",
        not_blocked: "no blocked.md, so there is nothing to drain",
      }.freeze

      desc "Fold answered blocks into a plan's documents and retire blocked.md"

      argument :plans, type: :array, required: true,
                       desc: "Which plans to drain: NNN or NNN.MM, e.g. 003 005.01"

      option :commit, type: :boolean, default: false,
                      desc: "Actually invoke the agent (default: dry run, prints the questions still open)"
      option :agent, default: DEFAULT_AGENT, desc: "Hand the folder to a different agent"
      option :root, desc: "Repository root the agent works in (default: the .plans parent)"

      example [
        "003                # what 003 is still waiting on",
        "003 --commit       # fold in whatever has been answered",
        "003,005 --commit   # both",
      ]

      # @param plans [Array<String>]
      # @param options [Hash]
      # @return [void]
      def call(plans:, **options)
        tree = tree_for(options)
        quiet?(options)
        unblocker = Unblocker.new(tree:, agent: agent_for(options), root: options[:root],
                                  commit: commit?(options), executor: Executor.new(root: options[:root] || File.dirname(tree.dir),
                                                                                   dry_run: !commit?(options)))

        targets = unblocker.resolve(plans)
        refused(targets, tree, options)
        subjects = targets.select(&:drainable?).map(&:subject)
        exit(worst(targets, [])) if subjects.empty?

        credentials_warning if commit?(options) && !quiet?(options)
        preflight(subjects, unblocker, options)

        outcomes = unblocker.call(subjects)
        outcomes.each { |outcome| report(outcome, options) }
        footer(outcomes, options) unless quiet?(options)
        exit(worst(targets, outcomes))
      end

      private

      # @param options [Hash]
      # @return [Agentilda::Agent]
      def agent_for(options)
        name = options.fetch(:agent, DEFAULT_AGENT)
        agents = Agentilda::Agents.new
        agents.find(name) or begin
          error("No agent called #{name}.\n\nKnown: #{agents.all.map(&:name).join(", ")}")
          exit 65
        end
      end

      # A number that names no folder, or a folder that was never stopped, is
      # refused rather than skipped. Whoever typed this believes an answer has
      # arrived; running against a folder nobody blocked and saying nothing is
      # how you come back later to a plan nobody touched and no record of why.
      #
      # Every bad token is reported, not just the first, because stopping at
      # the first one hides the rest of the answer.
      #
      # @param targets [Array<Agentilda::Unblocker::Target>]
      # @param tree [Agentilda::Tree]
      # @param options [Hash]
      # @return [void]
      def refused(targets, tree, options)
        problems = targets.reject(&:drainable?)
        return if problems.empty?

        problems.each do |target|
          state = target.subject ? target.subject.status.key : "unknown"
          puts "#{target.token}\t#{state}\t0 open\t#{PROBLEMS.fetch(target.problem)}"
        end
        return if quiet?(options)

        error("#{problems.size} of the plans named cannot be drained:\n\n" +
              problems.map { |t| "  #{t.token} — #{PROBLEMS.fetch(t.problem)}" }.join("\n") +
              "\n\nThe tree holds: #{tree.ordinals.join(", ")}")
      end

      # What each folder is waiting on, said BEFORE the agent is invoked.
      #
      # This is the half that was missing. `--commit` hands the folder to an
      # agent that can take a quarter of an hour, and until it came back the
      # terminal showed nothing at all — a run that had found nothing to do and
      # a run still working looked exactly alike.
      #
      # @param subjects [Array<Agentilda::Subject>]
      # @param unblocker [Agentilda::Unblocker]
      # @param options [Hash]
      # @return [void]
      def preflight(subjects, unblocker, options)
        return if quiet?(options)

        subjects.each do |subject|
          questions = Unblocker.questions(subject)
          answered = questions.count(&:answered)
          say("#{paint(subject.feature.ordinal.to_s, :bright_black)} #{subject.status.emoji} " \
              "#{subject.feature.title} — #{summary(questions.size, answered)}")
          detail(subject, questions)
        end
      end

      # @param open [Integer]
      # @param answered [Integer]
      # @return [String]
      def summary(open, answered)
        return "nothing open" if open.zero?

        "#{open} open, #{answered.zero? ? "none answered yet" : "#{answered} with an answer waiting"}"
      end

      # @param subject [Agentilda::Subject]
      # @param questions [Array<Agentilda::Unblocker::Question>]
      # @return [void]
      def detail(subject, questions)
        if subject.unreadable_block?
          say("  #{paint("blocked.md names no `## B<n>` question, so nothing here can be drained", :red)}",
              bullet: " ")
          say("  #{paint("Number each open question `## B1`, `## B2`, and each answer `## A1`, `## A2`.", :yellow)}",
              bullet: " ")
        elsif questions.empty?
          say("  #{paint("nothing left open", :green)}", bullet: " ")
        else
          questions.each { |question| say("  #{paint(question.to_s, :yellow)}", bullet: " ") }
        end
      end

      # One plan, after the fact: the deliverable line on STDOUT, and what
      # changed on STDERR.
      #
      # @param outcome [Agentilda::Unblocker::Outcome]
      # @param options [Hash]
      # @return [void]
      def report(outcome, options)
        moved = movement(outcome, commit?(options))
        puts "#{outcome.ordinal}\t#{outcome.ok ? outcome.subject.status.key : "failed"}\t" \
             "#{outcome.after.size} open\t#{moved}\t#{outcome.note}"
        # A dry run changed nothing, so the preflight above it is still the
        # whole truth. Printing the same three lines again reads as a second
        # pass that found the same thing, which is not what happened.
        return if quiet?(options) || !commit?(options)

        say("#{paint(outcome.ordinal.to_s, :bright_black)} #{outcome.subject.status.emoji} " \
            "#{outcome.subject.feature.title} — #{paint(moved, outcome.ok ? :green : :red)}")
        detail(outcome.subject, outcome.after)
      end

      # What the file says happened, rather than what the agent claims. The
      # questions are counted off disk on both sides of the run.
      #
      # @param outcome [Agentilda::Unblocker::Outcome]
      # @param commit [Boolean]
      # @return [String]
      def movement(outcome, commit)
        return "failed" unless outcome.ok
        return "not attempted" unless commit
        return "blocked.md retired" if outcome.cleared?
        return "nothing folded" if outcome.folded.empty?

        "folded #{outcome.folded.map { |n| "B#{n}" }.join(", ")}"
      end

      # @param outcomes [Array<Agentilda::Unblocker::Outcome>]
      # @param options [Hash]
      # @return [void]
      def footer(outcomes, options)
        failed = outcomes.reject(&:ok)

        unless commit?(options)
          warn("Dry run: no agent was invoked, and #{outcomes.size} " \
               "plan#{"s" unless outcomes.size == 1} #{(outcomes.size == 1) ? "is" : "are"} unchanged.\n" \
               "Re-run with --commit to fold in whatever has been answered.")
          return
        end

        return error(failed.map { |o| "#{o.ordinal}: #{o.note}" }.join("\n")) unless failed.empty?

        cleared = outcomes.count(&:cleared?)
        folded = outcomes.sum { |o| o.folded.size }
        waiting = outcomes.sum { |o| o.after.size }
        success("#{folded} question#{"s" unless folded == 1} folded in · " \
                "#{cleared} plan#{"s" unless cleared == 1} out of the block · " \
                "#{waiting} still waiting on a human." +
                (folded.zero? ? "\n\nNothing moved. An answer has to be written into blocked.md as its own " \
                                "`## A<n>` section, answering the `## B<n>` of the same number, before " \
                                "there is anything to fold." : ""))
      end

      # The most serious thing that happened, as an exit status. A tree that
      # was partly drained still exits non-zero when part of it could not be.
      #
      # @param targets [Array<Agentilda::Unblocker::Target>]
      # @param outcomes [Array<Agentilda::Unblocker::Outcome>]
      # @return [Integer]
      def worst(targets, outcomes)
        problems = targets.map(&:problem)
        return 66 if problems.include?(:missing)
        return 65 if problems.include?(:not_blocked)
        return 1 unless outcomes.all?(&:ok)

        0
      end
    end
  end
end
