# frozen_string_literal: true

require "csv"

module Agentilda
  # Scoring `agentilda resync` against a project whose right answers are known.
  #
  # `example-project/` at the gem's root is a fictional product with a plan
  # tree, a folder of pull requests standing in for GitHub, and two CSV files
  # saying what the run should rename and retitle. {Run} copies it somewhere
  # disposable, runs the whole command against the copy, and reports what
  # changed in the same two shapes. {Score} compares those to the committed
  # answers, one row at a time.
  #
  # Nothing here talks to Braintrust. `evals/resync_eval.rb` does, and it is
  # a thin script over these two classes so the scoring can be exercised in
  # the suite without an API key.
  module Evals
    # The fixture shipped with the gem.
    EXAMPLE_PROJECT = File.expand_path("../../example-project", __dir__)

    # What the run reported spending, parsed from its own summary line.
    SPEND = /([\d,]+)\s+tokens\s+in\D+?([\d,]+)\s+out\D+?\$([\d.]+)/m

    # A captured stream. TTY::Screen asks the streams for the terminal width
    # with `ioctl` and rescues only SystemCallError, so a bare StringIO raises
    # NoMethodError from inside the box drawing instead of falling back.
    class Captured < StringIO
      def ioctl(*) = raise(Errno::ENOTTY)
    end

    # Run the command against a disposable copy of a project and say what moved.
    class Run
      # @!attribute [r] plans
      #   @return [Array<Hash>] `{"before" => name, "after" => name}` per folder
      #     that was renamed; a minted folder has an empty `before`
      # @!attribute [r] prs
      #   @return [Array<Hash>] `{"number" =>, "before" =>, "after" =>}` per
      #     retitled pull request
      # @!attribute [r] spent
      #   @return [Hash] `up:`, `down:`, `cost:` as the run reported them
      # @!attribute [r] log
      #   @return [String] everything the run printed
      Outcome = Data.define(:plans, :prs, :spent, :log) do
        # @return [Hash] the shape an experiment logs
        def to_h = {plans:, prs:, spent:}
      end

      # @param source [String] the project to copy; the shipped fixture by default
      # @param force [Boolean] pass `--force`
      # @param cache [Boolean] reuse cached verdicts; off by default so an
      #   experiment measures the model, not the disk
      # @param model [String, nil] override the judge's model
      # @param runner [Proc, nil] `(options) → nil`, the command to run; the
      #   real one in-process by default, swappable so the suite can stub it
      def initialize(source: EXAMPLE_PROJECT, force: false, cache: false, model: nil, runner: nil)
        @source = File.expand_path(source)
        @force = force
        @cache = cache
        @model = model
        @runner = runner || method(:resync)
      end

      # @return [Agentilda::Evals::Run::Outcome]
      def call
        Dir.mktmpdir("agentilda-eval") do |tmp|
          root = File.join(tmp, File.basename(@source))
          FileUtils.cp_r(@source, root)
          plans_dir = File.join(root, Agentilda::PLANS_DIR)
          prs_dir = File.join(root, ".prs")

          folders_before = folders(plans_dir)
          titles_before = titles(prs_dir)
          log = capture { @runner.call(dir: plans_dir, fake_github_path: prs_dir, commit: true, force: @force, cache: @cache, model: @model) }

          Outcome.new(plans: plan_rows(folders_before, folders(plans_dir)),
            prs: pr_rows(titles_before, titles(prs_dir)), spent: spent(log), log:)
        end
      end

      private

      # The real thing, in this process.
      #
      # @param options [Hash]
      # @return [void]
      def resync(**options)
        CLI::Resync::All.new.call(**options.compact)
      end

      # @return [String] everything printed while the block ran
      def capture
        out = Captured.new
        original_out, original_err, quiet = $stdout, $stderr, UI.quiet
        $stdout = $stderr = out
        UI.quiet = false
        yield
        out.string
      ensure
        $stdout, $stderr = original_out, original_err
        UI.quiet = quiet
      end

      # @param dir [String]
      # @return [Hash{String => String}] slug => folder name
      def folders(dir)
        Dir.children(dir).select { |c| File.directory?(File.join(dir, c)) }
          .filter_map { |c| Feature.parse(File.join(dir, c))&.then { |f| [f.slug, c] } }.to_h
      end

      # @param dir [String]
      # @return [Hash{Integer => String}] number => title
      def titles(dir)
        FakeGitHub.new(dir:).pulls.to_h { |pr| [pr[:number], pr[:title]] }
      end

      # @param before [Hash{String => String}]
      # @param after [Hash{String => String}]
      # @return [Array<Hash>]
      def plan_rows(before, after)
        (before.keys | after.keys).sort.filter_map do |slug|
          was, now = before[slug].to_s, after[slug].to_s
          {"before" => was, "after" => now} unless was == now
        end
      end

      # @param before [Hash{Integer => String}]
      # @param after [Hash{Integer => String}]
      # @return [Array<Hash>]
      def pr_rows(before, after)
        before.keys.sort.filter_map do |number|
          was, now = before[number], after.fetch(number, "")
          {"number" => number.to_s, "before" => was, "after" => now} unless was == now
        end
      end

      # @param log [String]
      # @return [Hash]
      def spent(log)
        match = SPEND.match(log) or return {up: 0, down: 0, cost: 0.0}
        {up: match[1].delete(",").to_i, down: match[2].delete(",").to_i, cost: match[3].to_f}
      end
    end

    # Rows the run produced against rows the fixture expects.
    #
    # Keyed on `before` for folders and `number` for pull requests. An
    # expected row whose `after` matches is a hit. An expected row that
    # differs or is missing, and an actual row nobody expected, are each one
    # discrepancy. The score is the share of hits, so all right is 100 and
    # all wrong is 0.
    class Score
      # @!attribute [r] hits
      #   @return [Integer]
      # @!attribute [r] wrong
      #   @return [Array<Hash>] expected rows whose `after` differs
      # @!attribute [r] missing
      #   @return [Array<Hash>] expected rows the run did not produce
      # @!attribute [r] unexpected
      #   @return [Array<Hash>] actual rows the fixture does not expect
      Result = Data.define(:hits, :wrong, :missing, :unexpected) do
        # @return [Integer]
        def discrepancies = wrong.size + missing.size + unexpected.size

        # @return [Float] 0 to 100
        def score
          total = hits + discrepancies
          total.zero? ? 100.0 : (100.0 * hits / total).round(2)
        end

        # @return [Array<String>] one line per discrepancy, for a report
        def lines
          wrong.map { |r| "wrong      #{r["key"]}: expected #{r["expected"].inspect}, got #{r["actual"].inspect}" } +
            missing.map { |r| "missing    #{r["key"]}: expected #{r["expected"].inspect}" } +
            unexpected.map { |r| "unexpected #{r["key"]}: got #{r["actual"].inspect}" }
        end
      end

      # @param path [String] a CSV with a header row
      # @return [Array<Hash>]
      def self.read(path)
        CSV.read(path, headers: true).map(&:to_h)
      end

      # @param expected [Array<Hash>]
      # @param actual [Array<Hash>]
      # @param key [String] the column rows are matched on
      def initialize(expected:, actual:, key:)
        @expected = expected
        @actual = actual
        @key = key
      end

      # @return [Agentilda::Evals::Score::Result]
      def call
        want = @expected.to_h { |r| [r[@key].to_s, r["after"].to_s] }
        got = @actual.to_h { |r| [r[@key].to_s, r["after"].to_s] }

        hits = 0
        wrong = []
        missing = []
        want.each do |key, after|
          if !got.key?(key)
            missing << {"key" => key, "expected" => after}
          elsif got[key] == after
            hits += 1
          else
            wrong << {"key" => key, "expected" => after, "actual" => got[key]}
          end
        end
        unexpected = (got.keys - want.keys).map { |key| {"key" => key, "actual" => got[key]} }

        Result.new(hits:, wrong:, missing:, unexpected:)
      end
    end
  end
end
