# frozen_string_literal: true

# `tilda run`'s API server, as a process of its own. Spawned for real, but
# the executable is replaced by a tiny script so the suite starts no Puma.
RSpec.describe Agentilda::Web::Launcher do
  subject(:launcher) do
    described_class.new(root: dir,
      plans_dir: File.join(dir, ".plans"),
      port:,
      redis_url: "redis://localhost:6379/9",
      log: File.join(dir, "web.log"),
      ready_within: 2,
      probe: -> { healthy })
  end

  let(:dir) { Dir.mktmpdir("launcher") }
  let(:port) { 4999 }
  let(:script) { File.join(dir, "fake-web") }
  let(:healthy) { true }

  before do
    File.write(script, "#!/bin/sh\necho \"$@\"\necho \"redis: $AGENTILDA_REDIS_URL\"\ntrap 'exit 0' TERM\nwhile true; do sleep 0.05; done\n")
    File.chmod(0o755, script)
    stub_const("#{described_class}::EXE", script)
  end

  after do
    launcher.stop
    FileUtils.rm_rf(dir)
  end

  it "spawns `agentilda web` for this run's port and plans, never opening a browser" do
    expect(launcher.argv).to eq([script, "web", "--port", "4999", "--no-open", "--dir", File.join(dir, ".plans")])
  end

  it "keeps the Redis URL, and any password in it, off the command line" do
    expect(launcher.argv.join(" ")).not_to include("redis://")
  end

  it "hands the Redis URL to the server through its environment" do
    expect(launcher.env).to eq("AGENTILDA_REDIS_URL" => "redis://localhost:6379/9")
  end

  it "points at loopback" do
    expect(launcher.url).to eq("http://127.0.0.1:4999")
  end

  context "when the server answers /healthz" do
    # The fake server's two lines, once both are written: a fixed sleep lost
    # that race on a loaded machine.
    let(:output) do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.02 until File.read(launcher.log).include?("redis:") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      File.read(launcher.log)
    end

    before { launcher.start }

    it "is ready, and logs the server's output" do
      expect([launcher.ready?, output]).to match([true, /\Aweb --port 4999/])
    end

    it "starts the server with the Redis URL in its environment" do
      expect(output).to include("redis: redis://localhost:6379/9")
    end

    it "is serving while the server lives" do
      expect([launcher.serving?, launcher.joined?]).to eq([true, false])
    end

    it "is not serving once the server has gone" do
      Process.kill("TERM", -launcher.pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.02 while launcher.serving? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(launcher.serving?).to be(false)
    end

    it "stops its process group" do
      pid = launcher.pid
      launcher.stop
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end
  end

  context "when it never answers" do
    let(:healthy) { false }

    before do
      stub_const("#{described_class}::STOP_WITHIN", 0.2)
      File.write(script, "#!/bin/sh\ntrap '' TERM\nwhile true; do sleep 0.05; done\n")
      launcher.start
    end

    it "is not ready, and is killed when TERM is ignored" do
      launcher.stop
      expect([launcher.ready?, launcher.pid]).to eq([false, nil])
    end

    describe "after KILL" do
      let(:pid) { launcher.pid }

      before do
        allow(Process).to receive(:waitpid).and_call_original
        pid
        launcher.stop
      end

      it "reaps the server, leaving no zombie behind" do
        expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
      end

      it "waits for the reap rather than polling once" do
        expect(Process).to have_received(:waitpid).with(pid).once
      end
    end
  end

  context "when it dies at once" do
    let(:healthy) { false }

    before do
      File.write(script, "#!/bin/sh\nexit 3\n")
      launcher.start
    end

    it "gives up without waiting out the deadline" do
      expect(launcher.ready?).to be(false)
    end
  end

  # `tilda web` typed first, then `tilda run`: the run joins that server
  # rather than spawning one that dies on a taken port.
  context "when a server already listens on the port" do
    subject(:launcher) do
      described_class.new(root: dir,
        plans_dir: File.join(dir, ".plans"),
        port:,
        redis_url: "redis://localhost:6379/9",
        log: File.join(dir, "web.log"),
        probe: -> { answers.first })
    end

    let(:listener) { TCPServer.new(Agentilda::Web::HOST, 0) }
    let(:port) { listener.addr[1] }
    let(:answers) { [true] }

    before do
      stub_const("#{described_class}::PROBE_EVERY", 0)
      launcher.start
    end

    after { listener.close }

    it "joins it, spawning nothing" do
      expect([launcher.joined?, launcher.ready?, launcher.pid]).to eq([true, true, nil])
    end

    it "never stops it" do
      launcher.stop
      expect(listener.closed?).to be(false)
    end

    it "is serving while it answers, and not once it stops" do
      first = launcher.serving?
      answers.replace([false])
      expect([first, launcher.serving?]).to eq([true, false])
    end
  end

  describe "#healthy?, against nothing listening" do
    subject(:probe) { described_class.new(root: dir, plans_dir: dir, port: 1, redis_url: "x") }

    it "is false" do
      expect(probe.send(:healthy?)).to be(false)
    end
  end

  it "keeps its log in the temp dir by default" do
    expect(described_class.new(root: "/work/widgets", plans_dir: "/p", port: 1, redis_url: "x").log)
      .to eq(File.join(Dir.tmpdir, "agentilda-web-widgets.log"))
  end
end
