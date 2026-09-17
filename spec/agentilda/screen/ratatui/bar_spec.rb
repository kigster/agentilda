# frozen_string_literal: true

require "ratatui_ruby"

RSpec.describe Agentilda::Screen::Ratatui::Bar do
  let(:tui) { RatatuiRuby::TUI.new }

  describe ".cell" do
    subject(:line) { described_class.cell(tui, duration, color) }

    let(:color) { :green }
    let(:bar) { line.spans.first }
    let(:clock) { line.spans.last }

    context "when 15 of 30 minutes have passed" do
      let(:duration) { 900 }

      it "fills proportionally to the 30-minute cap" do
        expect(bar.content).to eq(("▓" * 5) + ("░" * 5))
      end

      it("colors the bar") { expect(bar.style.fg).to eq(:green) }
      it("appends the clock") { expect(clock.content).to eq(" 15:00") }
    end

    context "when there is no duration" do
      let(:duration) { nil }

      it("draws an empty bar") { expect(bar.content).to eq(" " * 10) }
      it("draws it dim") { expect(bar.style.fg).to eq(:bright_black) }
      it("shows no clock") { expect(clock.content).to eq(" --:--") }
    end

    context "when past the 30-minute cap" do
      let(:duration) { 5000 }
      let(:color) { :red }

      it("never exceeds a full bar") { expect(bar.content).to eq("▓" * 10) }
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
