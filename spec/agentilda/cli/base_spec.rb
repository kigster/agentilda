# frozen_string_literal: true

RSpec.describe Agentilda::CLI::Base do
  describe "#dry_run?" do
    subject { Class.new(described_class).new.send(:dry_run?, options) }

    let(:options) { {} }

    # A command does the work it is named for: no flag means do it.
    context "without --dry-run" do
      it { is_expected.to be(false) }
    end

    context "with --dry-run" do
      let(:options) { { dry_run: true } }

      it { is_expected.to be(true) }
    end
  end

  describe ".dry_run_option" do
    subject(:option) { Agentilda::CLI::Run.options.find { |o| o.name == :dry_run } }

    it "declares -n, off by default" do
      expect([option.aliases, option.default]).to eq([["-n"], false])
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
