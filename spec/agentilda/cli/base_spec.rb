# frozen_string_literal: true

RSpec.describe Agentilda::CLI::Base do
  describe "#commit?" do
    subject { Class.new(described_class).new.send(:commit?, options) }

    let(:options) { {} }
    let(:autocommit) { nil }

    around do |example|
      autocommit.nil? ? ENV.delete("AGENTILDA_AUTOCOMMIT") : ENV["AGENTILDA_AUTOCOMMIT"] = autocommit
      example.run
    ensure
      ENV.delete("AGENTILDA_AUTOCOMMIT")
    end

    context "without --commit" do
      it { is_expected.to be(false) }
    end

    context "with --no-commit" do
      let(:options) { { commit: false } }

      it { is_expected.to be(false) }
    end

    context "with --commit" do
      let(:options) { { commit: true } }

      it { is_expected.to be(true) }
    end

    # `--commit` on every command, for someone who never wants the dry run.
    %w[true YES 1].each do |value|
      context "with AGENTILDA_AUTOCOMMIT=#{value}" do
        let(:autocommit) { value }
        let(:options) { { commit: false } }

        it { is_expected.to be(true) }
      end
    end

    ["false", ""].each do |value|
      context "with AGENTILDA_AUTOCOMMIT=#{value.inspect}" do
        let(:autocommit) { value }

        it { is_expected.to be(false) }
      end
    end
  end

  # `tilda docs .plans/README.md` — the `-o` left out — used to run with every
  # default, write the file somewhere the caller never named, and report
  # success. dry-cli collects a token no command declared into :args and says
  # nothing about it.
  describe "a token no command declares" do
    subject(:run) do
      status = 0
      original = $stderr
      $stderr = err
      begin
        command.new.call(**options)
      rescue SystemExit => e
        status = e.status
      ensure
        $stderr = original
      end
      status
    end

    let(:err) { CapturedStream.new }
    let(:command) { Class.new(described_class) { def call(**) = nil } }
    let(:options) { { args: [".plans/README.md"] } }

    it { is_expected.to eq(64) }

    it "names the token it refused" do
      run

      expect(strip_ansi(err.string)).to include(".plans/README.md")
    end

    context "when the command declares an argument of its own" do
      let(:command) do
        Class.new(described_class) do
          argument :words, type: :array
          def call(**) = nil
        end
      end
      let(:options) { { words: %w[fix the thing], args: %w[fix the thing] } }

      it { is_expected.to eq(0) }
    end

    context "when nothing strays" do
      let(:options) { { args: [] } }

      it { is_expected.to eq(0) }
    end
  end
end
