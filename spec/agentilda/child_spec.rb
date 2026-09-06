# frozen_string_literal: true

RSpec.describe Agentilda::Child do
  it "streams the child's stdout and reports its exit" do
    child = described_class.spawn(["ruby", "-e", "print 'a'; $stdout.flush; print 'b'"])
    chunks = []
    child.each_chunk { |text| chunks << text }
    status = child.wait
    aggregate_failures do
      expect(chunks.join).to eq("ab")
      expect(status).to be_success
      expect(child.pid).to be_a(Integer)
    end
  end

  it "kills a process that will not end on its own" do
    child = described_class.spawn(["ruby", "-e", "sleep 30"])
    expect(child).to be_alive
    child.kill
    status = child.wait
    aggregate_failures do
      expect(status).not_to be_success
      expect(child).not_to be_alive
    end
  end

  it "runs in the directory asked for" do
    Dir.mktmpdir do |dir|
      child = described_class.spawn(["ruby", "-e", "print Dir.pwd"], chdir: dir)
      out = +""
      child.each_chunk { |text| out << text }
      child.wait
      expect(File.realpath(out)).to eq(File.realpath(dir))
    end
  end
end
