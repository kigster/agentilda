# frozen_string_literal: true

RSpec.describe Agentilda::OpenAPI, :tree do
  subject(:documents) { described_class.documents(tree) }

  let(:tree) { Agentilda::Tree.new(dir: plans_root) }

  let(:valid) do
    <<~YAML
      openapi: 3.1.0
      info:
        title: Returns
        version: "1"
      paths:
        /returns/{id}:
          get:
            responses:
              "200":
                description: a return
    YAML
  end

  def plan_with(ordinal, slug, contents)
    plans do |t|
      folder = t.plan ordinal, :building, slug, files: { "spec.md" => spec_body, "plan.md" => "# P" }
      File.write(File.join(folder, described_class::FILENAME), contents) if contents
    end
  end

  it "finds nothing in a tree where no plan carries one" do
    plan_with("001.00", "no-http", nil)
    expect(documents).to be_empty
  end

  describe "a plan that carries one" do
    subject(:document) { documents.first }

    before { plan_with("001.00", "returns-api", valid) }

    it "is found by its plan" do
      expect(document.ordinal).to eq("001.00")
    end

    it "is titled from the document itself" do
      expect(document.title).to eq("Returns")
    end

    it "is usable" do
      expect(document).to be_usable
    end
  end

  it "falls back to the plan's own slug when the document names no title" do
    plan_with("001.00", "returns-api", "openapi: 3.1.0\npaths: {}\n")
    expect(documents.first.title).to eq("returns-api")
  end

  # The check is shallow on purpose. What it has to catch is the file an
  # agent wrote before it had finished writing it, not a subtle schema
  # error — that would be another dependency, and can be added if agents
  # turn out to produce one.
  describe "a document that is not usable" do
    subject(:problems) { documents.first.problems }

    it "says which key is missing" do
      plan_with("001.00", "returns-api", "openapi: 3.1.0\n")
      expect(problems).to eq(["has no `paths:` key"])
    end

    it "names every missing key, not just the first" do
      plan_with("001.00", "returns-api", "info:\n  title: Returns\n")
      expect(problems.size).to eq(2)
    end

    it "says so when the file is not YAML at all" do
      plan_with("001.00", "returns-api", "openapi: [unclosed\n")
      expect(problems.first).to include("is not YAML")
    end

    it "says so when the YAML is not a mapping" do
      plan_with("001.00", "returns-api", "- one\n- two\n")
      expect(problems.first).to include("not a mapping")
    end

    # A broken document in one plan must not hide a good one in another.
    it "is still listed, beside the plans that are fine" do
      plan_with("001.00", "returns-api", "openapi: 3.1.0\n")
      plan_with("002.00", "orders-api", valid)

      expect(documents.map(&:usable?)).to eq([false, true])
    end
  end
end
