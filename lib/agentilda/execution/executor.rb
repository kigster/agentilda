# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

module Agentilda
  module Execution
    # Runs one agent against one plan by shelling out to a coding agent CLI:
    # `claude` unless the agent's definition or the plan's spec.md names
    # another {Agentilda::Adapters adapter}.
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
        # @return [Agentilda::Execution::Child, nil]
        attr_accessor :child

        # @return [Agentilda::Execution::Clock, nil]
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
      # @param spawn [Proc] `argv, chdir:` → {Agentilda::Execution::Child}, swappable so the
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
      # @param lean [Boolean] start agents without the operator's personal
      #   plugins, skills, hooks and MCP servers; `run --user-config` turns it off
      def initialize(root:, spawn: Child.method(:spawn), timeout: nil, dry_run: false,
        trace_dir: TRACE_DIR, instructions: nil, model: nil, max_tokens: nil, interactive: false, lean: true)
        @root = File.expand_path(root)
        @spawn = spawn
        @timeout = timeout
        @dry_run = dry_run
        @trace_dir = trace_dir
        @instructions = instructions.to_s.strip
        @model = model
        @max_tokens = max_tokens
        @interactive = interactive
        @lean = lean
      end

      # @return [String]
      attr_reader :root

      # @return [String, nil] what `run --model` typed
      attr_reader :model

      # Which CLI, model and effort this agent gets on this plan.
      #
      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject, nil]
      # @return [Agentilda::Agents::Profile]
      def profile_for(agent, subject = nil)
        spec = subject ? Plans::Spec.for(subject) : nil
        Agents::Profile.resolve(agent, spec:, model: @model)
      end

      # The clock this agent runs against: the tighter of its own frontmatter
      # and `--timeout`. A flag that could only loosen was useless the day
      # somebody wanted a quick run.
      #
      # {DEFAULT_TIMEOUT} steps in only when neither names a figure. It used
      # to be the flag's default instead, which silently cut every 1200-second
      # agent to 900 on the runs where nobody had typed `--timeout` at all.
      #
      # @param agent [Agentilda::Agents::Agent]
      # @return [Integer]
      def timeout_for(agent) = [agent.timeout, @timeout].compact.min || DEFAULT_TIMEOUT

      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject]
      # @param root [String] the checkout the agent works in
      # @param round [Integer] which attempt on this plan this is
      # @param successor [String, nil] who the agent names on its `next:` line
      # @param handle [Agentilda::Execution::Executor::Handle, nil] filled in for the caller
      # @param partners [Array<Agentilda::Agents::Agent>] the other agents working this
      #   plan right now, named in the prompt beside the plan's mailbox
      # @return [Agentilda::Execution::Executor::Result]
      # @yieldparam progress [Agentilda::Execution::Transcript::Progress]
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
        profile = profile_for(agent, subject)
        transcript = profile.adapter.transcript(trace:, &on_progress)
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
          return failure(transcript,
            started,
            "#{profile.adapter.executable} exited #{status.exitstatus}: #{said(transcript)} - trace: #{trace}",
            pid: child.pid)
        end
        if transcript.failed?
          return failure(transcript,
            started,
            "#{profile.adapter.executable} reported: #{transcript.error} - trace: #{trace}",
            pid: child.pid)
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
      # @return [Agentilda::Execution::Executor::Result]
      def failure(transcript, started, note, pid: nil) = spent(transcript, started, ok: false, note:, pid:)

      # @return [Agentilda::Execution::Executor::Result]
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

      # @param transcript [Agentilda::Execution::Transcript]
      # @return [String] the last few plain lines, clipped
      def said(transcript)
        text = (transcript.failed? ? transcript.error : transcript.plain.last(3).join(" ")).to_s.strip
        return "said nothing" if text.empty?

        text.length > REASON_LIMIT ? "#{text[0, REASON_LIMIT - 1]}..." : text
      end

      # @param reason [Symbol]
      # @param clock [Agentilda::Execution::Clock]
      # @return [String]
      def killed_note(reason, _clock)
        case reason
        when :timeout then "timed out (killed #{Clock::GRACE}s after STOP)"
        when :budget then "token budget of #{@max_tokens} exceeded"
        when :quit then "still running after #{Control.interrupted? ? "ctrl-c" : "q"}, killed once the grace period ran out"
        else "killed from the keyboard"
        end
      end

      # The exact argv, exposed so a spec can assert the boundary flags without
      # running anything.
      #
      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject]
      # @param round [Integer] which attempt on this plan this is
      # @param successor [String, nil] who the agent names on its `next:` line
      # @param partners [Array<Agentilda::Agents::Agent>]
      # @return [Array<String>]
      def invocation(agent, subject, root: @root, control: nil, round: 1, successor: nil, partners: [])
        profile = profile_for(agent, subject)
        profile.adapter.argv(
          Adapters::Invocation.new(
            prompt:          prompt_for(agent, subject, root, control:, round:, successor:, partners:, profile:),
            root:,
            model:           profile.model,
            effort:          profile.effort,
            allowed_tools:   agent.allowed_tools,
            denied_tools:    denied_for(agent),
            denied_commands: denied_commands(agent),
            network:         agent.network,
            lean:            @lean
          )
        )
      end

      # What this particular agent may not touch: the network tools unless it
      # asked for them, plus every forbidden command it has not been granted.
      # Both decisions are recorded in a reviewable file rather than passed as a
      # flag by whoever happened to start the run.
      #
      # @param agent [Agentilda::Agents::Agent]
      # @return [Array<String>]
      def denied_for(agent)
        tools = agent.network ? [] : DENIED_TOOLS
        tools + denied_commands(agent).map { |command| "Bash(#{command}:*)" }
      end

      # @param agent [Agentilda::Agents::Agent]
      # @return [Array<String>] commands withheld from this agent
      def denied_commands(agent) = FORBIDDEN_COMMANDS - granted_to(agent)

      # @param agent [Agentilda::Agents::Agent]
      # @return [Array<String>] what its `may:` actually buys it
      def granted_to(agent) = agent.may - UNGRANTABLE

      private

      # One file per invocation. The plan number and the agent's name make it
      # findable; the pid and the clock keep two concurrent runs from writing to
      # the same one. See {TRACE_DIR} for how to read one back.
      #
      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject]
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

      # @param agent [Agentilda::Agents::Agent]
      # @param subject [Agentilda::Plans::Subject]
      # @param round [Integer]
      # @param successor [String, nil]
      # @param partners [Array<Agentilda::Agents::Agent>]
      # @return [String]
      def prompt_for(agent, subject, root = @root, control: nil, round: 1, successor: nil, partners: [],
        profile: profile_for(agent, subject))
        Prompt.new(agent:,
          subject:,
          root:,
          profile:,
          round:,
          successor:,
          partners:,
          control:,
          instructions: @instructions,
          max_tokens:   @max_tokens,
          seconds:      timeout_for(agent),
          denied:       denied_commands(agent),
          granted:      granted_to(agent)).to_s
      end

      # The token budget crossed, or the grace period after `q` spent. Both go
      # through the handle so the kill is the same kill a keypress makes.
      #
      # @param transcript [Agentilda::Execution::Transcript]
      # @param handle [Agentilda::Execution::Executor::Handle]
      # @return [void]
      def abort_if_over(transcript, handle)
        spent = transcript.up + transcript.down
        if @max_tokens&.positive? && spent > @max_tokens
          handle.kill!(grace: 0, reason: :budget)
        elsif Control.overdue?
          handle.kill!(grace: 0, reason: :quit)
        end
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
end
