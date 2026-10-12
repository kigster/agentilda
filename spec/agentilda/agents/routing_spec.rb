# frozen_string_literal: true

RSpec.describe Agentilda::Agents::Routing, :tree do
  let(:agents) { Agentilda::Agents.registry }
  let(:subject_plan) { Agentilda::Plans::Tree.new(dir: plans_root).subjects.first }
  let(:planned) { Agentilda::Plans.status(:planned) }

  def plan_with(files)
    plans { |t| t.plan "001.00", :planned, "work", files: { "spec.md" => spec_body, "plan.md" => "## U1\n" }.merge(files) }
  end

  def routed = described_class.filter(agents.for_status(planned), subject_plan).map(&:name)

  it "gives a full-lane plan with front-end units to the pair" do
    plan_with("plan-frontend.md" => "# FE\n\n## F1\n")
    expect(routed).to eq(%w[luke-backend rey-frontend])
  end

  it "does not count a title line as a front-end unit" do
    plan_with("plan-frontend.md" => "# FE\n\nNo front-end units.\n")
    expect(routed).to eq(%w[luke-backend])
  end

  it "gives a quick-lane plan to r2d2-mechanic alone" do
    plan_with("spec.md" => "---\nlane: quick\n---\n#{spec_body}")
    expect(routed).to eq(%w[r2d2-mechanic])
  end

  it "lets a lone candidate through whatever its needs say" do
    plan_with({})
    expect(described_class.filter([agents.find("rey-frontend")], subject_plan).map(&:name)).to eq(%w[rey-frontend])
  end

  it "answers for one agent" do
    plan_with("spec.md" => "---\nfrontend: false\n---\n#{spec_body}")
    expect(described_class.allows?(agents.find("rey-frontend"), subject_plan)).to be(false)
  end
end
