# frozen_string_literal: true

require "json"

module Agentilda
  module Live
    # The engine's side of the command stream (W13). Called at the top of
    # every tick, on the loop thread, it reads what the page sent through the
    # `engine` consumer group, applies each command to the dispatcher, and
    # answers it.
    #
    # Delivery is at least once: a command is acknowledged only after it has
    # been applied, in the same `MULTI` that records its reply in `done` and
    # appends it to `replies`. A command whose id is already in `done` was
    # applied before the engine died, so it is acknowledged and its first
    # reply sent again, and nothing is applied twice.
    #
    # Each kind is one method, named in {HANDLERS}. A handler raises
    # {Refusal} with the reason a person will read; anything it returns is
    # a reason to show beside "done".
    class Commands
      # A command the engine will not apply, with the reason why.
      class Refusal < StandardError; end

      # Commands read per tick, so a flood cannot hold the loop.
      BATCH = 50

      # Seconds between sweeps of `done` for entries older than a day.
      SWEEP_EVERY = 600

      # Command kind to the method that applies it.
      HANDLERS = {
        "answer"       => :answer,
        "hold_blocked" => :hold_blocked,
        "release_hold" => :release_hold,
        "resume"       => :resume,
        "discard"      => :discard,
        "message"      => :message,
        "hold"         => :signal,
        "wrap_up"      => :signal,
        "compact"      => :signal,
        "stop"         => :signal,
        "stop_all"     => :stop_all,
        "set_model"    => :set_model,
        "switch_model" => :switch_model,
        "add_plan"     => :add_plan,
        "create_plans" => :create_plans
      }.freeze

      # Plans a person may not add to a run: there is nothing left to do.
      FINISHED = Snapshot::FINISHED

      # @param store [Agentilda::Live::Store, Agentilda::Live::MemoryStore]
      # @param keys [Agentilda::Live::Keys]
      # @param node [Agentilda::Live::Node]
      # @param run_state [Agentilda::Live::RunState]
      # @param claims [Agentilda::Live::Claims, nil]
      # @param clock [Proc] wall time
      def initialize(store:, keys:, node:, run_state: RunState.new, claims: nil, clock: -> { Time.now })
        @store = store
        @keys = keys
        @node = node
        @run_state = run_state
        @claims = claims
        @clock = clock
        @ready = false
        @swept_at = nil
      end

      # Apply everything waiting: this consumer's unacknowledged commands
      # first, which a previous engine read and died on, then new ones.
      #
      # @param dispatcher [Agentilda::Engine::Dispatcher]
      # @return [Array<Agentilda::Live::Reply>] what was answered
      def call(dispatcher)
        prepare
        entries = read("0")
        entries += read(">") if entries.size < BATCH
        replies = entries.map { |entry| handle(entry, dispatcher) }
        sweep
        replies
      rescue Unavailable => e
        UI.log("commands not read: #{e.message}")
        []
      end

      # @return [Proc] for {Engine::Dispatcher#before_tick}
      def to_proc = method(:call).to_proc

      private

      # @return [void]
      def prepare
        return if @ready

        @store.xgroup_create(@keys.commands, Keys::GROUP, from: "0")
        @ready = true
      end

      # @param id [String] "0" for this consumer's pending, ">" for new
      # @return [Array<Agentilda::Live::Store::Entry>]
      def read(id) = @store.xreadgroup(@keys.commands, Keys::GROUP, @node.name, id:, count: BATCH)

      # @param entry [Agentilda::Live::Store::Entry]
      # @param dispatcher [Agentilda::Engine::Dispatcher]
      # @return [Agentilda::Live::Reply]
      def handle(entry, dispatcher)
        command = Command.parse(entry.fields["json"].to_s)
        if (first = @store.hget(@keys.done, command.id))
          return answer_again(entry, first)
        end

        reply(entry, command.id, *apply(command, dispatcher))
      rescue Command::Invalid => e
        reply(entry, invalid_id(entry), "refused", e.message)
      end

      # @return [Array(String, String)] status and reason
      def apply(command, dispatcher)
        reason = send(HANDLERS.fetch(command.kind), command, dispatcher)
        ["done", reason.is_a?(String) ? reason : nil]
      rescue Refusal, Agentilda::Error => e
        ["refused", e.message]
      rescue StandardError => e
        UI.log("#{command.kind} failed: #{e.class}: #{e.message}", plan: command.plan)
        ["refused", "#{command.kind} failed: #{e.message}"]
      end

      # @return [Agentilda::Live::Reply]
      def reply(entry, id, status, reason)
        reply = Reply.new(id:, status:, reason:, at: @clock.call)
        json = reply.to_json
        @store.multi do |tx|
          tx.hset(@keys.done, id, json)
          tx.xadd(@keys.replies, { json: }, maxlen: Keys::REPLIES_LENGTH)
          tx.xack(@keys.commands, Keys::GROUP, entry.id)
        end
        reply
      end

      # @return [Agentilda::Live::Reply] the first reply, sent again
      def answer_again(entry, first)
        @store.multi do |tx|
          tx.xadd(@keys.replies, { json: first }, maxlen: Keys::REPLIES_LENGTH)
          tx.xack(@keys.commands, Keys::GROUP, entry.id)
        end
        data = JSON.parse(first)
        Reply.new(id: data["id"], status: data["status"], reason: data["reason"], at: Time.iso8601(data["at"]))
      end

      # A command too malformed to carry an id is answered under its stream
      # entry's id, so the reply still lands somewhere a person can see.
      #
      # @return [String]
      def invalid_id(entry)
        id = JSON.parse(entry.fields["json"].to_s)["id"].to_s
        id.match?(Command::ID) ? id : entry.id
      rescue JSON::ParserError, TypeError, NoMethodError
        entry.id
      end

      # Forget replies older than {Keys::DONE_TTL}; a command redelivered a
      # day late has bigger problems than being applied twice.
      #
      # @return [void]
      def sweep
        now = @clock.call
        return if @swept_at && now - @swept_at < SWEEP_EVERY

        @swept_at = now
        stale = @store.hgetall(@keys.done).select { |_, json| now - Time.iso8601(JSON.parse(json)["at"]) > Keys::DONE_TTL }
        @store.hdel(@keys.done, *stale.keys)
      rescue JSON::ParserError, ArgumentError
        nil
      end

      # ---- questions --------------------------------------------------------

      # `## A<n>` under the question, signed, for `lando-broker` to fold in
      # (W10). The plan leaves ⭕️ when the broker has drained the file.
      #
      # @return [String, nil]
      def answer(command, dispatcher)
        subject, question = question!(command, dispatcher)
        return "B#{question.number} already has an answer waiting" if question.answered

        File.open(File.join(subject.feature.path, "blocked.md"), "a") do |file|
          file.write("\n## A#{question.number}\n\n#{command["text"]}\n\n" \
                     "Answered by #{@node.user} on #{@clock.call.strftime("%Y-%m-%d")}\n")
        end
        @run_state.hold_question(question_id(subject, question), held: false)
        nil
      end

      # @return [nil]
      def hold_blocked(command, dispatcher) = hold_question(command, dispatcher, held: true)

      # @return [nil]
      def release_hold(command, dispatcher) = hold_question(command, dispatcher, held: false)

      # @return [nil]
      def hold_question(command, dispatcher, held:)
        subject, question = question!(command, dispatcher)
        @run_state.hold_question(question_id(subject, question), held:)
        nil
      end

      # @return [Array(Agentilda::Plans::Subject, Agentilda::Lifecycle::Unblocker::Question)]
      def question!(command, dispatcher)
        subject = subject!(command, dispatcher)
        number = command["question"][/\AB?(\d+)\z/i, 1] or raise Refusal, "#{command["question"]} is not a question number like B2"
        question = Lifecycle::Unblocker.questions(subject).find { it.number == number.to_i } or
          raise Refusal, "#{command.plan} has no open question B#{number}"
        [subject, question]
      end

      # @return [String]
      def question_id(subject, question) = "#{subject.feature.ordinal}/B#{question.number}"

      # ---- agents -----------------------------------------------------------

      # The agent the plan's history says was interrupted is started again,
      # with the person's note waiting in its mailbox.
      #
      # @return [String]
      def resume(command, dispatcher)
        subject = subject!(command, dispatcher)
        last = Plans::PlanState.for(subject.feature.path).stages.rfind { it["status"] == "Interrupted" }
        agent = command.agent.to_s.empty? ? last&.fetch("agent", nil) : command.agent
        raise Refusal, "#{command.plan} has no interrupted agent to resume" unless agent

        note = command["note"].empty? ? "carry on from your last resume note" : command["note"]
        Plans::Mailbox.new(dir: subject.feature.path).append(from: "human", to: agent, body: "RESUME: #{note}")
        dispatcher.resume(subject.feature.ordinal, agent)
        dispatcher.runner.add_plan(subject.feature.ordinal)
        "#{agent} resumes on #{command.plan} at its next turn"
      end

      # @return [void]
      # @raise [Refusal] always, until the engine can undo a state
      def discard(command, _dispatcher)
        raise Refusal,
          "discard is not built yet: resetting #{command.plan}'s worktree and sending it back one " \
          "state need an undo the engine does not have. Use stop on each agent instead."
      end

      # A person's message, into the plan's mailbox, from `human` (W10). To
      # the agent named, or every agent working the plan when none is.
      #
      # @return [nil]
      def message(command, dispatcher)
        subject = subject!(command, dispatcher)
        to = command.agent.to_s.empty? ? running_on(dispatcher, command.plan) : [command.agent]
        raise Refusal, "no agent named, and none is working #{command.plan}" if to.empty?

        mailbox = Plans::Mailbox.new(dir: subject.feature.path)
        to.each do |agent|
          mailbox.append(from: "human", to: agent, body: command["text"])
          @run_state.hold_car("#{command.plan}/#{agent}", held: false)
        end
        nil
      end

      # HOLD, WRAP_UP, STOP or COMPACT into one agent's control file.
      #
      # @return [nil]
      def signal(command, dispatcher)
        dispatcher.signal(command.car, Execution::Control::WORDS.fetch(command.kind)) or
          raise Refusal, "#{command.car} is not running"
        @run_state.hold_car(command.car, held: command.kind == "hold")
        nil
      end

      # @return [String]
      def stop_all(_command, dispatcher)
        Execution::Control.quit!
        "stopping #{dispatcher.running.size} agent#{"s" unless dispatcher.running.size == 1} on #{@node.label}"
      end

      # The model for the agent's next round on this plan (W24).
      #
      # @return [String]
      def set_model(command, dispatcher)
        id = model!(command, dispatcher)
        dispatcher.prefer_model(command.plan, command.agent, id) or
          raise Refusal, "this run's executor cannot change an agent's model"
        @run_state.choose_model(command.car, id)
        "#{command.agent} runs on #{id} from its next round"
      end

      # The model now (W27): the agent is stopped with a resume note and
      # started again on it.
      #
      # @return [String]
      def switch_model(command, dispatcher)
        raise Refusal, "#{command.car} is not running; use set_model for its next round" unless dispatcher.job(command.car)

        set_model(command, dispatcher)
        dispatcher.requeue(command.car)
        "#{command.agent} stops at its next step and restarts on #{@run_state.model_for(command.car)} " \
          "from its resume note; its session is not carried over"
      end

      # @return [String] the full model id
      def model!(command, dispatcher)
        subject!(command, dispatcher)
        agent = dispatcher.runner.agents.find(command.agent) or raise Refusal, "no agent called #{command.agent}"
        adapter = Adapters.for(agent.adapter)
        return command["model"] if adapter.models.empty?

        entry = adapter.model_entry(command["model"]) or raise Refusal, "#{adapter.name} offers no model #{command["model"]}"
        entry.id
      end

      # ---- plans ------------------------------------------------------------

      # @return [String, nil]
      def add_plan(command, dispatcher)
        ordinal = Plans::Ordinal.parse(command["ordinal"]) or raise Refusal, "#{command["ordinal"]} is not a plan number"
        subject = dispatcher.runner.tree.reload.find(ordinal) or raise Refusal, "there is no plan #{ordinal}"
        raise Refusal, "#{ordinal} is #{subject.status}, with nothing left to do" if FINISHED.include?(subject.status.key)

        claim!(ordinal)
        dispatcher.runner.add_plan(ordinal)
        nil
      end

      # The idea becomes a ⚪️ plan whose spec.md opens with it, then joins the run.
      #
      # @return [String]
      def create_plans(command, dispatcher)
        tree = dispatcher.runner.tree
        idea = command["idea"]
        path = Lifecycle.create(dir: tree.dir, words: idea.split.first(8)).either(
          ->(created) { created },
          ->(problem) { raise Refusal, "could not create the plan: #{problem}" }
        )
        feature = Plans::Feature.parse(path)
        Lifecycle.brief(path:, title: feature.title, root: File.dirname(tree.dir), seed: idea).write_scaffold!
        claim!(feature.ordinal)
        dispatcher.runner.add_plan(feature.ordinal)
        "created #{feature.ordinal} #{feature.slug}"
      end

      # @return [void]
      def claim!(ordinal)
        return if @claims.nil? || @claims.claim(ordinal)

        raise Refusal, "#{ordinal} is being worked on #{holder_label(@claims.held_by(ordinal))}"
      end

      # @param holder [String, nil] a node name
      # @return [String] `user@host` when the holder's heartbeat says
      def holder_label(holder)
        json = holder && @store.hget(@keys.nodes, holder)
        json ? JSON.parse(json).values_at("user", "host").join("@") : "another machine"
      end

      # ---- lookups ----------------------------------------------------------

      # @return [Agentilda::Plans::Subject]
      def subject!(command, dispatcher)
        ordinal = Plans::Ordinal.parse(command.plan.to_s) or raise Refusal, "#{command.plan} is not a plan number"
        dispatcher.runner.tree.reload.find(ordinal) or raise Refusal, "there is no plan #{command.plan}"
      end

      # @return [Array<String>] agents working the plan now
      def running_on(dispatcher, plan)
        dispatcher.running.filter_map { |job| job.task.agent.name if job.key.start_with?("#{plan}/") }
      end
    end
  end
end
