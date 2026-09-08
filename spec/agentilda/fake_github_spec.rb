# frozen_string_literal: true

# A folder of markdown files standing in for GitHub, so the whole resync can
# run against a fixture with known answers.
RSpec.describe Agentilda::FakeGitHub do
  subject(:github) { described_class.new(dir:) }

  let(:dir) { Dir.mktmpdir("prs") }

  after { FileUtils.rm_rf(dir) }

  def write(number, **meta)
    body = meta.delete(:body) || "What ##{number} did."
    front = {"number" => number, "title" => "PR #{number}", "branch" => "kig/#{number}", "state" => "open"}.merge(meta.transform_keys(&:to_s))
    File.write(File.join(dir, "#{number}.md"), "#{YAML.dump(front)}---\n#{body}\n")
  end

  describe "#pulls" do
    before do
      write(12, title: "Add the DSL", state: "merged", created_at: "2026-08-01T10:00:00Z", merged_at: "2026-08-03T16:20:00Z",
        head_sha: "0123abcd", files: [{"path" => "lib/printer.rb", "additions" => 120, "deletions" => 4}])
      write(3, state: "draft", files: ["README.md"])
      write(20, state: "closed")
    end

    it "reads every file into the shape GitHub#pulls produces, in number order" do
      pull = github.pulls.first

      aggregate_failures do
        expect(github.pulls.map { |p| p[:number] }).to eq([3, 12, 20])
        expect(pull[:title]).to eq("PR 3")
        expect(pull[:state]).to eq("WIP 🟡")
        expect(pull[:files]).to eq(["README.md"])
        expect(pull[:changes]).to eq([{path: "README.md", additions: 0, deletions: 0}])
      end
    end

    it "carries line counts, times, the head commit and the body" do
      pull = github.pulls.find { |p| p[:number] == 12 }

      aggregate_failures do
        expect(pull[:changes]).to eq([{path: "lib/printer.rb", additions: 120, deletions: 4}])
        expect(pull[:created_at]).to eq(Time.utc(2026, 8, 1, 10))
        expect(pull[:merged_at]).to eq(Time.utc(2026, 8, 3, 16, 20))
        expect(pull[:head_sha]).to eq("0123abcd")
        expect(pull[:body]).to eq("What #12 did.")
        expect(pull[:state]).to eq("Merged 🟣")
        expect(pull[:open]).to be(false)
      end
    end

    it "filters by state the way gh does" do
      aggregate_failures do
        expect(github.pulls(state: "open").map { |p| p[:number] }).to eq([3])
        expect(github.pulls(state: "merged").map { |p| p[:number] }).to eq([12])
        expect(github.pulls(state: "closed").map { |p| p[:number] }).to eq([12, 20])
      end
    end

    it "refuses a folder that is not there" do
      expect { described_class.new(dir: File.join(dir, "nope")).pulls }.to raise_error(Agentilda::Error, /no pull request folder/)
    end
  end

  describe "#retitle" do
    before { write(12, title: "Add the DSL", body: "Keep me.") }

    it "rewrites the title line and nothing else" do
      github.retitle(number: 12, title: "[003.00] Add the DSL")
      content = File.read(File.join(dir, "12.md"))

      aggregate_failures do
        expect(content).to include('title: "[003.00] Add the DSL"')
        expect(content).to include("Keep me.", "branch: kig/12")
        expect(github.pull_request("12")[:title]).to eq("[003.00] Add the DSL")
      end
    end

    it "refuses a number nobody has" do
      expect { github.retitle(number: 99, title: "x") }.to raise_error(Agentilda::Error, /#99/)
    end
  end

  describe "#pull_request" do
    before { write(12, title: "Add the DSL") }

    it "answers by number, in the view shape" do
      expect(github.pull_request("#12")).to eq(number: 12, title: "Add the DSL",
        url: "https://github.com/example/repo/pull/12", state: "Open 🟡", body: "What #12 did.")
    end

    it "refuses a number nobody has" do
      expect { github.pull_request("99") }.to raise_error(Agentilda::Error, /#99/)
    end
  end

  it "keys its cache by the folder's name" do
    expect(described_class.new(dir: "/tmp/x/.prs").slug).to eq("fake-prs")
  end
end
