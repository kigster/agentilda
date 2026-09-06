# frozen_string_literal: true

module Agentilda
  # The loop. One tick a second: reap what finished and settle it against
  # the ledger, poll what is running for its latest line, start what is
  # dispatchable, heartbeat the state file, hand the screen a board.
  #
  # Nothing here guesses. An agent that finished says so in its document;
  # the state machine says whether the folder may move; the state file says
  # what an earlier run left behind. When the three disagree the row goes
  # red with the reason, and nobody is re-run to paper over it.
  class Dispatcher
    # One running invocation. `from` is the state the plan showed when the
    # agent was picked; `state` is the one it ran under, after any
    # `starts_as` rename. History is keyed by `state`: luke picked at ⭐️
    # works at 🟡, and keying by ⭐️ would offer him 🟡 afterwards as though
    # he had never been there (the 020.00 regression, run twice over).
    Job = Struct.new(:key, :task, :thread, :handle, :started_at, :file, :status, :message,
      :up, :down, :result, :from, :state, :frame) do
      # @return [Boolean]
      def finished? = !thread.alive?
    end

    # How long a settled row stays on the screen.
    LINGER = 10

    # Seconds a kill waits between STOP and SIGKILL.
    KILL_GRACE = 15

    # @param runner [Agentilda::Runner]
    # @param state [Agentilda::StateFile, nil] nil under a dry run
    # @param rounds [Integer, nil] `--rounds`, a cap that only tightens
    # @param sleeper [Proc] how a tick waits; the suite passes a no-op
    # @param on_board [Proc, nil] receives a {Board} each tick
    def initialize(runner:, state: nil, rounds: nil, sleeper: ->(seconds) { sleep(seconds) }, on_board: nil)
      @runner = runner
      @state = state
      @rounds_cap = rounds
      @sleeper = sleeper
      @on_board = on_board
      @running = []
      @recent = []
      @attempts = []
      @history = Hash.new { |h, k| h[k] = [] }
      @finished_plans = []
      @preferred = {}
      @started_at = UI.monotonic
      @mutex = Mutex.new
    end

    # @return [Array<Agentilda::Dispatcher::Job>]
    attr_reader :running

    # @return [Array<Agentilda::Runner::Attempt>]
    attr_reader :attempts

    # @return [Array<Agentilda::Runner::Attempt>]
    def run
      resume_stranded
      loop do
        tick
        break if done?

        @sleeper.call(1)
      end
      @attempts
    end

    # One cycle. Public so the suite can drive it by hand.
    #
    # @return [void]
    def tick
      reap
      poll
      @running.each { |job| job.handle.kill!(grace: 0) } if Control.overdue?
      dispatch unless Control.quit?
      persist
      @on_board&.call(board)
    end

    # @return [Boolean]
    def done? = @running.empty? && (Control.quit? || next_dispatchable.nil?)

    # `k` from the console: STOP, {KILL_GRACE} seconds, SIGKILL, on a thread
    # so the tick is not held for fifteen seconds.
    #
    # @param key [String] a row's key
    # @return [void]
    def kill(key)
      job = @running.find { |j| j.key == key } or return
      Thread.new { job.handle.kill!(grace: KILL_GRACE) }
    end

    # `x` from the console.
    #
    # @param key [String]
    # @param seconds [Integer]
    # @return [void]
    def extend(key, seconds)
      @running.find { |j| j.key == key }&.handle&.extend!(seconds)
    end

    # @return [Agentilda::Board]
    def board
      up = @attempts.sum(&:up) + @running.sum { |j| j.up.to_i }
      down = @attempts.sum(&:down) + @running.sum { |j| j.down.to_i }
      Board.new(started_at: @started_at, status: run_status,
        plans: (@running.map { |j| j.task.subject.feature.ordinal.to_s } + @recent.map { |r| r[:row].ordinal }).uniq,
        up:, down:, rows: rows, root: @runner.root, running: @running.size,
        live_up: @running.sum { |j| j.up.to_i }, live_down: @running.sum { |j| j.down.to_i })
    end

    private

    # @return [Symbol]
    def run_status
      return :quitting if Control.quit?
      return :wrapping_up if @running.any? { |j| %i[wrap_up stopped].include?(j.handle.phase) }

      :running
    end

    # @return [Array<Agentilda::Board::Row>]
    def rows
      now = UI.monotonic
      @recent.reject! { |r| now - r[:at] > LINGER }
      @running.map { |job| row_for(job) } + @recent.map { |r| r[:row] }
    end

    # @param job [Agentilda::Dispatcher::Job]
    # @return [Agentilda::Board::Row]
    def row_for(job)
      task = job.task
      job.frame = job.frame.to_i + 1
      Board::Row.new(key: job.key, at: Time.now, ordinal: task.subject.feature.ordinal.to_s,
        file: job.file || task.agent.ledger.first.to_s, agent: task.agent.name, role: task.agent.role,
        round: task.round, rounds: rounds_for(task.agent), model: model_for(task.agent),
        remaining: job.handle.remaining, phase: job.handle.phase, up: job.up.to_i, down: job.down.to_i,
        message: job.message, state: :running, pr: pr_for(task), frame: job.frame)
    end

    # @param task [Agentilda::Runner::Task]
    # @return [Hash, nil]
    def pr_for(task)
      return nil unless task.agent.ledger.include?("pull-requests.md")

      subject = Tree.new(dir: @runner.tree.dir).find(task.subject.feature.ordinal) or return nil
      pull = subject.pull_requests.find(&:open?) or return nil
      {number: pull.number, url: pull.url, rejected: subject.status.key == :rejected}
    end

    # @param agent [Agentilda::Agent]
    # @return [Integer]
    def rounds_for(agent) = [agent.rounds, @rounds_cap].compact.min

    # @param agent [Agentilda::Agent]
    # @return [String]
    def model_for(agent)
      executor = @runner.executor
      (executor.respond_to?(:model) && executor.model) || agent.model || "default"
    end

    # ---- starting ---------------------------------------------------------

    # Started stages a dead run left behind get the harness's own line and a
    # place in history, so eligibility treats them as an Interrupted round.
    #
    # @return [void]
    def resume_stranded
      return unless @state

      @state.load
      @state.stranded.each do |ordinal, stage|
        subject = @runner.tree.reload.find(Ordinal.parse(ordinal)) or next
        agent = @runner.agents.find(stage["agent"]) or next
        write_interrupted(subject, agent, stage["round"], "harness died")
        remember(ordinal, agent.name, subject.status.key, "Interrupted", stage["round"])
        @state.record(ordinal, agent: agent.name, round: stage["round"], status: "Interrupted", exit: "harness died")
      end
      @state.begin_run!(root: @runner.root)
    end

    # @return [void]
    def dispatch
      while @running.size < @runner.jobs && (pair = next_dispatchable)
        start(*pair)
      end
    end

    # The next agent and plan to start, honouring a `next:` an agent wrote
    # over definition order.
    #
    # @return [Array(Agentilda::Agent, Agentilda::Subject), nil]
    def next_dispatchable
      reconcile
      @runner.in_scope.each do |subject|
        # After {#reconcile} this is the folder's name. On a dry run, which
        # renames nothing, it is what the name would have become.
        state = Resync::Dirs.target(subject)
        next if StateMachine::SETTLED.include?(state.key)
        next if @finished_plans.include?(subject.feature.ordinal.to_s)

        candidates = @runner.agents.for_status(state)
        preferred = @preferred[subject.feature.ordinal.to_s]
        candidates = candidates.sort_by { |a| (a.name == preferred) ? 0 : 1 } if preferred
        agent = candidates.find { |a| eligible?(a, subject) }
        return [agent, subject] if agent
      end
      nil
    end

    # A folder's name can lag its contents: a run killed before its rename,
    # a plan.md written by hand, a resync nobody ran. So the names are
    # reconciled before every dispatch, the way `resync dirs` would, and a
    # ⚪️ folder that already holds a plan goes to the pair under its honest
    # name rather than to leah-researcher under its stale one. Plans an
    # agent is working in right now are left alone: the prompt names the
    # folder by path, and moving it under a running agent would strand
    # every write it makes afterwards.
    #
    # @return [void]
    def reconcile
      busy = @running.map { |j| j.task.subject.feature.ordinal.to_s }
      Resync::Dirs.new(tree: @runner.tree.reload, except: busy).call(commit: !@runner.dry_run?)
    end

    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @return [Boolean]
    def eligible?(agent, subject)
      ordinal = subject.feature.ordinal.to_s
      return false if @running.any? { |j| j.task.agent.name == agent.name && j.task.subject.feature.ordinal.to_s == ordinal }

      past = @history[[ordinal, agent.name]].select { |h| h[:state] == subject.status.key }
      return true if past.empty?
      return false if %w[Completed Blocked].include?(past.last[:status])

      past.size < rounds_for(agent)
    end

    # @param agent [Agentilda::Agent]
    # @param subject [Agentilda::Subject]
    # @return [void]
    def start(agent, subject)
      ordinal = subject.feature.ordinal.to_s
      round = @history[[ordinal, agent.name]].count { |h| h[:state] == subject.status.key } + 1
      from = subject.status.key
      subject = rename_on_start(subject, agent) unless @runner.dry_run?
      task = @runner.prepare(agent, subject, round)
      handle = Executor::Handle.new
      job = Job.new(key: "#{ordinal}/#{agent.name}", task:, handle:, started_at: UI.monotonic,
        from:, state: subject.status.key, up: 0, down: 0, frame: 0)
      successor = @runner.agents.for_status(STATUS_BY_KEY.fetch(agent.advances_to)).first&.name if agent.advances_to && STATUS_BY_KEY.key?(agent.advances_to)
      remember(ordinal, agent.name, job.state, "Started", round)
      @state&.record(ordinal, agent: agent.name, round:, status: "Started", state: from.to_s,
        model: model_for(agent), file: agent.ledger.first, started_at: Time.now.iso8601)
      UI.log("started", **task.log_fields)
      job.thread = Thread.new do
        Thread.current.report_on_exception = false
        job.result = begin
          @runner.executor.call(agent, subject, root: task.root, round:, successor:, handle:) { |progress|
            job.up = progress.up
            job.down = progress.down
            job.message = progress.message || progress.activity
          }
        rescue => e
          e
        end
      end
      @running << job
    end

    # `starts_as`: the folder moves the moment the agent is dispatched, where
    # the topology allows, so luke's start is what makes a plan 🟡.
    #
    # @return [Agentilda::Subject] fresh, under whichever name it now has
    def rename_on_start(subject, agent)
      target = agent.starts_as
      return subject unless target && subject.machine.may?(target)

      subject.machine.promote!(target)
      Tree.new(dir: @runner.tree.dir).find(subject.feature.ordinal) || subject
    end

    # ---- polling ----------------------------------------------------------

    # @return [void]
    def poll
      @running.each do |job|
        reading = read_ledger(job.task)
        entry = Ledger.last_for(reading, job.task.agent.name)
        job.file = entry&.file || job.file
        job.status = entry&.status
        @state&.record(job.task.subject.feature.ordinal.to_s, agent: job.task.agent.name, round: job.task.round,
          status: entry&.status || "Started", file: job.file, up: job.up, down: job.down, pid: job.handle.pid)
      end
    end

    # @param task [Agentilda::Runner::Task]
    # @return [Agentilda::Ledger::Reading]
    def read_ledger(task)
      subject = Tree.new(dir: @runner.tree.dir).find(task.subject.feature.ordinal) or return Ledger::Reading.empty
      Ledger.read(subject.feature.path, task.agent.ledger)
    end

    # ---- settling ---------------------------------------------------------

    # @return [void]
    def reap
      @running.select(&:finished?).each do |job|
        @running.delete(job)
        attempt = settle(job)
        @attempts << attempt
        @recent << {at: UI.monotonic, row: row_for(job).with(state: attempt.ok ? :done : :failed,
          message: attempt.note, remaining: nil, phase: nil, bold: !attempt.ok)}
        UI.log(attempt.ok ? "finished: #{attempt.note}" : "failed: #{attempt.note}", **job.task.log_fields)
      end
    end

    # @param job [Agentilda::Dispatcher::Job]
    # @return [Agentilda::Runner::Attempt]
    def settle(job)
      task = job.task
      agent = task.agent
      ordinal = task.subject.feature.ordinal.to_s
      result = job.result
      base = attempt_for(job)
      return crashed(job, base, result) if result.is_a?(Exception)
      return base.with(note: result.note) if @runner.dry_run?

      reading = read_ledger(task)
      entry = Ledger.last_for(reading, agent.name)
      entry = nil if entry && entry.round != task.round
      problems = reading.problems.map { |p| "#{p.file}:#{p.line} unreadable ledger line" }

      attempt = if result.killed || (result.ok && (entry.nil? || entry.status == "Started"))
        verify_and_sign(job, base, reason_for(result))
      elsif !result.ok
        remember(ordinal, agent.name, job.state, "Interrupted", task.round)
        base.with(ok: false, note: result.note)
      elsif entry.completed?
        complete(job, base, entry, reading)
      elsif entry.blocked?
        park(job, base, entry)
      else
        remember(ordinal, agent.name, job.state, entry.status, task.round)
        base.with(status: entry.status, note: retry_note(agent, entry))
      end
      attempt = attempt.with(note: "#{attempt.note}; #{problems.join(", ")}") unless problems.empty?
      attempt = attempt.with(to: fresh(task)&.status&.key || attempt.to)
      @state&.record(ordinal, agent: agent.name, round: task.round, status: attempt.status || "Completed",
        exit: attempt.ok ? "ok" : attempt.note, ended_at: Time.now.iso8601, up: attempt.up, down: attempt.down)
      attempt
    end

    # @param result [Agentilda::Executor::Result]
    # @return [String]
    def reason_for(result)
      case result.killed
      when :key then "killed by harness after #{KILL_GRACE}s grace"
      when :timeout then "timed out, killed #{Clock::GRACE}s after STOP"
      else "no closing ledger line"
      end
    end

    # @return [String]
    def retry_note(agent, entry)
      left = rounds_for(agent) - entry.round
      left.positive? ? "#{entry.status}; #{left} round#{"s" unless left == 1} left" : "#{entry.status}; no rounds left"
    end

    # The agent stopped without saying it finished. If the state it was
    # advancing to is justified by what is on disk, the work happened and
    # the harness signs for it, in bold, saying why it had to.
    #
    # @return [Agentilda::Runner::Attempt]
    def verify_and_sign(job, base, reason)
      task = job.task
      agent = task.agent
      subject = fresh(task) or return base.with(ok: false, note: "plan folder vanished")
      write_interrupted(subject, agent, task.round, reason)
      target = agent.advances_to
      if target && subject.machine.may?(target)
        successor = @runner.agents.for_status(STATUS_BY_KEY.fetch(target)).first&.name
        lines = [Ledger.render(Ledger::Entry.new(at: Time.now, agent: agent.name, status: "Completed",
          round: task.round, note: "signed by harness: work verified on disk", file: "", line: 0))]
        lines << Ledger.render_handoff(Ledger::Handoff.new(at: Time.now, next: successor, file: "", line: 0)) if successor
        Ledger.append(File.join(subject.feature.path, agent.ledger.first), *lines)
        entry = Ledger.last_for(read_ledger(task), agent.name)
        complete(job, base.with(note: "#{reason}; signed by harness"), entry, read_ledger(task))
      else
        remember(subject.feature.ordinal.to_s, agent.name, job.state, "Interrupted", task.round)
        base.with(ok: false, status: "Interrupted", note: "#{reason}; #{retry_note(agent, Ledger::Entry.new(at: Time.now, agent: agent.name, status: "Interrupted", round: task.round, file: "", line: 0))}")
      end
    end

    # @return [void]
    def write_interrupted(subject, agent, round, reason)
      line = Ledger.render(Ledger::Entry.new(at: Time.now, agent: agent.name, status: "Interrupted",
        round:, note: reason, file: "", line: 0, bold: true))
      Ledger.append(File.join(subject.feature.path, agent.ledger.first), line)
    end

    # A Completed entry: move the folder, publish if that made it reviewable,
    # and honour the `next:` line.
    #
    # @return [Agentilda::Runner::Attempt]
    def complete(job, base, entry, reading)
      task = job.task
      agent = task.agent
      ordinal = task.subject.feature.ordinal.to_s
      subject = fresh(task) or return base.with(ok: false, note: "plan folder vanished")
      remember(ordinal, agent.name, job.state, "Completed", task.round)
      verdict = verdict_of(entry)
      partner_running = @running.any? { |j| j.task.subject.feature.ordinal.to_s == ordinal }
      target = target_for(agent, verdict, partner_running)

      if verdict == :approved
        @finished_plans << ordinal
        return base.with(status: "Completed", note: "#{base.note}; approved, awaiting merge")
      end

      attempt = base.with(status: "Completed")
      if target
        if subject.machine.may?(target)
          subject.machine.promote!(target)
          attempt = attempt.with(to: target, note: "#{base.note}#{" (#{entry.note})" if entry.note}")
          attempt = publish_if_reviewable(task, target, attempt)
        else
          return attempt.with(ok: false, note: "ledger says Completed but #{STATUS_BY_KEY.fetch(target)} is not justified: #{STATUS_BY_KEY.fetch(target).violation(subject)}")
        end
      end

      handoff = Ledger.handoff_after(reading, entry)
      attempt = honour(handoff, subject, attempt) if handoff
      attempt
    end

    # @param entry [Agentilda::Ledger::Entry]
    # @return [Symbol, nil] :rejected, :approved, :slop, :product or nil
    def verdict_of(entry)
      note = entry.note.to_s.downcase
      return :rejected if note.include?("reject")
      return :approved if note.include?("approv")
      return :slop if note.include?("slop") || note.include?("rewrite")
      return :product if note.include?("product")

      nil
    end

    # @return [Symbol, nil] where the folder goes
    def target_for(agent, verdict, partner_running)
      case verdict
      when :rejected then :rejected
      when :slop then :shit
      else partner_running ? agent.holds_at : agent.advances_to
      end
    end

    # @return [Agentilda::Runner::Attempt]
    def publish_if_reviewable(task, target, attempt)
      return attempt unless target == :ready_for_review

      subject = fresh(task) or return attempt
      publication = @runner.publish(task, subject)
      if publication&.published?
        attempt.with(note: "#{attempt.note}; opened #{publication.url}")
      elsif publication&.refusal
        attempt.with(note: "#{attempt.note}; publish refused: #{publication.refusal}")
      else
        attempt
      end
    end

    # A `next:` that names someone who handles the plan's new state is
    # honoured by preferring them; one that does not is reported, and the
    # state's own agents take it, because a wrong name must not stall a plan.
    #
    # @return [Agentilda::Runner::Attempt]
    def honour(handoff, subject, attempt)
      current = fresh_by(subject.feature.ordinal) || subject
      named = @runner.agents.find(handoff.next)
      if named&.handles?(current.status)
        @preferred[current.feature.ordinal.to_s] = named.name
        attempt
      else
        who = named ? "does not handle #{current.status}" : "is not an agent"
        attempt.with(note: "#{attempt.note}; next: names #{handoff.next}, who #{who}")
      end
    end

    # @return [Agentilda::Runner::Attempt]
    def park(job, base, entry)
      task = job.task
      subject = fresh(task) or return base.with(ok: false, note: "plan folder vanished")
      remember(subject.feature.ordinal.to_s, task.agent.name, job.state, "Blocked", task.round)
      target = (verdict_of(entry) == :product) ? :product_blocked : :blocked
      if subject.machine.may?(target)
        subject.machine.promote!(target)
        base.with(to: target, status: "Blocked", note: "blocked; see blocked.md")
      else
        base.with(ok: false, status: "Blocked", note: "ledger says Blocked but #{STATUS_BY_KEY.fetch(target).violation(subject)}")
      end
    end

    # @return [Agentilda::Runner::Attempt]
    def crashed(job, base, error)
      remember(base.ordinal, base.agent, job.state, "Interrupted", base.round)
      base.with(ok: false, note: error.message.lines.first.to_s.strip)
    end

    # @param job [Agentilda::Dispatcher::Job]
    # @return [Agentilda::Runner::Attempt]
    def attempt_for(job)
      task = job.task
      result = job.result
      spend = ->(field) { result.respond_to?(field) ? result.public_send(field) : 0 }
      Runner::Attempt.new(ordinal: task.subject.feature.ordinal.to_s, agent: task.agent.name, from: job.from,
        to: job.from, ok: result.respond_to?(:ok) ? !!result.ok : false,
        note: result.respond_to?(:note) ? result.note.to_s : "", up: spend.call(:up), down: spend.call(:down),
        subagents: spend.call(:subagents), delegated: spend.call(:delegated), seconds: spend.call(:seconds),
        round: task.round, file: job.file || task.agent.ledger.first.to_s, model: model_for(task.agent), status: job.status)
    end

    # @return [Agentilda::Subject, nil] the plan read fresh from the main tree
    def fresh(task) = fresh_by(task.subject.feature.ordinal)

    # @return [Agentilda::Subject, nil]
    def fresh_by(ordinal) = Tree.new(dir: @runner.tree.dir).find(ordinal)

    # One entry per round: the Started written at dispatch is overwritten by
    # the outcome rather than joined by it. Two entries a round would spend
    # an agent's rounds at double speed and number them 1, 3, 5.
    #
    # @return [void]
    def remember(ordinal, agent, state, status, round)
      @mutex.synchronize do
        entries = @history[[ordinal.to_s, agent]]
        entry = entries.find { |h| h[:state] == state && h[:round] == round }
        entry ? entry[:status] = status : entries << {state:, status:, round:}
      end
    end

    # @return [void]
    def persist
      return unless @state

      @state.heartbeat!
      @state.save
    end
  end
end
