# frozen_string_literal: true

require_relative "live_context"

RSpec.describe Agentilda::Live::Session, :tree do
  subject(:session) do
    described_class.new(store:, root: File.dirname(plans_root), tree:, agents:, node:, repo: keys.repo)
  end

  include_context "with a live run"

  before { building("001.00", "tax-rule-dsl") }

  let(:claims) { session.claims }
  let(:dispatcher) { Agentilda::Engine::Dispatcher.new(runner:, sleeper: ->(_) {}, on_board: session.on_board) }

  context "when attached to a run" do
    before do
      session.attach(dispatcher)
      Agentilda::Live.enqueue(store:, keys: session.keys, input: { id: "01J", kind: "stop_all", payload: {} })
      dispatcher.tick
    end

    after { session.close }

    it "publishes each tick's board" do
      expect(Agentilda::Live.board(store:, keys: session.keys)[:me]["project"]).to eq(File.basename(File.dirname(plans_root)))
    end

    it "applies commands at the top of the tick, before anything starts" do
      expect([Agentilda::Live.replies(store:, keys: session.keys, after: "0").map { it.last["status"] }, claims.held])
        .to eq([%w[done], []])
    end
  end

  context "when an agent has started" do
    before { start_agents }

    it "holds the plan's claim" do
      expect(claims.held).to eq(%w[001.00])
    end

    it "gives the claim back on close" do
      session.close
      expect(store.get(session.keys.claim("001.00"))).to be_nil
    end
  end

  it "takes its snapshot down on close, so other pages stop showing it" do
    session.publisher.call(dispatcher.board)
    session.close
    expect(store.get(session.keys.snapshot)).to be_nil
  end

  it "closes quietly when Redis has gone" do
    allow(store).to receive(:del).and_raise(Agentilda::Live::Unavailable, "gone")
    expect(session.close).to be_nil
  end

  it "describes itself for the start-up line" do
    expect(session.describe).to eq("memory:// as dana@studio-mini (#{node.name})")
  end

  it "keeps its run state, publisher and commands for the server beside it" do
    expect([session.run_state, session.publisher, session.commands, session.store, session.node])
      .to match([Agentilda::Live::RunState, Agentilda::Live::Publisher, Agentilda::Live::Commands, store, node])
  end
end
