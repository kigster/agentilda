# frozen_string_literal: true

# The three commands that print derived facts: `docs` (the conventions,
# regenerated from STATUSES and the aasm block), `states` (the same machine as
# a diagram) and `version`. None takes a tree; all deliver on STDOUT or to the
# file named, which is what these examples pin.
RSpec.describe "derived-output commands" do
  def run(command, **options)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      command.call(**options)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def unwrapped(text) = text.tr("║╔╗╚╝═", " ").gsub(/\s+/, " ")

  describe Agentilda::CLI::Docs do
    subject(:command) { described_class.new }

    # `mdformat` is a formatting nicety, not the deliverable; a machine
    # without it must not fail the write, so the shell-out is intercepted.
    before { allow(command).to receive(:system).and_return(true) }

    it "prints the whole conventions document when no output is named" do
      out, = run(command, output: nil)

      expect(out).to include("⚪️", "spec.md")
    end

    it "writes to the named file, creating the directories above it" do
      Dir.mktmpdir("agentilda-docs") do |tmp|
        path = File.join(tmp, "deep", "workflow.md")
        out, err, = run(command, output: path)

        expect(File.read(path)).to include("spec.md")
        expect(out).to eq("")
        # The box wraps a temp path mid-word; the filename is the stable part.
        expect(unwrapped(err)).to include("workflow.md")
      end
    end

    it "writes silently under --quiet" do
      Dir.mktmpdir("agentilda-docs") do |tmp|
        path = File.join(tmp, "workflow.md")
        _out, err, = run(command, output: path, quiet: true)

        expect(err).to eq("")
      end
    end
  end

  describe Agentilda::CLI::States do
    it "draws every state on STDOUT, where a pipe can take it" do
      out, err, = run(described_class.new)

      expect(out).to eq(Agentilda::Diagram.new.render)
      expect(err).to eq("")
    end
  end

  describe Agentilda::CLI::Version do
    it "prints the version and nothing else" do
      out, err, = run(described_class.new)

      expect(out).to eq("agentilda #{Agentilda::VERSION}\n")
      expect(err).to eq("")
    end
  end
end
