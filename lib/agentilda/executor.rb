# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Agentilda
  # Runs one agent against one plan by shelling out to the `claude` CLI.
  #
  # The autonomy boundary is "docs plus code, but nothing leaves the machine",
  # and it is enforced twice over:
  #
  #   BEFORE — the agent is told, and `--disallowedTools` withholds the tools
  #            that would let it push.
  #   AFTER  — the harness checks that HEAD did not move and no new remote ref
  #            appeared. A prompt is a request; a check is a guarantee, and only
  #            one of them survives a model deciding it knows better.
  class Executor
    # What one invocation did, and what it spent doing it.
    #
    # {#to_ary} is deliberate: every caller of {Executor#call} destructures
    # `ok, note = executor.call(...)`, and the meter is an addition to that
    # answer rather than a replacement for it. Callers that want the tokens
    # ask for them by name.
    #
    # @!attribute [r] ok
    #   @return [Boolean]
    # @!attribute [r] note
    #   @return [String] one line, for the report
    # @!attribute [r] up
    #   @return [Integer] tokens sent, sub-agents included
    # @!attribute [r] down
    #   @return [Integer] tokens generated
    # @!attribute [r] subagents
    #   @return [Integer] sub-agents this agent spawned
    # @!attribute [r] delegated
    #   @return [Integer] of {#up}, how much arrived as an unsplit sub-agent
    #     total rather than as a direction of its own
    # @!attribute [r] seconds
    #   @return [Float] wall clock, from argv to exit
    # @!attribute [r] killed
    #   @return [Symbol, nil] :timeout when the clock's backstop fired, :key
    #     when somebody pressed k, :budget when the token meter crossed the
    #     cap, :quit when the grace period after q ran out, nil otherwise
    # @!attribute [r] pid
    #   @return [Integer, nil]
    # @return [Data]
    Result = Data.define(:ok, :note, :up, :down, :subagents, :delegated, :seconds, :killed, :pid) do
      def initialize(killed: nil, pid: nil, **rest) = super

      # @return [Array(Boolean, String)]
      def to_ary = [ok, note]
    end

    # What the dispatcher holds on a running invocation, so a keypress can
    # reach it: the process, its clock and its control file.
    #
    # Filled in by {#call} once the child exists. Every method tolerates the
    # gap before that, because the keyboard does not wait.
    class Handle
      # @return [Agentilda::Child, nil]
      attr_accessor :child

      # @return [Agentilda::Clock, nil]
      attr_accessor :clock

      # @return [String, nil]
      attr_accessor :control

      # @return [Symbol, nil] why the process was killed, once it was
      attr_reader :killed

      # @return [Integer, nil]
      def pid = child&.pid

      # @return [Integer, nil]
      def remaining = clock&.remaining

      # @return [Symbol, nil]
      def phase = clock&.phase

      # STOP, a grace period, then SIGKILL if it is still there. The grace is
      # what lets an agent mid-write finish the line.
      #
      # @param grace [Integer] seconds
      # @param reason [Symbol] :key, :timeout, :budget or :quit
      # @return [void]
      def kill!(grace: 15, reason: :key)
        @killed ||= reason
        Control.write(control, Control::STOP) if control
        sleep(grace) if grace.positive?
        child&.kill("KILL") if child&.alive?
      end

      # @param seconds [Integer]
      # @return [void]
      def extend!(seconds) = clock&.extend!(seconds)
    end

    # Tools no agent may use under this autonomy level, whatever its definition
    # asks for. Git itself is reachable through Bash, which is why the
    # after-check exists as well.
    #
    # The exception is an agent that declares `network: true`. Closed is the
    # right default — most specialists here read the repository and write to
    # it, and a model that decides to go looking online mid-task is a model
    # doing something nobody asked for. But a researcher inverts that: reading
    # the internet is the entire job, and denying it silently produced an
    # agent that ran, found nothing, and reported success.
    DENIED_TOOLS = %w[WebFetch WebSearch].freeze

    # Commands that leave the machine, denied to every agent by default.
    #
    # These are passed to `claude` as `Bash(<command>:*)` tool specifiers, so
    # they are withheld rather than merely discouraged. This list spent a while
    # as a regular expression that nothing referenced — a guard in the shape of
    # a constant, enforcing nothing — which is exactly how `gh pr review` came
    # to be reachable by an agent nobody had granted it to.
    FORBIDDEN_COMMANDS = [
      "git push", "git commit",
      "gh pr create", "gh pr edit", "gh pr merge",
      "gh pr review", "gh pr comment",
      "gh release create"
    ].freeze

    # The subset no agent's `may:` can lift, however its definition is written.
    #
    # Pushing and merging change a branch everybody else builds on, and an
    # unattended loop doing either has no way to be wrong quietly. Reviewing
    # does not: an approval is reversible, visible, and attributable to the
    # identity that made it. That difference is the whole line between
    # `hansolo-reviewer` approving and `hansolo-reviewer` merging.
    UNGRANTABLE = ["git push", "gh pr merge"].freeze

    # How much of what the agent said survives into a one-line report.
    REASON_LIMIT = 300

    # Seconds an agent gets when neither its frontmatter nor `--timeout` says.
    DEFAULT_TIMEOUT = 900

    # Where the raw stream of each invocation is kept.
    #
    # Under `run -j` several agents work at once, and more than one
    # `agentilda` may be driving the same checkout, so a trace is named
    # per invocation rather than shared. To get an agent's final answer back
    # out of one afterwards:
    #
    #   jq -r 'select(.type=="result").result' <trace>
    #
    # and to replay what it did, tool call by tool call:
    #
    #   jq -r 'select(.type=="assistant")
    #          | .message.content[]?
    #          | select(.type=="tool_use")
    #          | "\(.name) \(.input|tostring[0:80])"' <trace>
    #
    # Outside the repository on purpose: the harness checks afterwards that the
    # agent moved nothing it should not have, and a megabyte of NDJSON dropped
    # into the working tree is exactly the kind of thing that check would then
    # have to learn to ignore.
    TRACE_DIR = File.join(Dir.tmpdir, "agentilda-traces")

    # Environment variables the `claude` CLI reads as credentials, in
    # preference to a claude.ai login.
    #
    # A project `.env` that sets one of these for the application's own use
    # reaches every agent a run spawns. `claude` then authenticates with that
    # key rather than the login, and a stale or unrelated one turns an entire
    # run into `401 API key is invalid`, three minutes per agent. The CLI warns
    # rather than unsets. Driving it with an API key on purpose is legitimate,
    # and nothing here can tell the two apart.
    CREDENTIAL_VARS = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN].freeze

    # @param env [Hash]
    # @return [Array<String>] credential variables currently set
    def self.foreign_credentials(env = ENV)
      CREDENTIAL_VARS.reject { |name| env[name].to_s.strip.empty? }
    end

    # @param root [String] the repository the agents work in
    # @param spawn [Proc] `argv, chdir:` → {Agentilda::Child}, swappable so the
    #   suite can play back a fake process without spawning one
    # @param timeout [Integer, nil] `--timeout`: a cap on every agent's clock,
    #   or nil to let each agent's own frontmatter clock stand
    # @param dry_run [Boolean] plan the invocation, do not run it
    # @param trace_dir [String] where each invocation's raw stream is kept
    # @param instructions [String, nil] what `run --prompt` typed, appended
    #   to the agent's own prompt. The command only accepts it alongside
    #   `--agent`, so exactly one agent ever hears it.
    # @param model [String, nil] what `run --model` typed. The flag actually
    #   typed beats what an agent's frontmatter declares, the same precedence
    #   every other flag here follows; nil leaves each agent its own choice.
    # @param max_tokens [Integer, nil] budget per invocation, input plus
    #   output, sub-agents included. The prompt states it so the agent can
    #   plan to finish inside it, and the meter enforces it so the statement
    #   is true. nil is unmetered.
    # @param interactive [Boolean] whether someone is at the keyboard, which
    #   the keyboard help reads. Every invocation gets a control file either
    #   way, because the clock writes its own warnings into it regardless of
    #   whether anyone is watching.
    def initialize(root:, spawn: Child.method(:spawn), timeout: nil, dry_run: false,
      trace_dir: TRACE_DIR, instructions: nil, model: nil, max_tokens: nil, interactive: false)
      @root = File.expand_path(root)
      @spawn = spawn
      @timeout = timeout
      @dry_run = dry_run
      @trace_dir = trace_dir
      @instructions = instructions.to_s.strip
      @model = model
      @max_tokens = max_tokens
      @interactive = interactive
    end

    # @return [String]
    attr_reader :root

    # The clock this agent runs against: the tighter of its own frontmatter
    # and `--timeout`. A flag that could only loosen was useless the day
    # somebody wanted a quick run.
    #
    # {DEFAULT_TIMEOUT} steps in only when neither names a figure. It used
    # to be the flag's default instead, which silently cut every 1200-second
    # agent to 900 on the runs where nobody had typed `--timeout` at all.
    #
    # @param agent [Agentilda::Agent]
    # @return [Integer]
    def timeout_for(agent) = [agent.timeout, @timeout].compact.min || DEFAULT_TIMEOUT

    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @param root [String] the checkout the agent works in
    # @param round [Integer] which attempt on this plan this is
    # @param successor [String, nil] who the agent names on its `next:` line
    # @param handle [Agentilda::Executor::Handle, nil] filled in for the caller
    # @param partners [Array<Agentilda::Agent>] the other agents working this
    #   plan right now, named in the prompt beside the plan's mailbox
    # @return [Agentilda::Executor::Result]
    # @yieldparam progress [Agentilda::Transcript::Progress]
    def call(agent, subject, root: @root, round: 1, successor: nil, handle: nil, partners: [], &on_progress)
      started = UI.monotonic
      if @dry_run
        return Result.new(ok: true,
          note: "dry run - would invoke #{agent.name}",
          up: 0,
          down: 0,
          subagents: 0,
          delegated: 0,
          seconds: 0.0)
      end

      handle ||= Handle.new
      before = head(root)
      trace = trace_path(agent, subject)
      transcript = Transcript.new(trace:, &on_progress)
      control = Control.register(@trace_dir, "#{subject.feature.ordinal}-#{agent.name}")
      handle.control = control
      argv = invocation(agent, subject, root:, control:, round:, successor:, partners:)

      child = @spawn.call(argv, chdir: root)
      handle.child = child
      transcript.pid = child.pid
      clock = Clock.new(seconds: timeout_for(agent),
        control:,
        on_expire: -> { handle.kill!(grace: 0, reason: :timeout) })
      handle.clock = clock
      clock.start

      child.each_chunk do |out|
        transcript.push(out)
        abort_if_over(transcript, handle)
      end
      status = child.wait
      transcript.finish
      clock.stop
      Control.release(control)

      if handle.killed
        return spent(transcript,
          started,
          ok:     false,
          pid:    child.pid,
          killed: handle.killed,
          note:   "#{killed_note(handle.killed, clock)}, last seen #{transcript.activity || "starting up"} - trace: #{trace}")
      end
      unless status.success?
        return failure(transcript, started, "claude exited #{status.exitstatus}: #{said(transcript)} - trace: #{trace}", pid: child.pid)
      end
      if transcript.failed?
        return failure(transcript, started, "claude reported: #{transcript.error} - trace: #{trace}", pid: child.pid)
      end

      violation = boundary_violation(before, root)
      return failure(transcript, started, violation, pid: child.pid) if violation

      spent(transcript,
        started,
        ok:   true,
        pid:  child.pid,
        note: "completed#{" - #{transcript.tools} tool calls" if transcript.tools.positive?}")
    end

    # A failed invocation still spent what it spent, and a run that burned two
    # hundred thousand tokens before timing out is a different fact from one
    # that failed to authenticate and spent nothing. Both used to report the
    # same thing.
    #
    # @return [Agentilda::Executor::Result]
    def failure(transcript, started, note, pid: nil) = spent(transcript, started, ok: false, note:, pid:)

    # @return [Agentilda::Executor::Result]
    def spent(transcript, started, ok:, note:, pid: nil, killed: nil)
      Result.new(ok:,
        note:,
        up: transcript.up,
        down: transcript.down,
        subagents: transcript.spawned,
        delegated: transcript.delegated,
        seconds: UI.monotonic - started,
        killed:,
        pid:)
    end

    # @param transcript [Agentilda::Transcript]
    # @return [String] the last few plain lines, clipped
    def said(transcript)
      text = (transcript.failed? ? transcript.error : transcript.plain.last(3).join(" ")).to_s.strip
      return "said nothing" if text.empty?

      text.length > REASON_LIMIT ? "#{text[0, REASON_LIMIT - 1]}..." : text
    end

    # @param reason [Symbol]
    # @param clock [Agentilda::Clock]
    # @return [String]
    def killed_note(reason, _clock)
      case reason
      when :timeout then "timed out (killed #{Clock::GRACE}s after STOP)"
      when :budget then "token budget of #{@max_tokens} exceeded"
      when :quit then "still running after q, killed once the grace period ran out"
      else "killed from the keyboard"
      end
    end

    # The exact argv, exposed so a spec can assert the boundary flags without
    # running anything.
    #
    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @param round [Integer] which attempt on this plan this is
    # @param successor [String, nil] who the agent names on its `next:` line
    # @param partners [Array<Agentilda::Agent>]
    # @return [Array<String>]
    def invocation(agent, subject, root: @root, control: nil, round: 1, successor: nil, partners: [])
      # `--include-partial-messages` is what the token meter runs on. Without
      # it the stream reports a settled input count and a placeholder output
      # count — 2 for a four-thousand-token answer — and a spinner counting
      # what came back would read zero all run. See {Transcript#meter}.
      argv = ["claude", "-p", prompt_for(agent, subject, root, control:, round:, successor:, partners:), "--add-dir", root,
              "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--brief"]
      denied = denied_for(agent)
      argv += ["--disallowedTools", denied.join(",")] unless denied.empty?
      argv += ["--allowedTools", agent.allowed_tools.join(",")] unless agent.allowed_tools.empty?
      model = @model || agent.model
      argv += ["--model", model] if model
      argv += ["--effort", agent.effort] if agent.effort
      argv
    end

    # What this particular agent may not touch: the network tools unless it
    # asked for them, plus every forbidden command it has not been granted.
    # Both decisions are recorded in a reviewable file rather than passed as a
    # flag by whoever happened to start the run.
    #
    # @param agent [Agentilda::Agent]
    # @return [Array<String>]
    def denied_for(agent)
      tools = agent.network ? [] : DENIED_TOOLS
      tools + denied_commands(agent).map { |command| "Bash(#{command}:*)" }
    end

    # @param agent [Agentilda::Agent]
    # @return [Array<String>] commands withheld from this agent
    def denied_commands(agent) = FORBIDDEN_COMMANDS - granted_to(agent)

    # @param agent [Agentilda::Agent]
    # @return [Array<String>] what its `may:` actually buys it
    def granted_to(agent) = agent.may - UNGRANTABLE

    private

    # One file per invocation. The plan number and the agent's name make it
    # findable; the pid and the clock keep two concurrent runs from writing to
    # the same one. See {TRACE_DIR} for how to read one back.
    #
    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @return [String]
    def trace_path(agent, subject)
      FileUtils.mkdir_p(@trace_dir)
      name = format("%s-%s-%s-%d-%04x.ndjson",
        Time.now.strftime("%Y%m%d-%H%M%S"),
        subject.feature.ordinal,
        agent.name,
        Process.pid,
        rand(0x10000))
      File.join(@trace_dir, name)
    end

    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @param round [Integer]
    # @param successor [String, nil]
    # @param partners [Array<Agentilda::Agent>]
    # @return [String]
    def prompt_for(agent, subject, root = @root, control: nil, round: 1, successor: nil, partners: [])
      <<~PROMPT
        #{agent.prompt}

        ---

        ## This invocation

        Plan folder    : #{subject.feature.path}
        Plan number    : #{subject.feature.ordinal}
        Current state  : #{subject.status.emoji} #{subject.status.label}
        Repository root: #{root}

        #{"The folder's name is not currently justified: #{subject.violation}" if subject.violation}
        #{operator_instructions}#{ledger_section(agent, round:, successor:)}#{budget_section}#{time_budget_section(agent)}#{control_section(control)}#{mailbox_section(agent, subject, partners)}
        ## Boundary — enforced, not requested

        You may read anything, and write source, tests and the plan's own
        markdown.

        These are withheld from you, not merely discouraged — `claude` is
        invoked with them disallowed:

        #{denied_commands(agent).map { |c| "  #{c}" }.join("\n")}
        #{granted(agent)}
        The harness checks afterwards that HEAD has not moved, and a round that
        moved it is reported as a failure and rolled into the report. A prompt
        is a request; a check is a guarantee.

        Claim what you are about to write with ~/.claude/agent-lock.sh first,
        and release it when you are done.
      PROMPT
    end

    # The one paragraph every agent gets, identically, about the ledger. It
    # lives here rather than in seven definition files so the wording cannot
    # drift between agents, and so the names, the round and the successor are
    # the harness's facts rather than the agent's guesses.
    #
    # @param agent [Agentilda::Agent]
    # @param round [Integer]
    # @param successor [String, nil]
    # @return [String]
    def ledger_section(agent, round:, successor:)
      documents = agent.ledger.map { |f| "`#{f}`" }.join(", then ")
      handoff = successor ? "\n    > [<now>] [ next: #{successor} ]" : ""
      <<~SECTION

        ## The ledger - write this at the start and at the end

        You sign the document you are working in: #{documents}. Get `<now>` from
        `date "+%Y-%m-%d %I:%M:%S %p %Z"`. Before you do any work, append:

            > [!NOTE]
            >
            > [<now>] [ agent: #{agent.name}   status: Started, round #{round} ]

        When you finish, append:

            > [!NOTE]
            >
            > [<now>] [ agent: #{agent.name}   status: Completed, round #{round} ]#{handoff}

        Write `Completed` only if your assignment is genuinely done. Otherwise write
        `Almost completed`, `Interrupted` or `Blocked` in its place and NO `next:` line.
        The harness renames the plan folder and starts the next agent from these
        lines; you never rename the folder yourself. A short note in parentheses
        after the round is welcome, e.g. `Completed, round 1 (approved)`.
      SECTION
    end

    # The token budget crossed, or the grace period after `q` spent. Both go
    # through the handle so the kill is the same kill a keypress makes.
    #
    # @param transcript [Agentilda::Transcript]
    # @param handle [Agentilda::Executor::Handle]
    # @return [void]
    def abort_if_over(transcript, handle)
      spent = transcript.up + transcript.down
      if @max_tokens&.positive? && spent > @max_tokens
        handle.kill!(grace: 0, reason: :budget)
      elsif Control.overdue?
        handle.kill!(grace: 0, reason: :quit)
      end
    end

    # The section `run --max-tokens` adds. Stating the number is what lets
    # the agent finish before it, rather than discovering the cap by dying
    # on it with half a file written.
    #
    # @return [String]
    def budget_section
      return "" unless @max_tokens&.positive?

      "\n## Token budget — #{@max_tokens} tokens, enforced\n\n" \
        "This invocation is aborted once its total spend (input plus output, " \
        "sub-agents included) crosses #{@max_tokens} tokens. Budget the work: " \
        "plan what fits, write results to disk as you go, and finish — or " \
        "write a handoff note into the plan folder — before the meter runs " \
        "out. Anything unwritten at the cap is lost.\n"
    end

    # The section describing the advisory clock this invocation runs against,
    # stated in the prompt so an agent can pace itself. The number is
    # whatever {#timeout_for} will actually enforce, so the prompt and the
    # clock can never disagree — an agent whose prose names its own figure
    # goes stale the first time someone passes `--timeout`, and stale is
    # worse than silent.
    #
    # @param agent [Agentilda::Agent]
    # @return [String]
    def time_budget_section(agent)
      seconds = timeout_for(agent)
      return "" unless seconds&.positive?

      minutes = (seconds / 60.0).round
      "\n## Time budget - #{seconds} seconds\n\n" \
        "You have about #{minutes} minute#{"s" unless minutes == 1} of wall clock. The control " \
        "file below tells you how it is going: `WARN: 10 minutes left`, `WARN: 5 minutes left`, " \
        "`WRAP_UP: 1 minute left, write to disk now`, then `STOP`. Sixty seconds after STOP " \
        "the process is killed, and anything unwritten is lost. Write each result to disk as " \
        "you reach it, and write your closing ledger line before anything else once you see " \
        "WRAP_UP.#{concurrency_advice(agent)}\n"
    end

    # Only worth saying to an agent that can actually do it. Telling an agent
    # without `Task` to parallelise is telling it to feel bad about a tool it
    # was not given.
    #
    # @param agent [Agentilda::Agent]
    # @return [String]
    def concurrency_advice(agent)
      return "" unless agent.allowed_tools.include?("Task")

      " Where the work divides into parts that do not read each other's output, run them " \
        "as one wave of concurrent sub-agents rather than in series: the wave costs one " \
        "part's wall clock, and the series costs the sum of all of them."
    end

    # Two agents on one plan are two processes. Naming the partner and the
    # exact commands is what replaced guessing the partner's session from
    # every Claude session on the machine.
    #
    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @param partners [Array<Agentilda::Agent>]
    # @return [String]
    def mailbox_section(agent, subject, partners)
      return "" if partners.empty?

      plans_dir = File.dirname(subject.feature.path)
      plan = subject.feature.ordinal
      names = partners.map { |p| "`#{p.name}`" }
      who = names.size == 1 ? "Your partner on this plan is #{names.first}" : "Your partners on this plan are #{names.join(" and ")}"

      <<~SECTION

        ## Mailbox - poll it between steps

        #{who}. You share one worktree and one branch, but not a process, so
        the only way to reach each other is the plan's mailbox:

            #{File.join(subject.feature.path, Mailbox::FILENAME)}

        Read it before each significant step and whenever you finish a unit:

            agentilda mail read --dir "#{plans_dir}" --plan #{plan} --for #{agent.name}

        Pass `--after N`, with the number of the last message you have read,
        to see only what is new. Write to it when you land an interface your
        partner is waiting on, when you amend the contract, when you need
        something from their half, and when you finish:

            agentilda mail send --dir "#{plans_dir}" --plan #{plan} --from #{agent.name} --to #{partners.first.name} "what you need them to know"

        Every message is appended with a number and a timestamp and never
        edited, so a person can read the exchange after the round. A question
        your partner has not answered within a few steps is not a reason to
        stop: write your assumption into implementation-plan.md and carry on.
      SECTION
    end

    # The section a control file adds. Present on every invocation, because
    # the advisory clock writes into it whether or not anyone is watching.
    #
    # @param control [String, nil]
    # @return [String]
    def control_section(control)
      return "" if control.nil?

      "\n## Control file — poll it between steps\n\n    " \
        "#{control}\n\n" \
        "Read this file before each significant step. Empty means carry on. " \
        "A line starting WARN: tells you how much time is left. WRAP_UP: means " \
        "finish the essential remainder now. STOP means write what you have, " \
        "write your ledger line, and end your turn.\n"
    end

    # The section `run --prompt` adds, labelled as coming from the person who
    # started the run so the agent can tell a one-off steer from its own
    # standing definition.
    #
    # @return [String]
    def operator_instructions
      return "" if @instructions.empty?

      "\n## Operator instructions — this invocation only\n\n#{@instructions}\n"
    end

    # Spelled out in the prompt as well as withheld at the tool layer, because
    # an agent that does not know it has been granted something does not use
    # it — and `hansolo-reviewer` silently never approving anything looks
    # exactly like `hansolo-reviewer` approving nothing worth approving.
    #
    # @param agent [Agentilda::Agent]
    # @return [String]
    def granted(agent)
      granted = granted_to(agent)
      return "" if granted.empty?

      "\nYou may run these, which most agents may not:\n\n" +
        granted.map { |c| "  #{c}" }.join("\n") + "\n"
    end

    # @return [String, nil] current commit, or nil outside a repository
    def head(root = @root)
      out = `git -C #{root.shellescape} rev-parse HEAD 2>/dev/null`.strip
      out.empty? ? nil : out
    end

    # @param before [String, nil]
    # @return [String, nil] what boundary was crossed, or nil
    def boundary_violation(before, root = @root)
      return nil if before.nil?

      after = head(root)
      return "agent committed (HEAD moved #{before[0, 7]} → #{after[0, 7]}) — the boundary is docs plus code, no commits" if after != before

      nil
    end
  end
end
