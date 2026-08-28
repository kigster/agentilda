# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda run` — drive the specialist agents until the tree settles.
    class Run < Base
      desc "Run specialist agents over the plans until nothing changes"

      option :commit, type: :boolean, default: false,
        desc: "Actually invoke the agents (default: dry run, prints the plan of work)"
      option :rounds, desc: "Hard ceiling on loop iterations (default: 10)"
      option :timeout, desc: "Seconds before one agent is abandoned (default: 900)"
      option :chain, type: :boolean,
        desc: "When an agent advances a plan, run the next agent in the same round " \
              "(default: on; forced off by --agent)"
      option :agent, desc: "Only run this one agent"
      option :prompt, desc: "Extra instructions appended to the agent's prompt (only with --agent)"
      option :skip, desc: "Never assign this agent; its plans wait, the rest of the pipeline runs. " \
        "Comma separated for several"
      option :model, desc: "Model for every agent this run, overriding each agent's own frontmatter " \
        "(default: what the agent declares, else the claude CLI's default)"
      option :plan, aliases: ["--plans"],
        desc: "Only these plans, comma separated: NNN or NNN.MM, e.g. --plan 003,005.01. Default: the whole tree"
      option :root, desc: "Repository root the agents work in (default: the .plans parent)"
      option :isolation, default: "worktree", values: %w[worktree shared],
        desc: "worktree: a checkout and branch per plan, run in parallel. shared: one tree, serial"
      option :jobs, aliases: ["-j"],
        desc: "Agents to run at once (default: cores - 2, capped at 12)"
      option :dont_push_anything, type: :boolean, default: false,
        desc: "With --commit and --isolation worktree, a finished branch is pushed and its pull request " \
              "opened as soon as it lands, titled [NNN.MM](X). Pass this to turn that off and leave it uncommitted."
      option :log, desc: "Append progress to this file (default: a per-project file under the system temp dir)"

      example [
        "                       # show which agent would take which plan",
        "--commit               # run them, one worktree per plan, in parallel",
        "--commit -j 4          # …with four at a time",
        "--isolation shared     # one tree, serial — no git required",
        "--commit --rounds 3    # …with a tighter ceiling",
        "--commit --plan 005,006,007  # only the plans a batch step just created"
      ]

      # Option precedence, quietest to loudest: the built-in default, then
      # `~/.local/config/agentilda.json` under its `"run"` key, then the flag
      # actually typed. The config never supplies `--commit`: an agent run
      # that writes is something a person asks for each time.
      #
      # @param options [Hash]
      # @return [void]
      def call(**options)
        config = begin
          Agentilda::Config.for(:run)
        rescue Agentilda::Error => e
          refuse(e.message, 66)
        end

        if options[:prompt] && !options[:agent]
          refuse("--prompt only works with --agent: it speaks to one agent, and without " \
                 "that restriction every agent in the round would hear it.", 64)
        end

        tree = tree_for(options)
        root = options[:root] || File.dirname(tree.dir)
        agents = Agentilda::Agents.new
        agents = filtered(agents, options[:agent]) if options[:agent]
        agents = skipped(agents, options[:skip], options[:agent]) if options[:skip]
        plans = options[:plan] ? scoped(tree, options[:plan]) : nil

        isolation = options.fetch(:isolation, "worktree").to_sym
        jobs = (options[:jobs] || config[:jobs] || UI.default_jobs).to_i
        timeout = (options[:timeout] || config[:timeout] || 900).to_i
        chain = if options[:agent]
          false
        elsif options.key?(:chain)
          options[:chain]
        else
          config.fetch(:chain, true)
        end

        if isolation == :worktree && !Worktree.new(root:).repository?
          refuse("#{root} is not a git repository, so plans cannot be isolated.\n\n" \
                 "Run with --isolation shared to work in one tree, serially.", 66)
        end

        # Set before the loop starts, not after: `UI.animate?` (and therefore
        # whether a round prints anything at all) is read the whole time the
        # loop runs, not just when `report` prints its closing summary.
        quiet?(options)
        UI.log_path = options[:log] || config[:log] ||
          File.join(Dir.tmpdir, "agentilda-#{File.basename(root)}.log")
        info("Progress: #{UI.log_path}") unless quiet?(options)
        credentials_warning if commit?(options) && !quiet?(options)

        runner = Runner.new(
          tree:, agents:, isolation:, jobs:, plans:, chain:,
          worktree: (Worktree.new(root:) if isolation == :worktree),
          max_rounds: (options[:rounds] || config[:rounds] || 10).to_i,
          executor: Executor.new(root:, timeout:, dry_run: !commit?(options),
            instructions: options[:prompt], model: options[:model]), dry_run: !commit?(options),
          publisher: publisher_for(root, isolation, options)
        )

        started = UI.monotonic
        rounds = runner.call
        report(runner, rounds, options, seconds: UI.monotonic - started)
        exit(failures(rounds).empty? ? 0 : 1)
      end

      private

      # @param agents [Agentilda::Agents]
      # @param name [String]
      # @return [Agentilda::Agents] holding only the agent named — the
      #   restriction has to reach assignments, not just chaining, or a flag
      #   like `--prompt` aimed at one agent leaks to the whole round
      def filtered(agents, name)
        agents.find(name) or
          refuse("No agent called #{name}.\n\nKnown: #{agents.all.map(&:name).join(", ")}", 65)
        agents.only(name)
      end

      # Each name is checked against the full roster, not the possibly
      # already-restricted one, so `--skip` misspelled is a refusal rather
      # than a silent no-op — the same reasoning `--plan` applies to numbers.
      #
      # @param agents [Agentilda::Agents]
      # @param text [String] comma-separated agent names
      # @param restricted [String, nil] what `--agent` asked for, if anything
      # @return [Agentilda::Agents] without the agents named
      def skipped(agents, text, restricted)
        roster = Agentilda::Agents.new
        names = text.split(",").map(&:strip).reject(&:empty?)
        names.each do |name|
          roster.find(name) or
            refuse("No agent called #{name}.\n\nKnown: #{roster.all.map(&:name).join(", ")}", 65)
          if name == restricted
            refuse("--agent #{name} and --skip #{name} contradict each other: " \
                   "one asks for only this agent, the other for anything but.", 64)
          end
        end
        agents.without(*names)
      end

      # `--plan` names the whole point of scoping: a skill that just minted
      # N folders hands off exactly those, not the tree. A typo'd or already-
      # settled number silently running the whole tree instead is the failure
      # this exists to prevent, so an unknown one is refused rather than
      # dropped.
      #
      # @param tree [Agentilda::Tree]
      # @param text [String]
      # @return [Array<Agentilda::Ordinal>]
      def scoped(tree, text)
        known = tree.subjects.map { |s| s.feature.ordinal }
        text.split(",").map(&:strip).reject(&:empty?).map { |token|
          ordinal = Ordinal.parse(token)
          unless ordinal && known.include?(ordinal)
            refuse("No plan #{token} in #{tree.dir}.\n\n" \
                   "Known: #{known.join(", ")}", 66)
          end
          ordinal
        }
      end

      # @param rounds [Array]
      # @return [Array]
      def failures(rounds) = rounds.flat_map(&:attempts).reject(&:ok)

      # The one thing this harness does that leaves the machine — pushing a
      # branch and opening its pull request — so it takes one more thing to
      # turn on than everything else here: `--commit` alone is not enough,
      # isolation has to actually give each plan a branch of its own too.
      #
      # `nil` is how {Runner} is told to leave a finished worktree alone; it
      # is what `--dont-push-anything` asks for, and what a shared tree gets
      # by construction, since there is no separate branch there to push.
      #
      # @param root [String]
      # @param isolation [Symbol]
      # @param options [Hash]
      # @return [Agentilda::Publisher, nil]
      def publisher_for(root, isolation, options)
        return nil if isolation != :worktree || options[:dont_push_anything]

        Publisher.new(root:, dry_run: !commit?(options))
      end

      # @param runner [Agentilda::Runner]
      # @param rounds [Array]
      # @param options [Hash]
      # @param seconds [Float] wall clock for the whole loop
      # @return [void]
      def report(runner, rounds, options, seconds: 0.0)
        rounds.each do |round|
          puts "round #{round.number}"
          round.attempts.each do |a|
            mark = if !a.ok
              "FAIL"
            elsif a.advanced?
              "#{a.from} -> #{a.to}"
            else
              "no change"
            end
            puts "  #{a.ordinal}\t#{a.agent}\t#{mark}\t#{a.note}"
          end
        end

        # What the run cost, on STDOUT with the rounds it belongs to, so a run
        # redirected to a file keeps its bill. A dry run spent nothing and gets
        # none of this.
        tally = Tally.new(attempts: rounds.flat_map(&:attempts), seconds:, rounds: rounds.size)
        puts("", tally.render) if commit?(options)

        return if quiet?(options)

        advanced = rounds.sum(&:advanced)
        blocked = runner.blocked
        summary = ["#{rounds.size} round#{"s" unless rounds.size == 1}", "#{advanced} advanced"]
        summary << (runner.isolated? ? "#{runner.jobs} at a time, one worktree each" : "serial, shared tree")
        summary << "#{blocked.size} blocked" unless blocked.empty?
        summary << "#{failures(rounds).size} failed" unless failures(rounds).empty?

        if !commit?(options)
          warn("Dry run — no agent was invoked.\n#{summary.join(" · ")}\n\nRe-run with --commit.")
        elsif failures(rounds).empty?
          success("#{summary.join(" · ")}#{"\n\nEvery plan is done or deliberately parked." if runner.settled?}")
        else
          error("#{summary.join(" · ")}\n\n#{failures(rounds).map { |f| "#{f.ordinal} #{f.agent}: #{f.note}" }.join("\n")}")
        end

        return if blocked.empty?

        warn("#{blocked.size} plan#{"s" unless blocked.size == 1} need a human decision:\n" +
             blocked.map { |b| "  #{b.feature.ordinal} #{b.status.emoji} #{b.feature.title} — see blocked.md" }.join("\n") +
             "\n\nWrite the answers into blocked.md, then: agentilda unblock " \
             "#{blocked.map { |b| b.feature.ordinal }.join(",")} --commit")
      end
    end
  end
end
