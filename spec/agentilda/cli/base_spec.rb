# frozen_string_literal: true

RSpec.describe Agentilda::CLI::Base do
  subject(:command) { Class.new(described_class).new }

  def commit?(options = {}, env: nil)
    ENV["AGENTILDA_AUTOCOMMIT"] = env if env
    command.send(:commit?, options)
  ensure
    ENV.delete("AGENTILDA_AUTOCOMMIT")
  end

  describe "#commit?" do
    it "is a dry run unless --commit is passed" do
      expect(commit?).to be(false)
      expect(commit?({ commit: false })).to be(false)
      expect(commit?({ commit: true })).to be(true)
    end

    it "treats AGENTILDA_AUTOCOMMIT=true as --commit on every command" do
      expect(commit?({ commit: false }, env: "true")).to be(true)
      expect(commit?({}, env: "YES")).to be(true)
      expect(commit?({}, env: "1")).to be(true)
    end

    it "ignores AGENTILDA_AUTOCOMMIT set to anything else" do
      expect(commit?({}, env: "false")).to be(false)
      expect(commit?({}, env: "")).to be(false)
    end
  end
end
