# frozen_string_literal: true

require "ratatui_ruby"

RSpec.describe Agentilda::Screen::Ratatui::KeyTranslator do
  def key(code, modifiers: [])
    RatatuiRuby::Event::Key.new(code:, modifiers:)
  end

  it "passes plain character keys through unchanged" do
    %w[h ? s k x w n q].each do |char|
      expect(described_class.call(key(char))).to eq(char)
    end
  end

  it "maps arrow keys to the escape sequences Keyboard#handle expects" do
    expect(described_class.call(key("up"))).to eq("\e[A")
    expect(described_class.call(key("down"))).to eq("\e[B")
  end

  it "maps enter and esc" do
    expect(described_class.call(key("enter"))).to eq("\r")
    expect(described_class.call(key("esc"))).to eq("\e")
  end

  it "maps Ctrl+C to ETX, ahead of the plain-character case" do
    expect(described_class.call(key("c", modifiers: ["ctrl"]))).to eq("\u0003")
  end

  it "ignores non-key events" do
    expect(described_class.call(RatatuiRuby::Event::Resize.new(width: 80, height: 24))).to be_nil
  end
end
