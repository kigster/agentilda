# frozen_string_literal: true

module Agentilda
  module Live
    # What each plan has spent this run, kept across the board's rows.
    #
    # A row leaves the board ten seconds after its agent finishes, and what it
    # spent must not leave the plan's total with it. So every row seen is
    # remembered by plan, agent and round, at the highest figures it showed.
    class Meter
      # One agent's round on one plan, at its latest reading.
      Spend = Data.define(:up, :down, :model)

      def initialize
        @spends = Hash.new { |h, k| h[k] = {} }
        @first_seen = {}
      end

      # @param rows [Array<Agentilda::Engine::Board::Row>]
      # @param now [Time]
      # @return [void]
      def record(rows, now: Time.now)
        rows.each do |row|
          @first_seen[row.ordinal] ||= now
          known = @spends[row.ordinal][[row.agent, row.round]]
          @spends[row.ordinal][[row.agent, row.round]] =
            Spend.new(up: [row.up.to_i, known&.up.to_i].max, down: [row.down.to_i, known&.down.to_i].max, model: row.model)
        end
      end

      # @param ordinal [String]
      # @return [Time, nil] when this run first saw an agent on the plan
      def started_at(ordinal) = @first_seen[ordinal]

      # @param ordinal [String]
      # @param price [#call] model name to an {Adapters::Model}, or nil
      # @return [Hash{Symbol => Numeric}] `up`, `down` and `cost`
      def for(ordinal, price)
        spends = @spends.fetch(ordinal, {}).values
        { up:   spends.sum(&:up),
          down: spends.sum(&:down),
          cost: spends.sum { |s| price.call(s.model)&.cost(s.up, s.down).to_f }.round(4) }
      end
    end
  end
end
