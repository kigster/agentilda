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

  it "h pops the bindings when there is no console, and they mention every key" do
    keyboard.handle("h")

    expect(Agentilda::UI).to have_received(:popup)
      .with("Keys", a_string_including("wrap up", "q", "ctrl-c"))
  end

  it "? pops the version and a reminder of how to quit, when there is no console" do
    keyboard.handle("?")

    expect(Agentilda::UI).to have_received(:popup)
      .with("About", a_string_including(Agentilda::VERSION, "q", "stop all agents"))
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

  describe "the console keys" do
    let(:sink) { instance_double(Agentilda::Console, select_next: nil, select_prev: nil, toggle_kill: nil, extend: nil, apply: nil, escape: nil, toggle_help: nil) }
    let(:keyboard) { described_class.new(input: StringIO.new, sink:) }

    it "routes s, the arrows, k, x, ENTER and ESC to the console" do
      %w[s k x].zip(%i[select_next toggle_kill extend]).each { |key, method|
        keyboard.handle(key)
        expect(sink).to have_received(method)
      }
      keyboard.handle("\e[A")
      keyboard.handle("\e[B")
      keyboard.handle("\r")
      keyboard.handle("\e")
      aggregate_failures do
        expect(sink).to have_received(:select_prev)
        expect(sink).to have_received(:select_next).twice
        expect(sink).to have_received(:apply)
        expect(sink).to have_received(:escape)
      end
    end

    it "h shows the help through the console when there is one" do
      keyboard.handle("h")
      expect(sink).to have_received(:toggle_help)
    end

    it "lists every key in the help" do
      expect(described_class.new(input: StringIO.new).help).to include("s", "k", "x", "ENTER", "ESC")
    end
  end
end
