# frozen_string_literal: true

module Agentilda
  module Plans
    # What the author of `spec.md` asked of the harness, in its frontmatter:
    #
    #   ---
    #   lane: quick              # full (default) | plan | quick
    #   frontend: false          # true forces rey-frontend, false forbids it
    #   depth: fast              # fast | medium | deep
    #   phases:
    #     build:  { adapter: codex, model: gpt-5-codex, effort: medium }
    #     review: { model: opus }
    #   ---
    #
    # The body is the specification; this is how it should be worked. A value
    # this does not recognise is ignored and named in {#problems}, rather than
    # stopping the run: a typo in `lane:` should cost the author their lane,
    # not their plan.
    #
    # @!attribute [r] lane
    #   @return [Symbol] :full, :plan or :quick
    # @!attribute [r] frontend
    #   @return [Boolean, nil] nil when the plan decides
    # @!attribute [r] depth
    #   @return [Symbol, nil] :fast, :medium or :deep
    # @!attribute [r] phases
    #   @return [Hash{String => Hash{String => String}}] per-phase
    #     `adapter`, `model` and `effort`
    # @!attribute [r] problems
    #   @return [Array<String>] what was ignored, and why
    Spec = Data.define(:lane, :frontend, :depth, :phases, :problems) do
      def initialize(lane: :full, frontend: nil, depth: nil, phases: {}, problems: []) = super

      # @param phase [String, Symbol, nil]
      # @return [Hash{String => String}] what the author set for that phase
      def override_for(phase) = phases.fetch(phase.to_s, {})

      # @return [Boolean]
      def default? = self == Spec.new
    end

    class Spec
      # Every route a plan can take through the agents.
      #   full  — research, specification, planning, build, review
      #   plan  — the spec is already what the author wants: plan, build, review
      #   quick — a short mechanical task: one agent builds it, then review
      LANES = %i[full plan quick].freeze

      # How much each phase should think, and what an eval holds it to.
      DEPTHS = %i[fast medium deep].freeze

      # What a depth means as an effort, when nothing more specific is set.
      EFFORT_FOR_DEPTH = { fast: "low", medium: "medium", deep: "high" }.freeze

      # The keys a `phases:` entry may set.
      PHASE_KEYS = %w[adapter model effort].freeze

      FILENAME = "spec.md"

      class << self
        # @param subject [#read]
        # @return [Agentilda::Plans::Spec]
        def for(subject) = parse(subject.read(FILENAME).to_s)

        # @param dir [String] a plan folder
        # @return [Agentilda::Plans::Spec]
        def load(dir)
          path = File.join(dir, FILENAME)
          File.file?(path) ? parse(File.read(path, encoding: "UTF-8")) : new
        end

        # @param text [String] a whole spec.md
        # @return [Agentilda::Plans::Spec]
        def parse(text)
          meta, = Frontmatter.split(text)
          from(meta)
        rescue Psych::Exception => e
          new(problems: ["spec.md frontmatter is not valid YAML (#{e.message.lines.first.strip})"])
        end

        # @param meta [Hash]
        # @return [Agentilda::Plans::Spec]
        def from(meta)
          problems = []
          new(lane:     choice(meta, "lane", LANES, :full, problems),
            frontend: switch(meta, "frontend", problems),
            depth:    choice(meta, "depth", DEPTHS, nil, problems),
            phases:   phases(meta["phases"], problems),
            problems:)
        end

        private

        # @return [Symbol, nil]
        def choice(meta, key, allowed, default, problems)
          return default unless meta.key?(key)

          value = meta[key].to_s.strip.downcase.to_sym
          return value if allowed.include?(value)

          problems << "#{key}: #{meta[key].inspect} is not one of #{allowed.join(", ")}"
          default
        end

        # @return [Boolean, nil]
        def switch(meta, key, problems)
          return nil unless meta.key?(key)
          return meta[key] if [true, false].include?(meta[key])

          problems << "#{key}: #{meta[key].inspect} is not true or false"
          nil
        end

        # @return [Hash]
        def phases(value, problems)
          return {} if value.nil?

          unless value.is_a?(Hash)
            problems << "phases: must be a mapping of phase to adapter, model and effort"
            return {}
          end

          value.each_with_object({}) do |(phase, settings), out|
            next problems << "phases.#{phase}: must be a mapping" unless settings.is_a?(Hash)

            kept = settings.transform_keys(&:to_s).slice(*PHASE_KEYS).transform_values(&:to_s)
            (settings.keys.map(&:to_s) - PHASE_KEYS).each { |k| problems << "phases.#{phase}.#{k}: unknown key" }
            if kept.key?("effort") && !Adapters.effort?(kept["effort"])
              problems << "phases.#{phase}.effort: #{kept["effort"].inspect} is not one of #{Adapters::EFFORTS.join(", ")}"
              kept.delete("effort")
            end
            if kept.key?("adapter") && !Adapters.known?(kept["adapter"])
              problems << "phases.#{phase}.adapter: #{kept["adapter"].inspect} is not one of #{Adapters.names.join(", ")}"
              kept.delete("adapter")
            end
            out[phase.to_s] = kept
          end
        end
      end
    end
  end
end
