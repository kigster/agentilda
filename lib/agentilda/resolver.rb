# frozen_string_literal: true

require "digest"
require "json"

module Agentilda
  # Asks `jabba-resolver` which plan a pull request implements.
  #
  # This is the step `resync prs` reaches when the branch name and the diff's
  # paths have both failed to settle a pull request. It is a judgment, not a
  # lookup, so it goes to a model — through the same `claude -p` seam every
  # other agent uses, with three differences that make it a judge rather than
  # a worker:
  #
  #   - **One process per pull request.** Accuracy over cost: the whole plan
  #     index travels with every call, and a small batch is a small batch of
  #     mistakes. The processes run concurrently on the usual thread pool.
  #   - **No tools, no ledger, no control file.** The prompt carries everything
  #     and the answer is the whole output, so none of {Executor}'s machinery
  #     for long-running agents applies.
  #   - **`--json-schema`.** The CLI guarantees the shape of the answer, so
  #     Ruby parses it and never scrapes a chat message for a JSON block. A
  #     response that fails validation is *no verdict* — never a guess.
  #
  # Verdicts are cached on disk, keyed by the pull request's head commit and
  # a digest of the plan index, so a dry run followed by `--commit` asks the
  # model once, and a rerun after nothing changed asks it nothing.
  class Resolver
    # The definition file this consults.
    AGENT_NAME = "jabba-resolver"

    # How much of each spec.md the index carries.
    SPEC_EXCERPT = 2000

    # Seconds one verdict may take when the agent's frontmatter is silent.
    DEFAULT_TIMEOUT = 120

    # Where verdicts live between runs.
    CACHE_ROOT = File.join(Dir.home, ".cache", "agentilda")

    # What the model must answer with. Passed to `claude --json-schema`.
    SCHEMA = {
      "type" => "object",
      "properties" => {
        "plan" => {"type" => %w[string null], "description" => "A plan number from the index, NNN.MM, or null"},
        "confidence" => {"type" => "number", "minimum" => 0, "maximum" => 1},
        "reason" => {"type" => "string"},
        "dev" => {"type" => "boolean"}
      },
      "required" => %w[plan confidence reason dev],
      "additionalProperties" => false
    }.freeze

    # Dollars per million tokens, by the model alias the agent names. Used
    # only when `claude` does not report `total_cost_usd` itself.
    RATES = {
      "haiku" => {up: 1.0, down: 5.0},
      "sonnet" => {up: 3.0, down: 15.0},
      "opus" => {up: 15.0, down: 75.0}
    }.freeze

    # Tools withheld from the judge. It has nothing to read that is not in
    # its prompt, and a judge that starts exploring the repository is a judge
    # spending money on a question it was not asked.
    DENIED_TOOLS = %w[Bash Read Write Edit MultiEdit Glob Grep WebFetch WebSearch Task Agent NotebookEdit].freeze

    # One answer about one pull request.
    #
    # @!attribute [r] number
    #   @return [Integer]
    # @!attribute [r] plan
    #   @return [Agentilda::Ordinal, nil] a plan in the tree, or nothing
    # @!attribute [r] confidence
    #   @return [Float] 0.0 when there is no verdict
    # @!attribute [r] reason
    #   @return [String]
    # @!attribute [r] dev
    #   @return [Boolean] the model's call that this is developer work
    # @!attribute [r] up
    #   @return [Integer] tokens sent
    # @!attribute [r] down
    #   @return [Integer] tokens generated
    # @!attribute [r] cost
    #   @return [Float] dollars
    # @!attribute [r] cached
    #   @return [Boolean] read from disk rather than asked
    # @!attribute [r] error
    #   @return [String, nil] why there is no verdict
    Verdict = Data.define(:number, :plan, :confidence, :reason, :dev, :up, :down, :cost, :cached, :error) do
      def initialize(plan: nil, confidence: 0.0, reason: "", dev: false, up: 0, down: 0, cost: 0.0, cached: false, error: nil, **rest) = super

      # @return [Boolean] whether the model answered in a usable shape
      def valid? = error.nil?

      # @return [Boolean]
      def dev? = dev == true

      # @return [Boolean]
      def cached? = cached

      # @return [Hash] what the cache file holds
      def to_h_for_cache
        {"plan" => plan&.to_s, "confidence" => confidence, "reason" => reason, "dev" => dev,
         "up" => up, "down" => down, "cost" => cost, "error" => error}
      end
    end

    # @param tree [Agentilda::Tree]
    # @param agent [Agentilda::Agent, nil] the judge; found by name when nil
    # @param spawn [Proc] `argv, chdir:` → {Agentilda::Child}, swappable so
    #   the suite plays back a fake process
    # @param cache_dir [String, nil] where verdicts persist; nil disables
    # @param root [String] the repository root, the child's working directory
    # @param jobs [Integer] how many `claude` processes run at once
    # @param model [String, nil] overrides the agent's frontmatter
    def initialize(tree:, agent: nil, spawn: Child.method(:spawn), cache_dir: nil, root: nil,
      jobs: UI.default_jobs, model: nil)
      @tree = tree
      @agent = agent
      @spawn = spawn
      @cache_dir = cache_dir
      @root = root || File.dirname(tree.dir)
      @jobs = jobs
      @model = model
    end

    # @return [Agentilda::Tree]
    attr_reader :tree

    # @return [String]
    attr_reader :root

    # @return [Agentilda::Agent]
    # @raise [Agentilda::Error] when no definition file carries the name
    def agent
      @agent ||= Agents.new.find(AGENT_NAME) or
        raise Error, "no agent named #{AGENT_NAME} in #{Agents::DEFAULT_DIR}"
    end

    # The model actually asked: the flag typed beats the frontmatter.
    #
    # @return [String]
    def model = @model || agent.model || "haiku"

    # Judge every pull request given, concurrently, reading the cache first.
    #
    # @param pulls [Array<Hash>] as {GitHub#pulls} returns them
    # @return [Array<Agentilda::Resolver::Verdict>] in input order
    def call(pulls)
      list = pulls.to_a
      return [] if list.empty?

      Parallel.map(list, in_threads: @jobs) { |pull| judge(pull) }
    end

    # One verdict, from the cache when it is there.
    #
    # @param pull [Hash]
    # @return [Agentilda::Resolver::Verdict]
    def judge(pull)
      cached = read_cache(pull)
      return cached if cached

      verdict = ask(pull)
      write_cache(pull, verdict) if verdict.valid?
      verdict
    end

    # The exact argv, exposed so a spec can assert it without running anything.
    #
    # @param pull [Hash]
    # @return [Array<String>]
    def invocation(pull)
      argv = ["claude", "-p", prompt_for(pull),
        "--output-format", "json", "--json-schema", JSON.generate(SCHEMA),
        "--max-turns", "1", "--disallowedTools", DENIED_TOOLS.join(","),
        "--model", model]
      argv += ["--effort", agent.effort] if agent.effort
      argv += ["--max-budget-usd", format("%.2f", agent.budget)] if agent.budget
      argv
    end

    # The judge's definition, then the index, then the pull request.
    #
    # @param pull [Hash]
    # @return [String]
    def prompt_for(pull)
      <<~PROMPT
        #{agent.prompt}

        ---

        ## The plan index

        #{plan_index}

        ---

        ## The pull request

        #{describe(pull)}
      PROMPT
    end

    # Every plan in the tree with the opening of its spec. Memoized: it is
    # the same for every pull request in a run.
    #
    # @return [String]
    def plan_index
      @plan_index ||= tree.subjects.map { |subject|
        feature = subject.feature
        excerpt = subject.read("spec.md").to_s.strip[0, SPEC_EXCERPT]
        excerpt = "_(no spec.md)_" if excerpt.empty?
        "### #{feature.ordinal} — #{feature.title}\n\nFolder: `#{feature.dirname}`\n\n#{excerpt}\n"
      }.join("\n")
    end

    # @return [String] eight hex characters that change when the index does
    def index_digest = @index_digest ||= Digest::SHA256.hexdigest(plan_index)[0, 8]

    # @param pull [Hash]
    # @return [String, nil] the cache file for this pull request
    def cache_path(pull)
      return nil unless @cache_dir

      sha = pull[:head_sha].to_s
      sha = "nosha" if sha.empty?
      File.join(@cache_dir, "#{pull[:number]}-#{sha[0, 12]}-#{index_digest}.json")
    end

    private

    # @param pull [Hash]
    # @return [String]
    def describe(pull)
      files = Array(pull[:changes])
      files = Array(pull[:files]).map { |path| {path:, additions: nil, deletions: nil} } if files.empty?
      listing = files.map { |f|
        counts = f[:additions].nil? ? "" : "  (+#{f[:additions]} −#{f[:deletions]})"
        "- `#{f[:path]}`#{counts}"
      }.join("\n")
      listing = "_(no files listed)_" if listing.empty?
      body = pull[:body].to_s.strip
      body = "_(no description was written)_" if body.empty?

      <<~TEXT
        Number : ##{pull[:number]}
        Title  : #{pull[:title]}
        Branch : #{pull[:branch]}
        State  : #{pull[:state]}

        ### Description

        #{body}

        ### Files changed

        #{listing}
      TEXT
    end

    # Run the judge once and read what it said.
    #
    # @param pull [Hash]
    # @return [Agentilda::Resolver::Verdict]
    def ask(pull)
      argv = invocation(pull)
      output = +""
      child = @spawn.call(argv, chdir: root)
      watchdog = Thread.new do
        sleep(agent.timeout || DEFAULT_TIMEOUT)
        child.kill("KILL") if child.alive?
      end
      child.each_chunk { |chunk| output << chunk }
      status = child.wait
      watchdog.kill

      parse(pull, output, status)
    rescue SystemCallError => e
      Verdict.new(number: pull[:number], error: "could not start claude: #{e.message}")
    end

    # @param pull [Hash]
    # @param output [String] everything the process wrote
    # @param status [Process::Status, nil]
    # @return [Agentilda::Resolver::Verdict]
    def parse(pull, output, status)
      text = output.to_s.strip
      if text.empty?
        return Verdict.new(number: pull[:number],
          error: "claude produced no output#{" (exit #{status.exitstatus})" if status && !status.success?} — " \
                 "usually a login a non-interactive shell cannot reach")
      end

      envelope = JSON.parse(text[text.index("{")..])
      answer = envelope["structured_output"]
      answer = JSON.parse(envelope["result"].to_s) if answer.nil? && envelope["result"].to_s.strip.start_with?("{")
      if envelope["is_error"] || answer.nil?
        return Verdict.new(number: pull[:number], **spent(envelope),
          error: "claude reported: #{envelope["result"].to_s.lines.first.to_s.strip[0, 200]}")
      end

      verdict_from(pull, answer, envelope)
    rescue JSON::ParserError, TypeError => e
      Verdict.new(number: pull[:number], error: "unreadable answer: #{e.message.lines.first.to_s.strip[0, 120]}")
    end

    # Validate the answer against the schema *and* the tree: the schema says
    # `plan` is a string, but only the tree knows whether it is a plan.
    #
    # @param pull [Hash]
    # @param answer [Hash]
    # @param envelope [Hash]
    # @return [Agentilda::Resolver::Verdict]
    def verdict_from(pull, answer, envelope)
      unless answer.is_a?(Hash) && SCHEMA["required"].all? { |k| answer.key?(k) }
        return Verdict.new(number: pull[:number], **spent(envelope), error: "answer is missing a required field")
      end

      plan = nil
      unless answer["plan"].nil?
        plan = Ordinal.parse(answer["plan"])
        unless plan && tree.include?(plan)
          return Verdict.new(number: pull[:number], **spent(envelope),
            error: "answer names #{answer["plan"]}, which is not a plan in the tree")
        end
      end

      Verdict.new(number: pull[:number], plan:,
        confidence: answer["confidence"].to_f.clamp(0.0, 1.0),
        reason: answer["reason"].to_s.strip, dev: answer["dev"] == true, **spent(envelope))
    end

    # @param envelope [Hash]
    # @return [Hash] `up:`, `down:`, `cost:`
    def spent(envelope)
      usage = envelope["usage"].is_a?(Hash) ? envelope["usage"] : {}
      up = usage.values_at("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens").sum(&:to_i)
      down = usage["output_tokens"].to_i
      cost = envelope["total_cost_usd"]
      cost = estimate(up, down) if cost.nil?
      {up:, down:, cost: cost.to_f}
    end

    # @param up [Integer]
    # @param down [Integer]
    # @return [Float]
    def estimate(up, down)
      rate = RATES.find { |name, _| model.to_s.include?(name) }&.last || RATES["haiku"]
      (up * rate[:up] + down * rate[:down]) / 1_000_000.0
    end

    # @param pull [Hash]
    # @return [Agentilda::Resolver::Verdict, nil]
    def read_cache(pull)
      path = cache_path(pull)
      return nil unless path && File.file?(path)

      data = JSON.parse(File.read(path))
      plan = data["plan"] && Ordinal.parse(data["plan"])
      return nil if data["plan"] && !(plan && tree.include?(plan))

      Verdict.new(number: pull[:number], plan:, confidence: data["confidence"].to_f,
        reason: data["reason"].to_s, dev: data["dev"] == true, up: data["up"].to_i, down: data["down"].to_i,
        cost: data["cost"].to_f, cached: true)
    rescue JSON::ParserError
      nil
    end

    # @param pull [Hash]
    # @param verdict [Agentilda::Resolver::Verdict]
    # @return [void]
    def write_cache(pull, verdict)
      path = cache_path(pull) or return

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(verdict.to_h_for_cache))
    end
  end
end
