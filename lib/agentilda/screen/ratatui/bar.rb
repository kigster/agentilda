# frozen_string_literal: true

require "ratatui_ruby"

module Agentilda
  module Screen
    class Ratatui
      module Bar
        # Cells the fill portion occupies.
        WIDTH = 10

        # Seconds a bar visually maxes out at. Cosmetic only — the color
        # thresholds below are independent, absolute-minute rules.
        CAP = 1800

        # @param tui [RatatuiRuby::TUI]
        # @param seconds [Integer, nil] nil draws an empty, dim bar
        # @param color [Symbol] the fill's foreground color
        # @return [RatatuiRuby::Text::Line]
        def self.cell(tui, seconds, color)
          return empty(tui) if seconds.nil?

          filled = ((seconds.to_f / CAP).clamp(0.0, 1.0) * WIDTH).round
          bar = ("▓" * filled) + ("░" * (WIDTH - filled))
          clock = format(" %2d:%02d", seconds / 60, seconds % 60)
          tui.text_line(spans: [
                          tui.text_span(content: bar, style: tui.style(fg: color)),
                          tui.text_span(content: clock, style: tui.style(fg: :bright_black))
                        ])
        end

        # @param tui [RatatuiRuby::TUI]
        # @return [RatatuiRuby::Text::Line]
        def self.empty(tui)
          tui.text_line(spans: [
                          tui.text_span(content: " " * WIDTH, style: tui.style(fg: :bright_black)),
                          tui.text_span(content: " --:--", style: tui.style(fg: :bright_black))
                        ])
        end

        # @param elapsed [Integer]
        # @return [Symbol]
        def self.elapsed_color(elapsed) = elapsed >= 900 ? :yellow : :green

        # @param remaining [Integer, nil]
        # @return [Symbol]
        def self.remaining_color(remaining)
          return :bright_black if remaining.nil?
          return :red if remaining < 300
          return :yellow if remaining < 900

          :green
        end
      end
    end
  end
end
