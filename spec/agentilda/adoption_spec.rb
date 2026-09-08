# frozen_string_literal: true

# Pull requests that resolve to no plan get one minted for them: a sibling
# slot beside the plan they landed after, or a new number at the end of the
# stack. The property that matters is not that the numbering is
# *deterministic* — the obvious parallel design is deterministic and still
# wrong — but that it is **distinct**, which is why allocation is serial.
RSpec.describe Agentilda::Adoption, :tree do
  subject(:adoption) { described_class.new(tree: Agentilda::Tree.new(dir: plans_root)) }

  let!(:tree) do
    plans do |t|
      t.plan "001.00", :new, "initial-spec", files: {"spec.md" => spec_body}
      t.plan "024.00", :approved, "engine-core", prs: [t.merged(2, "Ship it")]
    end
  end

  def pull(number, title, body: "What #{number} did.")
    {number:, title:, branch: "kig/work-#{number}", files: [], state: "Open 🟡", open: true, body:,
     url: "https://github.com/example/repo/pull/#{number}"}
  end

  describe "#plan" do
    context "when many pull requests all land after the same plan" do
      let(:placements) { (95..109).map { |n| [pull(n, "Work #{n}"), 24] } }

      it "gives every one of them a different number" do
        expect(adoption.plan(placements).map { |a| a.ordinal.to_s }.uniq.size).to eq(15)
      end

      it "numbers them in ascending pull request order, so the run is reproducible" do
        adoptees = adoption.plan(placements.reverse)

        aggregate_failures do
          expect(adoptees.map { |a| a.pull[:number] }).to eq((95..109).to_a)
          expect(adoptees.first.ordinal.to_s).to eq("024.01")
          expect(adoptees.last.ordinal.to_s).to eq("024.15")
        end
      end
    end

    it "steps over minors the tree already holds rather than colliding with them" do
      plans { |t| t.plan "024.01", :approved, "already-here", prs: [t.merged(9, "x")] }
      fresh = described_class.new(tree: Agentilda::Tree.new(dir: plans_root))

      expect(fresh.plan([[pull(95, "Work"), 24]]).first.ordinal.to_s).to eq("024.02")
    end

    it "opens a new whole number at the end of the stack for a straggler" do
      adoptees = adoption.plan([[pull(95, "Lost"), nil], [pull(96, "Also lost"), nil]])

      aggregate_failures do
        expect(adoptees.map { |a| a.ordinal.to_s }).to eq(%w[025.00 026.00])
        expect(adoptees).to all(be_straggler)
      end
    end

    it "names the folder from the pull request's title, prefix stripped" do
      expect(adoption.plan([[pull(95, "[dev] Add the health checks"), 24]]).first.dirname).to eq("024.01-🕰️--add-the-health-checks")
    end

    it "skips a placement whose gap is full rather than wrapping" do
      crowded = plans { |t| (1..99).each { |m| t.plan(format("024.%02d", m), :new, "p#{m}", files: {"spec.md" => spec_body}) } }
      fresh = described_class.new(tree: Agentilda::Tree.new(dir: crowded))

      expect(fresh.plan([[pull(95, "One too many"), 24]])).to be_empty
    end
  end

  describe "#call" do
    let(:placements) { [[pull(95, "Health checks"), 24], [pull(96, "Structured logging"), nil]] }

    it "creates a folder for each, holding the pull request that earned it" do
      adoption.call(placements)

      aggregate_failures do
        expect(Dir.children(plans_root)).to include("024.01-🕰️--health-checks", "025.00-🕰️--structured-logging")
        expect(File.read(File.join(plans_root, "024.01-🕰️--health-checks", "pull-requests.md"))).to include("/pull/95", "What 95 did.")
      end
    end

    it "writes spec.md and plan.md from the pull request's own description" do
      adoption.call(placements)
      folder = File.join(plans_root, "024.01-🕰️--health-checks")

      aggregate_failures do
        expect(Dir.children(folder).sort).to eq(%w[plan.md pull-requests.md spec.md])
        expect(File.read(File.join(folder, "spec.md"))).to include("# Health checks", "## Goal", "What 95 did.", "pull request #95")
        expect(File.read(File.join(folder, "plan.md"))).to include("## Plan", "What 95 did.")
      end
    end

    it "says so when no description was written" do
      adoption.call([[pull(97, "Quiet", body: ""), nil]])

      expect(File.read(File.join(plans_root, "025.00-🕰️--quiet", "spec.md"))).to include("No description was written")
    end

    it "leaves an existing folder alone" do
      adoption.call(placements)
      before = File.read(File.join(plans_root, "024.01-🕰️--health-checks", "spec.md"))
      described_class.new(tree: Agentilda::Tree.new(dir: plans_root)).call([[pull(95, "Health checks"), 24]])

      expect(Dir.children(plans_root).grep(/health-checks/).size).to eq(2).or eq(1)
      expect(File.read(File.join(plans_root, "024.01-🕰️--health-checks", "spec.md"))).to eq(before)
    end
  end
end
