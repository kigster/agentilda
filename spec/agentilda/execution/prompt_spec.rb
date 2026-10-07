# frozen_string_literal: true

# The executor's specs read the prompt through the argv. These build one
# directly, which is the point of it being its own object: what an agent is
# told can be checked without a process, an executor or an adapter's flags.
RSpec.describe Agentilda::Execution::Prompt, :tree do
  subject(:text) do
    described_class.new(agent:,
      subject: plan,
      root: "/repo",
      profile:,
      round: 3,
      successor: "hansolo-reviewer",
      max_tokens: 1000,
      seconds: 120,
      denied: ["git push"],
      granted: ["gh pr review"]).to_s
  end

  let(:agent) { Agentilda::Agents.find("r2d2-mechanic") }
  let(:profile) { Agentilda::Agents::Profile.resolve(agent) }
  let(:plan) do
    plans { |t| t.plan "001.00", :building, "task", files: { "spec.md" => spec_body, "plan.md" => "## Task\n" } }
    Agentilda::Plans::Tree.new(dir: plans_root).subjects.first
  end

  it "opens with the agent's own definition" do
    expect(text).to start_with(agent.prompt)
  end

  it "states the budgets the executor will enforce" do
    expect(text).to include("Token budget — 1000 tokens", "Time budget - 120 seconds")
  end

  it "names the round and the successor in the signing command" do
    expect(text).to include("--round 3 --status Completed --next hansolo-reviewer")
  end

  # The agent's PATH can hold an older release that has no `state sign`.
  it "signs through this checkout's own executable, not whatever is on PATH" do
    expect(text).to include("#{described_class::EXECUTABLE} state sign --dir")
  end

  it "lists what is withheld and what is granted" do
    expect(text).to include("  git push", "You may run these, which most agents may not:\n\n  gh pr review")
  end

  it "adds no operator section when nobody steered the run" do
    expect(text).not_to include("Operator instructions")
  end
end
