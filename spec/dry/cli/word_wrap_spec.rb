# frozen_string_literal: true

module Dry
  class CLI
    # WordWrap is mixed into a host. `wrap` is an instance method, not a module
    # function, so the spec talks to a throwaway object that extends it —
    # calling `Dry::CLI::WordWrap.wrap` would raise, and that is the API, not
    # a gap.
    #
    # The shape it produces is a hanging indent for a help table: the first
    # line starts wherever the caller put it, and every line the wrapping
    # invents is pushed out by `prefix` to sit under it. An author's own
    # newline is not a wrap, so it starts a fresh paragraph at column zero and
    # takes no prefix. That is why a two-line `desc` still falls to the left
    # margin in `agentilda -h`.
    RSpec.describe WordWrap do
      let(:host) { Object.new.extend(::Dry::CLI::WordWrap) }

      describe "#wrap" do
        subject(:wrapped) { host.wrap(text, width: width, prefix: prefix) }

        let(:text) { "hello" }
        let(:width) { 10 }
        let(:prefix) { "  " }

        it "returns text that already fits the width, unchanged" do
          expect(wrapped).to eq("hello")
        end

        it "returns an empty string for empty input" do
          expect(host.wrap("")).to eq("")
        end

        # The scan starts on a non-whitespace character, so a paragraph of only
        # spaces is not a blank line: it is nothing.
        it "drops a paragraph that is only whitespace" do
          expect(host.wrap("   ")).to eq("")
        end

        # `wrap` is the name the callers use; `wrap_description` is the name it
        # was born with. Pinning the alias stops a rename from quietly leaving
        # half the codebase calling a method that no longer exists.
        it "is an alias of #wrap_description" do
          expect(host.method(:wrap).original_name).to eq(:wrap_description)
        end

        describe "the default arguments" do
          it "wraps at 55 columns when no width is given" do
            text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu"

            expect(host.wrap(text)).to eq(
              "alpha beta gamma delta epsilon zeta eta theta iota\n  kappa lambda mu nu"
            )
          end

          it "indents a wrapped line by two spaces when no prefix is given" do
            expect(host.wrap("one two three four", width: 10)).to eq("one two\n  three four")
          end
        end

        context "when a sentence runs past the width" do
          let(:text) { "one two three four" }

          it "breaks at the last space that still fits and indents what follows" do
            expect(wrapped).to eq("one two\n  three four")
          end

          # The prefix is on top of the width, not inside it, so the budget has
          # to be measured on the text the indent is holding up.
          it "keeps every line at or under the width once the indent is taken off" do
            expect(wrapped.lines.map { |line| line.chomp.delete_prefix(prefix).length })
              .to all(be <= width)
          end
        end

        context "when a single token is longer than the width" do
          let(:text) { "abcdefghij" }
          let(:width) { 5 }

          # A URL, a flag, a path: slicing it mid-token would make the wrapped
          # line uncopyable, so the token stays intact and overruns.
          it "leaves the token on one line rather than slicing it" do
            expect(wrapped).to eq("abcdefghij")
          end
        end

        context "with a custom prefix" do
          let(:text) { "one two three four" }
          let(:prefix) { ">>" }

          it "uses that string as the hanging indent" do
            expect(wrapped).to eq("one two\n>>three four")
          end
        end

        context "when the text contains original newlines" do
          let(:text) { "hello\nworld" }
          let(:width) { 60 }

          it "starts a new paragraph at column zero, with no prefix" do
            expect(wrapped).to eq("hello\nworld")
          end
        end

        context "when a paragraph both wraps and follows another" do
          let(:text) { "one two three four\nfive six seven eight" }

          it "indents the wrap breaks and not the author's newline" do
            expect(wrapped).to eq("one two\n  three four\nfive six\n  seven\n  eight")
          end
        end

        context "when a paragraph is blank" do
          let(:text) { "hello\n\nworld" }
          let(:width) { 60 }

          it "keeps the blank line, unindented like any other paragraph" do
            expect(wrapped).to eq("hello\n\nworld")
          end
        end

        # split(..., -1) keeps a trailing empty field, so the author's final
        # newline survives instead of being eaten.
        context "when the text ends with a newline" do
          let(:text) { "hello\n" }
          let(:width) { 60 }

          it "preserves it" do
            expect(wrapped).to eq("hello\n")
          end
        end

        context "when the text starts with a newline" do
          let(:text) { "\nhello" }
          let(:width) { 60 }

          it "preserves the empty first paragraph" do
            expect(wrapped).to eq("\nhello")
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

          it "puts each single-character word on its own indented line" do
            expect(host.wrap("a b c", width: 1)).to eq("a\n  b\n  c")
          end

          it "still refuses to split a longer token" do
            expect(host.wrap("abc", width: 1)).to eq("abc")
          end
        end
      end
    end
  end
end
