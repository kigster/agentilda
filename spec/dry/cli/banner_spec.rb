# frozen_string_literal: true

require "dry/cli"

# The vendored banner, patched for colour control. Every command's `--help`
# runs through here, so an unexercised branch is a help screen nobody has ever
# seen — and the colour switch is global state, which is exactly the kind of
# thing that breaks only when the untested combination finally runs.
module BannerFixture
  # A command using every feature the banner renders: description, required
  # and optional arguments, one option of each shape, and examples.
  class Deploy < Dry::CLI::Command
    desc "Deploys the thing"

    argument :target, required: true, desc: "Where it goes"
    argument :tag, desc: "Which build"

    option :mode, desc: "How to deploy", default: "safe", aliases: ["-m"]
    option :verbose, type: :boolean, desc: "Say more"
    option :force, type: :flag, desc: "Skip the checks"
    option :only, type: :array, desc: "Restrict to these"

    example ["prod # ship to production", "staging v2 # rehearse first"]

    def call(**)
    end
  end

  # A command declaring nothing optional, so every `return if empty` guard in
  # the banner takes its early exit rather than rendering an empty section.
  class Bare < Dry::CLI::Command
    def call(**)
    end
  end

  # A parent whose registration gains a child, so `command.subcommands` is the
  # registry's live children hash rather than the empty default.
  class Parent < Dry::CLI::Command
    desc "Groups related commands"

    def call(**)
    end
  end

  class Child < Dry::CLI::Command
    desc "Does the actual work"

    def call(**)
    end
  end

  extend Dry::CLI::Registry

  register "deploy", Deploy
  register "bare", Bare
  register "parent", Parent
  register "parent child", Child
end

