# frozen_string_literal: true

module Agentilda
  # What the screen draws: everything about the run, as values, refreshed
  # once a second by the dispatcher. The screen paints it and knows nothing
  # about threads; the dispatcher builds it and knows nothing about cells.
  #
  # @!attribute [r] rows
  #   @return [Array<Agentilda::Board::Row>] one per agent invocation still
  #     worth showing: running, or finished within the last few seconds
  Board = Data.define(:started_at,
    :status,
    :plans,
    :up,
    :down,
    :rows,
    :root,
    :running,
    :live_up,
    :live_down,
    :selected,
    :dialog,
    :help,
    :about,
    :hidden) do
    def initialize(selected: nil, dialog: nil, help: false, about: nil, hidden: 0, **rest) = super
  end

  # @!attribute [r] key
  #   @return [String] `"001.00/leah-researcher"`, what selection and the
  #     keyboard address a row by
  # @!attribute [r] file
  #   @return [String] the document holding the agent's latest ledger line
  # @!attribute [r] pr
  #   @return [Hash, nil] `{number:, url:, rejected:}` once the plan is at
  #     the review stage
  # @!attribute [r] state
  #   @return [Symbol] :running, :done, :failed or :stuck
  # @!attribute [r] phase
  #   @return [Symbol, nil] the clock's phase while running
  # @!attribute [r] frame
  #   @return [Integer] spinner frame counter
  # @!attribute [r] history
  #   @return [Array<String>] what the agent has said, newest first, for
  #     `run --scroll-height` to show more than the latest line of
  Board::Row = Data.define(:key,
    :at,
    :ordinal,
    :file,
    :agent,
    :role,
    :round,
    :rounds,
    :model,
    :remaining,
    :phase,
    :up,
    :down,
    :message,
    :state,
    :pr,
    :frame,
    :bold,
    :elapsed,
    :subagents,
    :history) do
    def initialize(pr: nil, phase: nil, remaining: nil, frame: 0, bold: false, message: nil,
      elapsed: 0, subagents: 0, history: [], **rest)
      super
    end

    # @param history [Array<String>] newest first
    # @param text [String, nil]
    # @return [Array<String>] +text+ on top, unless it is empty or repeats
    #   the newest line: an agent restating its activity is not news
    def self.remember(history, text)
      text = text.to_s.strip
      return history if text.empty? || history.first == text

      [text, *history].first(Board::Row::HISTORY)
    end

    # @return [Boolean]
    def running? = state == :running
  end

  # Statuses a row keeps, whatever the screen shows of them. A cap, so a
  # long-running agent's chatter cannot grow without bound. Outside the
  # `Data.define` block, whose constants would land on Agentilda instead.
  Board::Row::HISTORY = 50
end
