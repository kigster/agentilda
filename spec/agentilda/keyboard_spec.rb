# frozen_string_literal: true

require "tmpdir"

RSpec.describe Agentilda::Keyboard do
  subject(:keyboard) { described_class.new(input: input) }

  let(:input) { instance_double(IO) }

  before do
    allow(Agentilda::UI).to receive(:line)
    allow(Agentilda::UI).to receive(:popup)
  end

  after { Agentilda::Control.reset! }

  # Raw mode eats input a byte at a time, which must never happen to a pipe —
  # and a run with nobody at the keys has no keys to listen for.
  it "does not listen when STDIN is not a terminal" do
    allow(input).to receive(:tty?).and_return(false)

    expect(described_class.listen(input:)).to be_nil
  end

  it "h and ? pop the bindings, which mention every key" do
    keyboard.handle("h")
    keyboard.handle("?")

    expect(Agentilda::UI).to have_received(:popup)
      .with("Keys", a_string_including("wrap up", "q", "ctrl-c")).twice
  end

  describe "with a registered agent to reach" do
    let!(:file) { Agentilda::Control.register(Dir.mktmpdir("keys"), "000.00-yoda-writer") }

    it "w asks it to wrap up, and says so" do
      keyboard.handle("w")

      expect(File.read(file).strip).to eq("WRAP_UP")
      expect(Agentilda::UI).to have_received(:line).with(a_string_including("wrap up"))
    end

    it "n asks it to write out and stop, without quitting the loop" do
      keyboard.handle("n")

      expect(File.read(file).strip).to eq("STOP")
      expect(Agentilda::Control.quit?).to be(false)
    end

    it "q stops it and quits the loop" do
      keyboard.handle("q")

      expect(File.read(file).strip).to eq("STOP")
      expect(Agentilda::Control.quit?).to be(true)
    end
  end

  # The listener must never make a run harder to kill: raw mode swallowed
  # the Ctrl-C, so the listener forwards the Interrupt it would have been.
  it "forwards Ctrl-C as the Interrupt raw mode swallowed" do
    expect { keyboard.handle("\u0003") }.to raise_error(Interrupt)
  end

  it "ignores keys that mean nothing" do
    expect { keyboard.handle("z") }.not_to raise_error
  end
end