RSpec.describe Dry::CLI::Banner do
  # The colour switch is module-level state shared by every example in the
  # process, so each example puts it back where it found it — otherwise one
  # `enable_color!` here would repaint every CLI spec that runs after it.
  around do |example|
    was_enabled = described_class.color_enabled?
    example.run
  ensure
    was_enabled ? described_class.enable_color! : described_class.disable_color!
  end

  def banner(command, name = "prog") = strip_ansi(described_class.call(command.new, name))

  describe ".call on a fully-featured command" do
    subject(:text) { banner(BannerFixture::Deploy, "agentilda deploy") }

    it "names the command" do
      expect(text).to include("COMMAND:").and include("agentilda deploy")
    end

    it "shows required arguments bare and optional ones bracketed" do
      expect(text).to include("agentilda deploy TARGET [TAG]")
    end

    it "carries the description" do
      expect(text).to include("DESCRIPTION:").and include("Deploys the thing")
    end

    it "lists each argument with its own description, marking the required one" do
      aggregate_failures do
        expect(text).to match(/TARGET\s+.*# REQUIRED Where it goes/)
        expect(text).to match(/TAG\s+.*# Which build/)
      end
    end

    # Each option shape renders differently, and a wrong one misleads the
    # reader about what the shell line should look like.
    it "renders a plain option as --name=VALUE with its default" do
      expect(text).to match(/--mode=VALUE.*# How to deploy, default: "safe"/)
    end

    it "renders a boolean option as its --[no-] pair" do
      expect(text).to include("--[no-]verbose")
    end

    it "renders a flag option as the bare switch" do
      expect(text).to match(/--force\s+.*# Skip the checks/)
    end

    it "renders an array option with a VALUE1,VALUE2 hint" do
      expect(text).to include("--only=VALUE1,VALUE2,..")
    end

    it "lists an option's aliases beside its long name" do
      expect(text).to include("-m")
    end

    it "always offers --help, even though no command declares it" do
      expect(text).to include("--help, -h")
    end

    # The note used to trail the command on the same line, which pushed the
    # shell line off to the right and made it awkward to copy. It now sits
    # above, so what you select is exactly what you paste.
    it "puts each example's note above the line it describes, program name and all" do
      aggregate_failures do
        expect(text).to include("# ship to production\n  agentilda deploy prod")
        expect(text).to include("# rehearse first\n  agentilda deploy staging v2")
      end
    end
  end

  describe ".call on a command declaring nothing optional" do
    subject(:text) { banner(BannerFixture::Bare, "prog bare") }

    # A command with no description must not render an empty "Description:"
    # heading — a heading with nothing under it reads as a rendering bug.
    it "omits the sections it has nothing to say in" do
      aggregate_failures do
        expect(text).not_to include("DESCRIPTION:")
        expect(text).not_to include("EXAMPLES:")
        expect(text).not_to include("ARGUMENTS:")
        expect(text).not_to include("SUBCOMMANDS:")
      end
    end

    it "still renders the usage line and the options, which every command has" do
      aggregate_failures do
        expect(text).to include("USAGE:")
        expect(text).to include("OPTIONS:")
      end
    end
  end

  describe ".call on a command with subcommands" do
    subject(:text) { banner(BannerFixture::Parent, "prog parent") }

    it "tells the reader a SUBCOMMAND is expected" do
      expect(text).to include("prog parent | prog parent SUBCOMMAND")
    end

    it "lists each subcommand with its description" do
      expect(text).to match(/SUBCOMMANDS:.*child\s+# Does the actual work/m)
    end
  end

  describe "the colour switch" do
    it "reports its own state, so the CLI can decide once and ask later" do
      described_class.disable_color!

      expect(described_class.color_enabled?).to be(false)
    end

    context "when colour is disabled" do
      before { described_class.disable_color! }

      it "renders headers as bare upper-case text" do
        expect(described_class.color_header("usage")).to eq("USAGE")
      end

      it "hands commands and arguments back untouched" do
        aggregate_failures do
          expect(described_class.color_command("deploy")).to eq("deploy")
          expect(described_class.color_arguments(" TARGET")).to eq(" TARGET")
        end
      end

      # The stand-in must answer both of Pastel's shapes: `yellow("x")`
      # decorates in one call, `yellow.bold("x")` chains. A stand-in that
      # answers only one raises NoMethodError from inside help rendering.
      it "answers a chained decoration the way Pastel would, minus the colour" do
        expect(described_class.pastel.yellow.bold("plain")).to eq("plain")
      end

      it "answers a direct decoration too" do
        expect(described_class.pastel.yellow("plain")).to eq("plain")
      end

      it "renders a whole banner with no escape codes at all" do
        expect(described_class.call(BannerFixture::Deploy.new, "prog")).not_to match(/\e\[/)
      end
    end

    context "when colour is enabled" do
      before { described_class.enable_color! }

      it "reports so" do
        expect(described_class.color_enabled?).to be(true)
      end

      # Content assertions rather than escape-code assertions: Pastel decides
      # for itself whether the terminal merits colour, and the suite runs
      # piped. What must hold either way is that the words survive.
      it "still carries the text through every coloured helper" do
        aggregate_failures do
          expect(strip_ansi(described_class.color_header("usage"))).to eq("USAGE")
          expect(strip_ansi(described_class.color_command("deploy"))).to eq("deploy")
          expect(strip_ansi(described_class.color_arguments(" TARGET"))).to eq(" TARGET")
        end
      end

      it "renders the full banner without losing a section" do
        text = strip_ansi(described_class.call(BannerFixture::Deploy.new, "prog"))

        expect(text).to include("USAGE:").and include("OPTIONS:").and include("EXAMPLES:")
      end
    end

    # Switching colour must rebuild the engine: the pastel object is memoized,
    # and a stale one keeps answering for the mode that has just been left.
    it "forgets the memoized engine on every switch, in both directions" do
      described_class.disable_color!
      colourless = described_class.pastel
      described_class.enable_color!
      coloured = described_class.pastel
      described_class.disable_color!

      aggregate_failures do
        expect(colourless).to be_a(Dry::CLI::Banner::ColorMethods::NoColorPastel)
        expect(coloured).not_to be_a(Dry::CLI::Banner::ColorMethods::NoColorPastel)
        expect(described_class.pastel).to be_a(Dry::CLI::Banner::ColorMethods::NoColorPastel)
      end
    end
  end
end
