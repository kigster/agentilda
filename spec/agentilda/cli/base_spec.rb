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
end
