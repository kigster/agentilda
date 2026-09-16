# frozen_string_literal: true

require "tmpdir"

RSpec.describe Agentilda::Control do
  around do |example|
    Dir.mktmpdir("control") do |dir|
      @dir = dir
      example.run
    end
  ensure
    described_class.reset!
  end

  it "hands each invocation an empty file of its own" do
    path = described_class.register(@dir, "000.00-yoda-writer")

    expect(File.read(path)).to eq("")
    expect(File.basename(path)).to include("control-000.00-yoda-writer")
  end

  it "wrap_up! reaches every registered file" do
    one = described_class.register(@dir, "a")
    two = described_class.register(@dir, "b")
    described_class.wrap_up!

    expect(File.read(one).strip).to eq("WRAP_UP")
    expect(File.read(two).strip).to eq("WRAP_UP")
  end

  it "stop! asks agents to write out, without quitting the loop" do
    path = described_class.register(@dir, "a")
    described_class.stop!

    expect(File.read(path).strip).to eq("STOP")
    expect(described_class.quit?).to be(false)
  end

  it "quit! stops the agents and the loop both" do
    path = described_class.register(@dir, "a")
    described_class.quit!

    expect(File.read(path).strip).to eq("STOP")
    expect(described_class.quit?).to be(true)
  end

  it "interrupt! asks for a resume note and quits the loop, on the same deadline as quit!" do
    path = described_class.register(@dir, "a")
    described_class.interrupt!

    expect(File.read(path).strip).to eq("INTERRUPT")
    expect(described_class).to be_quit
    expect(described_class).to be_interrupted
    allow(Agentilda::UI).to receive(:monotonic).and_return(Agentilda::UI.monotonic + described_class::GRACE + 1)
    expect(described_class).to be_overdue
  end

  it "reset! forgets an interrupt" do
    described_class.interrupt!
    described_class.reset!
    expect(described_class).not_to be_interrupted
  end

  describe ".on_interrupt" do
    it "turns the first SIGINT into interrupt! and the second into an Interrupt" do
      raised = nil
      described_class.on_interrupt do
        Process.kill("INT", Process.pid)
        sleep 0.05 until described_class.interrupted?
        begin
          Process.kill("INT", Process.pid)
          sleep 1
        rescue Interrupt
          raised = true
        end
      end

      expect(raised).to be(true)
    end

    it "puts the previous handler back" do
      previous = Signal.trap("INT") { nil }
      described_class.on_interrupt { :ok }
      expect(Signal.trap("INT", previous)).to be_a(Proc)
    end
  end

  # The deadline is what turns "please stop" into "stopped": inside the
  # grace period nothing is overdue, past it everything is.
  it "is overdue only once the grace period after quit! has passed" do
    described_class.quit!
    expect(described_class.overdue?).to be(false)

    allow(Agentilda::UI).to receive(:monotonic)
      .and_return(Agentilda::UI.monotonic + described_class::GRACE + 1)

    expect(described_class.overdue?).to be(true)
  end

  it "a released file is deleted and no longer written to" do
    path = described_class.register(@dir, "a")
    described_class.release(path)
    described_class.stop!

    expect(File.exist?(path)).to be(false)
  end

  it "reset! returns everything to rest" do
    path = described_class.register(@dir, "a")
    described_class.quit!
    described_class.reset!

    expect(described_class.quit?).to be(false)
    expect(described_class.overdue?).to be(false)
    expect(File.exist?(path)).to be(false)
  end
end
