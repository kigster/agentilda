# frozen_string_literal: true

module Agentilda
  module CLI
    # `agentilda start` — the factory as a long-lived service: `run` with the
    # control room on, idling instead of ending at a fixed point.
    #
    # `run` ends the moment nothing is dispatchable, which is also the moment
    # palpatine-planner blocks on a question: the engine stops, the page
    # with the question on it dies with it, and the answer has nowhere to
    # go. `start` stays. It keeps the board published and the commands read,
    # rescans the tree, and starts agents as soon as an answer, a new plan
    # or a hand edit makes something dispatchable. It needs no plans to
    # start: the page's New idea creates them. It never ends on its own,
    # finished plans included; only Stop All, Ctrl-C, SIGTERM or the control
    # room going away end it.
    #
    # The page is the only way in: every decision a person makes goes through
    # it, and the terminal is output only. So there is no headless fallback
    # (Redis and the control room are required, not hoped for), no dry run,
    # and no `--no-web`.
    class Start < Run
      desc "Run the factory and its control room until Stop All; plans and questions go through the page"

      # Inherited from `run`, and meaningless here: a dry run publishes no
      # board, and a run without its page cannot be answered.
      @options = options.reject { %i[dry_run web].include?(it.name) }

      option :rescan,
        default: Engine::Dispatcher::RESCAN.to_s,
        desc:    "Seconds between rescans of .plans while idle; a command from the page rescans at once"

      example [
        "                       # engine and control room, until Stop All or Ctrl-C",
        "--no-open              # print the control room's URL, open no browser",
        "--port 4848 -j 4       # somewhere other than 4747, four agents at a time",
        "--plan 005             # only plan 005"
      ]

      # Exit status when Redis or the control room is not there to serve.
      UNAVAILABLE = 69

      # The progress log, echoed to the terminal: the terminal is where a
      # person watches `start` from when the page is closed, and it takes
      # no input.
      #
      # @param options [Hash]
      # @return [void]
      def call(**options)
        @rescan = Integer(options.fetch(:rescan, Engine::Dispatcher::RESCAN), exception: false)
        refuse("--rescan takes a whole number of seconds, at least 1.", 64) unless @rescan&.positive?

        tap = UI.tap_log(lambda { |message, fields|
          next if UI.quiet

          Kernel.warn(Engine::ProgressLog.render(message, **fields.slice(:plan, :status, :agent, :seconds, :round)))
        })
        super
      ensure
        UI.untap_log(tap) if tap
      end

      private

      # No plans is where a project starts, and the page's New idea is how
      # the first one arrives, so a missing `.plans/` is made rather than
      # refused.
      #
      # @param options [Hash]
      # @return [Agentilda::Plans::Tree]
      def tree_for(options)
        tree = Plans.tree(options.fetch(:dir, Agentilda::PLANS_DIR))
        return tree if tree.exist?

        FileUtils.mkdir_p(tree.dir)
        info("Created #{tree.dir}: no plans yet, so the control room opens on New idea.") unless quiet?(options)
        tree
      end

      # @param _options [Hash]
      # @param web [Agentilda::Web::Launcher] always connected: {#without_web} refuses otherwise
      # @return [Hash]
      def staying(_options, web) = { stay: true, rescan: @rescan, lifeline: web.method(:serving?) }

      # TERM too: a service manager stops a service that way, and it gets
      # the same graceful stop as Ctrl-C.
      #
      # @return [Array<String>]
      def signals = %w[INT TERM]

      # @return [void]
      def without_live(message, _options)
        refuse("#{message}\n\ntilda start needs Redis: its control room is the only way to answer the " \
               "agents' questions. Start redis-server, or pass --redis-url. " \
               "`tilda run` goes on without it, headless.",
          UNAVAILABLE)
      end

      # @return [void]
      def without_web(web, live, _options)
        live.close
        refuse("The control room did not answer on #{web.url}, and tilda start is no use without it. " \
               "Its log: #{web.log}",
          UNAVAILABLE)
      end

      # A project with nothing left to do opens on the idea dialog (W19).
      #
      # @return [String]
      def browser_url(web, tree)
        open = tree.subjects.reject { Engine::Dispatcher::FINISHED.include?(it.status.key) }
        open.empty? ? "#{web.url}#start" : web.url
      end

      # What the service did, and exit 0: it only ever ends by being
      # stopped, which is not a failure, and the failed attempts it lived
      # through are listed above the box.
      #
      # @return [void]
      def finish(runner, attempts, options, seconds:)
        puts ""
        puts attempt_lines(attempts)
        puts("", Engine.tally(attempts:, seconds:).render)
        unless quiet?(options)
          blocked = runner.blocked.map { it.feature.ordinal }
          lines = ["Stopped. Unfinished plans keep their state; tilda start picks them up again."]
          lines << "Still waiting for answers: #{blocked.join(", ")}" unless blocked.empty?
          success("#{attempts.size} invocation#{"s" unless attempts.size == 1}, " \
                  "#{attempts.count(&:advanced?)} advanced\n\n#{lines.join("\n")}")
        end
        exit(0)
      end
    end
  end
end
