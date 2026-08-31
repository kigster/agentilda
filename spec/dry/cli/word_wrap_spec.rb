# frozen_string_literal: true

# WordWrap is mixed into a host. `wrap` is an instance method, not a module
# function, so the spec talks to a throwaway object that extends it — calling
# `Dry::CLI::WordWrap.wrap` would raise, and that is the API, not a gap.
RSpec.describe Dry::CLI::WordWrap do
  let(:host) { Object.new.extend(described_class) }

  describe "#wrap" do
    subject(:wrapped) { host.wrap(text, width, prefix:) }

    let(:text) { "hello" }
    let(:width) { 10 }
    let(:prefix) { "  " }

    it "returns text that already fits the width, unchanged" do
      expect(wrapped).to eq("hello")
    end

    it "returns an empty string for empty input" do
      expect(host.wrap("")).to eq("")
    end

    # scan starts on a non-whitespace character, so a paragraph of only
    # spaces is not a blank line: it is nothing.
    it "drops a paragraph that is only whitespace" do
      expect(host.wrap("   ")).to eq("")
    end

    describe "the default arguments" do
      it "wraps at 60 columns when no width is given" do
        text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu"

        expect(host.wrap(text)).to eq(
          "alpha beta gamma delta epsilon zeta eta theta iota kappa\nlambda mu nu"
        )
      end

      it "prefixes an original newline with two spaces when no prefix is given" do
        expect(host.wrap("first\nsecond")).to eq("first\n  second")
      end
    end

    context "when a sentence runs past the width" do
      let(:text) { "one two three four" }

      it "breaks at the last space that still fits" do
        expect(wrapped).to eq("one two\nthree four")
      end

      it "keeps every wrapped line at or under the width" do
        expect(wrapped.lines.map { |line| line.chomp.length }).to all(be <= width)
      end
    end

    context "when a single token is longer than the width" do
      let(:text) { "abcdefghij" }
      let(:width) { 5 }

      # A URL, a flag, a path: slicing it mid-character would make the
      # wrapped line uncopyable, so the token stays intact and overruns.
      it "leaves the token on one line rather than slicing it" do
        expect(wrapped).to eq("abcdefghij")
      end
    end

    context "when the text contains original newlines" do
      let(:text) { "hello\nworld" }
      let(:width) { 60 }

      it "rejoins those paragraphs with the prefix" do
        expect(wrapped).to eq("hello\n  world")
      end
    end

    context "with a custom prefix" do
      let(:text) { "hello\nworld" }
      let(:width) { 60 }
      let(:prefix) { ">>" }

      it "uses that string between original paragraphs" do
        expect(wrapped).to eq("hello\n>>world")
      end
    end

    # The prefix is the indent of a new paragraph, not of a wrapped
    # continuation. Word-wrap breaks join with a bare newline, so hanging
    # indent only appears where the author typed one.
    context "when a paragraph both wraps and follows another" do
      let(:text) { "one two three four\nfive six seven eight" }

      it "prefixes only the original newline, not the wrap breaks" do
        expect(wrapped).to eq("one two\nthree four\n  five six\nseven\neight")
      end
    end

    context "when a paragraph is blank" do
      let(:text) { "hello\n\nworld" }
      let(:width) { 60 }

      it "keeps the blank and still prefixes it" do
        expect(wrapped).to eq("hello\n  \n  world")
      end
    end

    # split(..., -1) keeps a trailing empty field, which becomes a prefixed
    # empty paragraph. Dropping that would eat the author's final newline.
    context "when the text ends with a newline" do
      let(:text) { "hello\n" }
      let(:width) { 60 }

      it "preserves it as a prefixed empty last paragraph" do
        expect(wrapped).to eq("hello\n  ")
      end
    end

    context "when the text starts with a newline" do
      let(:text) { "\nhello" }
      let(:width) { 60 }

      it "prefixes the first real paragraph" do
        expect(wrapped).to eq("\n  hello")
      end
    end

    context "when a paragraph begins with spaces" do
      let(:text) { "  hello world" }
      let(:width) { 20 }

      it "strips that leading whitespace, because wrapping starts on a word" do
        expect(wrapped).to eq("hello world")
      end
    end

    context "when wrapping at width 1" do
      let(:width) { 1 }

      it "puts each single-character word on its own line" do
        expect(host.wrap("a b c", 1)).to eq("a\nb\nc")
      end

      it "still refuses to split a longer token" do
        expect(host.wrap("abc", 1)).to eq("abc")
      end
    end
  end
end
