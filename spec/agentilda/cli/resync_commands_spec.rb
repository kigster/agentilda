# frozen_string_literal: true

# Both resyncs write to things other tools join on — folder names, pull
# request titles — so the property under test throughout is candour: a dry run
# says it changed nothing, a commit says exactly what it changed, and anything
# too ambiguous to touch is reported rather than skipped in silence.
RSpec.describe "agentilda resync", :tree do
  def run(command, **options)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      command.call(dir: plans_root, **options)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def unwrapped(text) = text.tr("║╔╗╚╝═", " ").gsub(/\s+/, " ")

  describe Agentilda::CLI::Resync::Dirs do
    subject(:command) { described_class.new }

    it "says every folder already holds when there is nothing to do" do
      plans { |t| t.plan("001.00", :new, "fine", files: {"spec.md" => spec_body}) }
      out, err, = run(command)

      expect(out).to eq("")
      expect(unwrapped(err)).to include("already named")
    end

    context "with a folder whose contents outgrew its name" do
      before do
        # A ⚪️ folder that has grown a plan.md with work units best-fits ⭐️ whatever its name says.
        plans { |t| t.plan("001.00", :new, "outgrown", files: {"spec.md" => spec_body, "plan.md" => "# Plan"}) }
      end

      it "prints the rename as a machine-readable row and leaves the disk alone" do
        out, err, = run(command)

        expect(out).to include("001.00-⚪️--outgrown\t001.00-⭐️--outgrown")
        expect(Dir.children(plans_root)).to include("001.00-⚪️--outgrown")
        expect(unwrapped(err)).to include("1 rename pending", "--commit")
      end

      it "renames under --commit and says how many folders moved" do
        _out, err, = run(command, commit: true)

        expect(Dir.children(plans_root)).to include("001.00-⭐️--outgrown")
        expect(unwrapped(err)).to include("Renamed 1 folder")
      end

      it "keeps the rows and drops the prose under --quiet" do
        out, err, = run(command, quiet: true)

        expect(out).to include("001.00-⚪️--outgrown")
        expect(err).to eq("")
      end
    end
  end

  describe Agentilda::CLI::Resync::Prs do
    subject(:command) { described_class.new }

    let(:github) { instance_double(Agentilda::GitHub, slug: "example-repo", retitle: nil) }
    let(:resolver) { instance_double(Agentilda::Resolver) }
    let(:verdicts) { {} }

    before do
      allow(Agentilda::GitHub).to receive(:new).and_return(github)
      allow(Agentilda::Resolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:call) { |pending|
        pending.map { |pull|
          verdicts.fetch(pull[:number]) {
            Agentilda::Resolver::Verdict.new(number: pull[:number], confidence: 0.1, reason: "nothing fits", up: 900, down: 30, cost: 0.002)
          }
        }
      }
    end

    def pull(number, title, branch: "", files: [], body: "")
      {number:, title:, url: "https://github.com/example/repo/pull/#{number}", branch:, files:, body:,
       changes: files.map { |path| {path:, additions: 1, deletions: 0} }, state: "Open 🟡", open: true,
       created_at: Time.utc(2026, 8, number), merged_at: nil, head_sha: "sha#{number}"}
    end

    it "says every title already carries a prefix when they all do" do
      allow(github).to receive(:pulls).and_return([pull(1, "[001.00] Done already")])
      out, err, = run(command)

      expect(out).to eq("")
      expect(unwrapped(err)).to include("already carries a prefix")
    end

    context "with titles to resolve" do
      before do
        plans { |t| t.plan("001.00", :new, "tax-rule-dsl", files: {"spec.md" => spec_body}) }
        allow(github).to receive(:pulls).and_return([
          pull(7, "Add the DSL", branch: "kig/001.00-tax-rule-dsl"),
          pull(9, "Bump CI cache")
        ])
      end

      it "previews each retitle as a row without touching GitHub" do
        out, = run(command, adopt: false)

        expect(out).to include("7\t[001.00] Add the DSL\tbranch kig/001.00-tax-rule-dsl")
        expect(out).to include("9\t-\t")
        expect(github).not_to have_received(:retitle)
      end

      it "reports what the judge cost, even on a dry run" do
        _out, err, = run(command, adopt: false)

        expect(unwrapped(err)).to include("jabba-resolver judged 1 pull request (0 from cache): 900 tokens in, 30 out, $0.0020")
      end

      it "retitles through the seam under --commit and reports the count" do
        _out, err, = run(command, adopt: false, commit: true)

        expect(github).to have_received(:retitle).with(number: 7, title: "[001.00] Add the DSL")
        expect(unwrapped(err)).to include("Retitled 1 pull request")
      end

      it "passes the typed model and job count to the resolver" do
        run(command, adopt: false, model: "sonnet", jobs: 3)

        expect(Agentilda::Resolver).to have_received(:new).with(hash_including(model: "sonnet", jobs: 3,
          cache_dir: File.join(Agentilda::Resolver::CACHE_ROOT, "example-repo", "verdicts")))
      end
    end

    context "with a pull request nothing can resolve" do
      before do
        plans { |t| t.plan("001.00", :new, "tax-rule-dsl", files: {"spec.md" => spec_body}) }
        allow(github).to receive(:pulls).and_return([pull(4, "Mystery work", branch: "kig/099.00-mystery", body: "It does things.")])
      end

      it "flags it for a human under --no-adopt rather than editing it" do
        out, err, = run(command, adopt: false)

        expect(out).to include("4\t-\tjabba-resolver 10%: nothing fits")
        expect(unwrapped(err)).to include("SKIPPED")
      end

      it "proposes a new plan at the end of the stack by default" do
        out, err, = run(command)

        expect(out).to include("4\t[002.00] Mystery work\t", "would adopt into 002.00")
        expect(unwrapped(err)).to include("Would create 1 plan folder", "(new plan)")
        expect(Dir.children(plans_root)).not_to include(a_string_starting_with("002.00"))
      end

      it "mints the folder with the description under --commit" do
        run(command, commit: true)

        expect(File.read(File.join(plans_root, "002.00-🕰️--mystery-work", "spec.md"))).to include("It does things.")
      end
    end

    context "with a folder of markdown files standing in for GitHub" do
      let(:prs) { Dir.mktmpdir("prs") }

      before do
        plans { |t| t.plan("001.00", :new, "tax-rule-dsl", files: {"spec.md" => spec_body}) }
        File.write(File.join(prs, "5.md"), "---\nnumber: 5\ntitle: Add the DSL\nbranch: kig/001.00-dsl\nstate: open\n---\nBody.\n")
      end

      after { FileUtils.rm_rf(prs) }

      it "never calls gh, and writes the retitle back into the file" do
        run(command, commit: true, fake_github_path: prs)

        expect(Agentilda::GitHub).not_to have_received(:new)
        expect(File.read(File.join(prs, "5.md"))).to include('title: "[001.00] Add the DSL"')
      end
    end

    it "reports a gh that cannot answer instead of a stack trace" do
      allow(github).to receive(:pulls).and_raise(Agentilda::Error, "could not list pull requests via `gh`: boom")
      _out, err, status = run(command)

      expect(unwrapped(err)).to include("could not list pull requests")
      expect(status).to eq(69)
    end
  end

  describe Agentilda::CLI::Resync::All do
    subject(:command) { described_class.new }

    let(:dirs) { instance_double(Agentilda::CLI::Resync::Dirs) }
    let(:prs) { instance_double(Agentilda::CLI::Resync::Prs) }
    let(:calls) { [] }

    before do
      plans { |t| t.plan("001.00", :new, "fine", files: {"spec.md" => spec_body}) }
      allow(Agentilda::CLI::Resync::Dirs).to receive(:new).and_return(dirs)
      allow(Agentilda::CLI::Resync::Prs).to receive(:new).and_return(prs)
      allow(dirs).to receive(:call) { |**o| calls << [:dirs, o] }
      allow(prs).to receive(:call) { |**o| calls << [:prs, o] }
    end

    it "runs dirs, then prs, then dirs again, forwarding each flag to the child that takes it" do
      run(command, commit: true, force: true, state: "open")

      aggregate_failures do
        expect(calls.map(&:first)).to eq(%i[dirs prs dirs])
        expect(calls[0].last).to eq(dir: plans_root, commit: true)
        expect(calls[1].last).to include(dir: plans_root, commit: true, force: true, state: "open")
        expect(calls[1].last).not_to include(:nope)
      end
    end

    it "stops when the first dirs refuses, and says so" do
      allow(dirs).to receive(:call) {
        calls << [:dirs, {}]
        exit 65
      }
      _out, err, status = run(command)

      aggregate_failures do
        expect(status).to eq(65)
        expect(calls.map(&:first)).to eq([:dirs])
        expect(unwrapped(err)).to include("resync dirs failed", "not run")
      end
    end
  end
end
