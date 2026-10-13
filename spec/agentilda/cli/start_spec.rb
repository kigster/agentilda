# frozen_string_literal: true

# `agentilda start` is `run` that stays: the same options and code, the
# control room required rather than hoped for, and an end that comes from
# Stop All, a signal or the page going away, never from a fixed point.
#
# Like run_spec, every example runs `--isolation shared` over a bare temp
# tree, publishes to a store in this process, and never spawns the server,
# a browser or an agent.
RSpec.describe Agentilda::CLI::Start, :tree do
  subject(:command) { described_class.new }

  let(:live_store) { Agentilda::Live.memory_store }
  let(:web) do
    instance_double(Agentilda::Web::Launcher,
      ready?:   true,
      url:      "http://127.0.0.1:4747",
      log:      "/tmp/web.log",
      stop:     nil,
      joined?:  false,
      serving?: true)
  end
  let(:executor) { instance_double(Agentilda::Execution::Executor) }

  # Between ticks, instead of sleeping a second. The default stops the run
  # the way a service manager does, with SIGTERM, once it has idled a while.
  let(:sleeper) do
    ticks = 0
    lambda { |_|
      ticks += 1
      Process.kill("TERM", Process.pid) if ticks == 3
      Agentilda::Execution::Control.quit! if ticks > 5_000
      Thread.pass
    }
  end

  before do
    allow(Agentilda::Engine::Runner).to receive(:new).and_wrap_original do |original, **keywords|
      original.call(**keywords, sleeper:)
    end
    allow(Agentilda::Live).to receive(:connect).and_return(live_store)
    allow(web).to receive(:start).and_return(web)
    allow(Agentilda::Web).to receive(:launcher).and_return(web)
    allow(Agentilda::Web).to receive(:open)
    allow(Agentilda::Execution::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:call)
  end

  after { Agentilda::Execution::Control.reset! }

  def start(**)
    out = CapturedStream.new
    err = CapturedStream.new
    status = nil
    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      command.call(dir: plans_root, isolation: "shared", log: File.join(plans_root, "..", "progress.log"), **)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end
    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def asked
    plans do |t|
      t.plan "002.00", :blocked, "minesweeper", files: { "spec.md" => spec_body, "blocked.md" => "## B1 Board size\n\nHow big?\n" }
    end
  end

  def parse(*argv) = Dry::CLI::Parser.call(described_class, argv, "tilda start")

  describe "its options" do
    it "takes run's, and --rescan" do
      expect(parse("-j", "4", "--port", "4848", "--no-open", "--rescan", "2").arguments)
        .to include(jobs: "4", port: "4848", open: false, rescan: "2")
    end

    it "leaves out --dry-run, which would publish no board" do
      expect(parse("--dry-run").error?).to be(true)
    end

    it "leaves out --no-web, since the page is the only way in" do
      expect(parse("--no-web").error?).to be(true)
    end

    it "is listed with the agents in help" do
      expect(Agentilda::CLI.get(["start"]).command).to eq(described_class)
    end
  end

  describe "a plan blocked on a question" do
    before { asked }

    let!(:result) { start(open: false) }

    it "stays up past the fixed point until SIGTERM, then exits 0" do
      expect([result.last, result[1]]).to match([0, include("Stopped.", "Still waiting for answers: 002.00")])
    end

    it "idles rather than ends, and says on the terminal why" do
      expect(result[1]).to include("idle: waiting for answers on 002.00")
    end

    it "runs the engine in stay mode, rescanning every five seconds" do
      expect(Agentilda::Engine::Runner).to have_received(:new).with(hash_including(stay: true, rescan: 5))
    end

    it "stops the control room" do
      expect(web).to have_received(:stop)
    end

    it "puts SIGTERM back the way it found it" do
      expect(Signal.trap("TERM", "DEFAULT")).to eq("DEFAULT")
    end
  end

  describe "every plan finished" do
    before do
      plans { |t| t.plan "001.00", :deployed, "shipped", files: { "spec.md" => spec_body, "deployed.md" => "v1\n" } }
    end

    let!(:result) { start }

    it "stays up, waiting for the next idea, until SIGTERM" do
      expect([result.last, result[1]]).to match([0, include("idle: every plan is finished", "Stopped.")])
    end

    it "opens the control room on the idea dialog" do
      expect(Agentilda::Web).to have_received(:open).with("http://127.0.0.1:4747#start")
    end
  end

  describe "with no plans at all" do
    let!(:result) { start }

    it "stays up for the first plan from the page" do
      expect([result.last, result[1]]).to match([0, include("idle: no plans yet", "Stopped.")])
    end

    it "opens the control room on the idea dialog" do
      expect(Agentilda::Web).to have_received(:open).with("http://127.0.0.1:4747#start")
    end
  end

  describe "without a .plans directory" do
    let(:missing) { File.join(Dir.mktmpdir("start"), ".plans") }
    let!(:result) { start(dir: missing) }

    after { FileUtils.rm_rf(File.dirname(missing)) }

    it "makes one and stays up for the first plan" do
      expect([Dir.exist?(missing), result.last, unwrapped(result[1])]).to match([true, 0, include("no plans yet, so the control room opens on New idea")])
    end
  end

  describe "a .plans directory named in .tilda.yml" do
    let(:project) { Dir.mktmpdir("start") }
    let(:named) { File.join(project, "work", "plans") }
    let!(:result) do
      File.write(File.join(project, ".tilda.yml"), "commands:\n  start:\n    dir: work/plans\n")
      Dir.chdir(project) do
        typed = Dry::CLI::Parser.call(described_class, [], "tilda start").arguments
        start(**typed.except(:isolation, :log), dir: typed.fetch(:dir))
      end
    end

    after { FileUtils.rm_rf(project) }

    it "is made where the file says" do
      expect([Dir.exist?(named), result.last]).to eq([true, 0])
    end
  end

  describe "when the control room goes away" do
    before do
      asked
      ticks = 0
      allow(web).to receive(:serving?) { (ticks += 1) <= 1 }
    end

    let!(:result) { start(open: false) }

    it "stops, exit 0, and says why in the progress log" do
      expect([result.last, result[1]]).to match([0, include("the control room stopped; stopping the run")])
    end
  end

  describe "with work still to do" do
    before { asked }

    it "opens the board itself" do
      start
      expect(Agentilda::Web).to have_received(:open).with("http://127.0.0.1:4747")
    end
  end

  describe "without Redis" do
    before do
      asked
      allow(Agentilda::Live).to receive(:connect).and_raise(Agentilda::Live::Unavailable, "Redis at redis://h/0 is unavailable")
    end

    let!(:result) { start }

    it "refuses with exit 69 instead of going headless" do
      expect([result.last, result[1]]).to match([69, include("Redis at redis://h/0 is unavailable", "tilda start needs Redis")])
    end

    it "never starts the engine" do
      expect(Agentilda::Engine::Runner).not_to have_received(:new)
    end
  end

  describe "when the control room does not answer" do
    before do
      asked
      allow(web).to receive(:ready?).and_return(false)
    end

    let!(:result) { start }

    it "refuses with exit 69, naming its log" do
      expect([result.last, result[1]]).to match([69, include("did not answer on http://127.0.0.1:4747", "/tmp/web.log")])
    end

    it "stops the server it started" do
      expect(web).to have_received(:stop)
    end
  end

  it "refuses a --rescan that is not a positive whole number" do
    asked
    expect(start(rescan: "soon").last).to eq(64)
  end
end
