# frozen_string_literal: true

require "ratatui_ruby"

RSpec.describe Agentilda::Screen::Ratatui::KeyTranslator do
  subject { described_class.call(event) }

  def key(code, modifiers: [])
    RatatuiRuby::Event::Key.new(code:, modifiers:)
  end

  describe "plain character keys pass through unchanged" do
    %w[h ? s k x w n q].each do |char|
      context "with #{char.inspect}" do
        let(:event) { key(char) }

        it { is_expected.to eq(char) }
      end
    end
  end

  describe "arrow keys map to the escape sequences Keyboard#handle expects" do
    context "with up" do
      let(:event) { key("up") }

      it { is_expected.to eq("\e[A") }
    end

    context "with down" do
      let(:event) { key("down") }

      it { is_expected.to eq("\e[B") }
    end
  end

  describe "enter and esc" do
    context "with enter" do
      let(:event) { key("enter") }

      it { is_expected.to eq("\r") }
    end

    context "with esc" do
      let(:event) { key("esc") }

      it { is_expected.to eq("\e") }
    end
  end

  context "with Ctrl+C, ahead of the plain-character case" do
    let(:event) { key("c", modifiers: ["ctrl"]) }

    it("maps to ETX") { is_expected.to eq("") }
  end

  context "with a non-key event" do
    let(:event) { RatatuiRuby::Event::Resize.new(width: 80, height: 24) }

    it("is ignored") { is_expected.to be_nil }
  end
end
