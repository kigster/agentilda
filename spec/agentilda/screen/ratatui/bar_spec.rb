# frozen_string_literal: true

require "ratatui_ruby"

RSpec.describe Agentilda::Screen::Ratatui::Bar do
  let(:tui) { RatatuiRuby::TUI.new }

  describe ".cell" do
    it "fills proportionally to the 30-minute cap and appends the clock" do
      line = described_class.cell(tui, 900, :green) # 15 of 30 minutes = half full
      bar, clock = line.spans
      expect(bar.content).to eq(("▓" * 5) + ("░" * 5))
      expect(bar.style.fg).to eq(:green)
      expect(clock.content).to eq(" 15:00")
    end

    it "draws an empty, dim bar with no clock when there is no duration" do
      line = described_class.cell(tui, nil, :green)
      bar, clock = line.spans
      expect(bar.content).to eq(" " * 10)
      expect(clock.content).to eq(" --:--")
      expect(bar.style.fg).to eq(:bright_black)
    end

    it "never exceeds a full bar past the 30-minute cap" do
      line = described_class.cell(tui, 5000, :red)
      bar, = line.spans
      expect(bar.content).to eq("▓" * 10)
    end
  end

  describe ".elapsed_color" do
    it "is green under 15 minutes" do
      expect(described_class.elapsed_color(899)).to eq(:green)
    end

    it "is yellow at 15 minutes and over" do
      expect(described_class.elapsed_color(900)).to eq(:yellow)
    end
  end

  describe ".remaining_color" do
    it "is red under 5 minutes" do
      expect(described_class.remaining_color(299)).to eq(:red)
    end

    it "is yellow under 15 minutes" do
      expect(described_class.remaining_color(899)).to eq(:yellow)
    end

    it "is green at 15 minutes and over" do
      expect(described_class.remaining_color(900)).to eq(:green)
    end

    it "is dim with no timeout" do
      expect(described_class.remaining_color(nil)).to eq(:bright_black)
    end
  end
end
