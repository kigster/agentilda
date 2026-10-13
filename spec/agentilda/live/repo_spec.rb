# frozen_string_literal: true

require "open3"

RSpec.describe Agentilda::Live::Repo do
  describe ".normalise" do
    {
      "git@github.com:Kigster/Agentilda.git"          => "github.com/kigster/agentilda",
      "https://github.com/kigster/agentilda"          => "github.com/kigster/agentilda",
      "https://github.com/kigster/agentilda.git/"     => "github.com/kigster/agentilda",
      "ssh://git@github.com/kigster/agentilda.git"    => "github.com/kigster/agentilda",
      "ssh://git@github.com:22/kigster/agentilda.git" => "github.com/kigster/agentilda",
      "https://user:token@github.com/o/n"             => "github.com/o/n"
    }.each do |url, expected|
      it "folds #{url}" do
        expect(described_class.normalise(url)).to eq(expected)
      end
    end

    it "makes nothing of a string that is not a remote" do
      expect(described_class.normalise("just-a-name")).to be_nil
    end
  end

  describe ".for" do
    let(:dir) { Dir.mktmpdir("agentilda-repo") }
    let(:root) { File.join(dir, "my-clone").tap { FileUtils.mkdir_p(it) } }

    after { FileUtils.rm_rf(dir) }

    def git(*) = Open3.capture2e("git", "-C", root, *)

    it "reads origin" do
      git("init", "-q")
      git("remote", "add", "origin", "git@github.com:Example/Thing.git")
      expect(described_class.for(root)).to eq("github.com/example/thing")
    end

    it "falls back to the directory's name with no remote to share" do
      expect(described_class.for(root)).to eq("my-clone")
    end

    it "falls back to the name it was given when the directory is not there" do
      expect(described_class.for(File.join(root, "gone"))).to eq("gone")
    end
  end
end
