# frozen_string_literal: true

module Agentilda
  # Where a pull request falls in the sequence of plans, by time.
  #
  # A plan has no date of its own, but the pull requests already filed under
  # it do: the span from its first merge to its last is when that plan was
  # being built. A pull request that the resolver could place only weakly —
  # "probably 003, but the spec does not really describe it" — is not filed
  # inside 003. It is filed *beside* it, as `003.01`, at the point in the
  # sequence where its own merge time says it happened. That is what the
  # decimal has always meant: a sibling in the gap, documented afterwards.
  class Timeline
    # The prefix a filed title carries.
    PREFIX = /\A\[(\d{3}(?:\.\d{2})?)\]/

    # One plan's stretch of time.
    #
    # @!attribute [r] ordinal
    #   @return [Agentilda::Ordinal]
    # @!attribute [r] from
    #   @return [Time]
    # @!attribute [r] to
    #   @return [Time]
    Span = Data.define(:ordinal, :from, :to) do
      # @param time [Time]
      # @return [Boolean]
      def cover?(time) = time.between?(from, to)

      # @return [Integer]
      def major = ordinal.major
    end

    # @param tree [Agentilda::Tree]
    # @param pulls [Array<Hash>] every pull request, with the titles they
    #   will carry — the caller substitutes proposed titles for current ones
    #   so a plan assigned in this run counts toward its own span
    def initialize(tree:, pulls:)
      @tree = tree
      @pulls = pulls
    end

    # The moment a pull request happened: when it merged, or when it was
    # opened if it has not.
    #
    # @param pull [Hash]
    # @return [Time, nil]
    def self.time_of(pull) = pull[:merged_at] || pull[:created_at]

    # Every plan with at least one timed pull request, in number order.
    #
    # @return [Array<Agentilda::Timeline::Span>]
    def spans
      @spans ||= begin
        times = Hash.new { |h, k| h[k] = [] }
        @pulls.each do |pull|
          number = pull[:title].to_s[PREFIX, 1] or next
          time = self.class.time_of(pull) or next
          ordinal = Ordinal.parse(number)
          times[ordinal] << time if ordinal && @tree.include?(ordinal)
        end
        times.map { |ordinal, list| Span.new(ordinal:, from: list.min, to: list.max) }.sort_by(&:ordinal)
      end
    end

    # The plan a pull request lands after, by time.
    #
    # Inside one or more spans: the one whose last merge is nearest. After
    # every span: the last one to end before it. Before every span: the
    # first plan, since "beside its nearest plan" is the only sensible reading
    # of a pull request older than the whole sequence.
    #
    # @param pull [Hash]
    # @return [Integer, nil] a major, or nil when nothing is dated
    def place(pull)
      time = self.class.time_of(pull) or return nil
      return nil if spans.empty?

      inside = spans.select { |span| span.cover?(time) }
      return inside.min_by { |span| (span.to - time).abs }.major unless inside.empty?

      before = spans.select { |span| span.to <= time }
      return before.max_by(&:to).major unless before.empty?

      spans.first.major
    end
  end
end
