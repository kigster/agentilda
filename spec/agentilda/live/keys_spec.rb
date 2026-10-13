# frozen_string_literal: true

RSpec.describe Agentilda::Live::Keys do
  subject(:keys) { described_class.new(repo: "github.com/o/n", node: "abc:def") }

  it "lays out every key as contract.md does" do
    expect([keys.nodes, keys.snapshot, keys.board, keys.commands, keys.replies, keys.done, keys.claim("004.00")])
      .to eq(%w[agentilda:github.com/o/n:nodes agentilda:github.com/o/n:abc:def:snapshot
                agentilda:github.com/o/n:abc:def:board agentilda:github.com/o/n:abc:def:commands
                agentilda:github.com/o/n:abc:def:replies agentilda:github.com/o/n:abc:def:done
                agentilda:github.com/o/n:claim:004.00])
  end

  it "names another node's keys through the same methods" do
    expect([keys.snapshot("x:y"), keys.board("x:y")]).to eq(%w[agentilda:github.com/o/n:x:y:snapshot agentilda:github.com/o/n:x:y:board])
  end
end
