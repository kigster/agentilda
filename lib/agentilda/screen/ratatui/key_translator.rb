# frozen_string_literal: true

require "ratatui_ruby"

module Agentilda
  class Screen
    class Ratatui
      # RatatuiRuby::Event -> the exact string Keyboard#handle already
      # expects, so every key binding (select, kill, extend, wrap-up, quit,
      # the dialog, ctrl-c) is reused verbatim rather than reimplemented.
      module KeyTranslator
        # @param event [RatatuiRuby::Event]
        # @return [String, nil] nil for anything that is not a key press
        def self.call(event)
          return nil unless event.key?
          return "\u0003" if event.interrupt?

          case event.code
          when "up" then "\e[A"
          when "down" then "\e[B"
          when "enter" then "\r"
          when "esc" then "\e"
          else event.code
          end
        end
      end
    end
  end
end
