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
    :bold) do
    def initialize(pr: nil, phase: nil, remaining: nil, frame: 0, bold: false, message: nil, **rest) = super

    # @return [Boolean]
    def running? = state == :running
  end
end
