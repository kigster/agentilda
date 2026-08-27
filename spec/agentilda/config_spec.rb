# frozen_string_literal: true

RSpec.describe Agentilda::Config do
  def config_file(content)
    file = Tempfile.create(["agentilda", ".json"])
    File.write(file.path, content)
    file.path
  end

  it "returns {} when the file does not exist" do
    expect(described_class.for(:run, path: "/nowhere/agentilda.json")).to eq({})
  end

  it "returns the named command's section with symbol keys" do
    path = config_file('{"run": {"timeout": 1800, "jobs": 4}}')

    expect(described_class.for(:run, path:)).to eq(timeout: 1800, jobs: 4)
  end

  it "returns {} for a command the file does not mention" do
    path = config_file('{"run": {"timeout": 1800}}')

    expect(described_class.for(:create, path:)).to eq({})
  end

  # A config silently ignored is how a timeout somebody set stops applying
  # with no signal anywhere, so a broken file is an error, never a shrug.
  it "raises on invalid JSON, naming the file" do
    path = config_file("{not json")

    expect { described_class.for(:run, path:) }
      .to raise_error(Agentilda::Error, /#{Regexp.escape(path)}.*not valid JSON/m)
  end

  it "raises when the file is not an object keyed by command" do
    path = config_file('["timeout", 1800]')

    expect { described_class.for(:run, path:) }.to raise_error(Agentilda::Error, /keyed by command/)
  end

  it "raises when a command's section is not an object" do
    path = config_file('{"run": 1800}')

    expect { described_class.for(:run, path:) }.to raise_error(Agentilda::Error, /"run" must be a JSON object/)
  end
end
