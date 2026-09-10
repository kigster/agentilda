module Agentilda
  # Names dry-cli can resolve, so a leading word that is not one of these is a
  # typo and must fail rather than quietly run something else.
  # TODO: get this list from Dry::CLI
  KNOWN = %w[create new c list-plans status st resync docs worktree version --version -v -h --help].freeze

  class Launcher
    include ::Dry::CLI::Banner::ColorMethods

    attr_accessor :argv,
      :stdin,
      :stdout,
      :stderr,
      :kernel

    def initialize(argv,
      stdin = $stdin,
      stdout = $stdout,
      stderr = $stderr,
      kernel = Kernel)
      self.argv   = argv
      self.stdin  = stdin
      self.stdout = stdout
      self.stderr = stderr
      self.kernel = kernel

      # Bare `agentilda` prints its help. It used to print the plan table, which
      # meant the one command that reads a tree was also the one you got by accident.
      @argv = argv.empty? ? %w(-h) : argv

      # `run --push-pr` takes an OPTIONAL part letter: bare means "continue this
      # plan"s sequence", `--push-pr C` means "use C". dry-cli has no optional-value
      # option, so the bare form is filled in here rather than made to look like a
      # mistake.
      #
      # Scoped to `run`, and to the long spelling when it is not. This rewrote every
      # `-p` in every command for a while, which quietly turned
      # `linear import TAX -p "Some Project"` into `-p auto "Some Project"` — the
      # option took "auto" and the project name became a stray argument. A global
      # rewrite of a one-letter flag will collide with the next command that wants
      # it; this one collided within the week.
      return unless argv.first == "run"

      argv = argv.each_with_object([]) do |token, out|
        out << token
        next unless ["--push-pr", "-p"].include?(token)

        following = argv[argv.index(token) + 1]
        out << "auto" unless following&.match?(/\A[A-Z]\z/)
      end
    end

    def execute!
      no_color = %w[--no-color -C].intersect?(argv)
      Dry::CLI::Banner.disable_color! if no_color
      # # dry-cli prints the command list for an unresolved command and exits 1, and
      # it treats a bare `--help` as exactly that. Asking for help is not a failure,
      # so the status is forced back to 0 for the help forms only.
      help = %w[-h --help help].intersect?(argv) && argv.first[0] == "-"
      ProgramBanner.banner if help
      code = 0
      Dry::CLI.new(::Agentilda::CLI).call(arguments: help ? [] : argv)
    rescue StandardError
      warn red("Error: #{$!.message}")
      code = 1
    ensure
      kernel.exit(code)
    end
  end

  module ProgramBanner
    extend ::Dry::CLI::Banner::ColorMethods

    def self.banner
      puts %(
      #{yellow.bold("agentilda")}
        #{blue("Agentic Specification-Driven Development")} #{green("v#{Agentilda::VERSION}")}

        This is the key executable that facilitates Agentic Flow:

        #{green.bold("spec → plan → build → review → tune/fix → approve")}

        For now the final merge and deploy is manual. It also provides sync
        of the .plans folders with Github PRs and Linear Issues. See the file
        #{::Agentilda::PROJECT_ROOT}/context/workflow.md for the details.

      #{yellow.bold("GLOBAL FLAGS")}
        -h, --help        Show this help message and exit
        -C, --no-color    Disable color output

    ).gsub(/^ {6}/, "").strip
      puts
    end
  end
end
