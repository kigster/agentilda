# frozen_string_literal: true

RSpec.describe "agentilda api", :tree do
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

  let(:output) { File.join(plans_root, "..", "site") }

  def plan_with(ordinal, slug, contents)
    plans do |t|
      folder = t.plan ordinal, :building, slug, files: { "spec.md" => spec_body, "plan.md" => "# P" }
      File.write(File.join(folder, Agentilda::OpenAPI::FILENAME), contents) if contents
    end
  end

  def run(command, **)
    out = CapturedStream.new
    err = CapturedStream.new
    status = 0

    original_out, original_err = $stdout, $stderr
    $stdout, $stderr = out, err
    begin
      command.call(dir: plans_root, **)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_out, original_err
    end

    [strip_ansi(out.string), strip_ansi(err.string), status]
  end

  def list(**) = run(Agentilda::CLI::API::List.new, **)

  def docs(**) = run(Agentilda::CLI::API::Docs.new, **)

  describe "list" do
    it "says so, on STDERR, when no plan carries one" do
      plan_with("001.00", "no-http", nil)
      out, err, status = list

      aggregate_failures do
        expect(out).to be_empty
        expect(err).to include("No plan carries")
        expect(status).to eq(0)
      end
    end

    it "names each plan that does, on STDOUT, where the deliverable goes" do
      plan_with("001.00", "returns-api", valid)
      out, _err, status = list

      aggregate_failures do
        expect(out).to include("001.00", "Returns")
        expect(status).to eq(0)
      end
    end

    it "says what is wrong with one that is not usable, and exits non-zero" do
      plan_with("001.00", "returns-api", "openapi: 3.1.0\n")
      out, _err, status = list

      aggregate_failures do
        expect(out).to include("has no `paths:` key")
        expect(status).to eq(65)
      end
    end
  end

  describe "docs" do
    before { plan_with("001.00", "returns-api", valid) }

    it "writes an index naming every plan that has a document" do
      docs(output:)
      expect(File.read(File.join(output, "index.html"))).to include("001.00", "Returns")
    end

    it "writes a page per plan, pointed at Redoc" do
      docs(output:)
      expect(File.read(File.join(output, "001.00.html"))).to include("<redoc spec-url=\"001.00.yaml\">", "redoc@")
    end

    # Copied rather than linked, so the site is one directory that can be
    # opened, served or moved without the plans beside it.
    it "copies the document in beside its page" do
      docs(output:)
      expect(File.read(File.join(output, "001.00.yaml"))).to eq(valid)
    end

    it "says where it wrote, and how much" do
      _out, err, = docs(output:)
      expect(err).to include("Wrote 1 document")
    end

    it "leaves out a document that is not usable rather than rendering a broken page" do
      plan_with("002.00", "broken-api", "openapi: 3.1.0\n")
      docs(output:)

      aggregate_failures do
        expect(File).to exist(File.join(output, "001.00.html"))
        expect(File).not_to exist(File.join(output, "002.00.html"))
      end
    end

    it "refuses rather than writing an empty site" do
      FileUtils.rm_f(Dir.glob(File.join(plans_root, "*", Agentilda::OpenAPI::FILENAME)))
      _out, err, status = docs(output:)

      aggregate_failures do
        expect(err).to include("No plan carries a usable")
        expect(status).to eq(65)
        expect(File).not_to exist(File.join(output, "index.html"))
      end
    end

    # A title comes out of a plan's own document, which is written by an
    # agent, so it is not ours to trust with the page it goes into.
    it "escapes a title rather than letting it into the markup" do
      plans { |t| t.plan "003.00", :building, "sneaky", files: { "spec.md" => spec_body, "plan.md" => "# P" } }
      File.write(File.join(plans_root,
        Dir.children(plans_root).find { |d| d.start_with?("003") },
        Agentilda::OpenAPI::FILENAME),
        "openapi: 3.1.0\ninfo:\n  title: \"<script>alert(1)</script>\"\npaths: {}\n")
      docs(output:)

      aggregate_failures do
        expect(File.read(File.join(output, "index.html"))).to include("&lt;script&gt;")
        expect(File.read(File.join(output, "index.html"))).not_to include("<script>alert")
      end
    end
  end
end
