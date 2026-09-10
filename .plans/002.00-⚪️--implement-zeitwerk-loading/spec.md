# Zeitwerk Domain Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agentilda load cleanly through Zeitwerk while moving business logic toward domain-owned namespaces and leaving CLI classes as thin adapters.

**Architecture:** First make the current tree Zeitwerk-compatible with local third-party requires and explicit acronym inflections. Then introduce domain namespace directories without changing behavior, move constants in low-risk batches with compatibility aliases where needed, and finally slim fat command classes into workflow objects.

**Tech Stack:** Ruby 4.0.6, Bundler, Zeitwerk, dry-cli, dry-monads, RSpec.

**Spec:** Conversation design approved on 2026-09-10.

## Global Constraints

- Work only inside `/Users/kig/github/kigster/agentilda`.
- Preserve existing behavior while moving files.
- Use local file-level requires for third-party gems; Zeitwerk only owns Agentilda constants.
- Keep `Agentilda::CLI::*` as command adapters: option parsing, domain call, output, exit.
- Keep public constants working during migration with compatibility aliases when practical.
- Do not start the TUI redesign until loader and base functionality are green.

---

### Task 1: Stabilize Zeitwerk Boot

**Files:**
- Modify: `lib/agentilda.rb`
- Modify: `lib/agentilda/linear.rb`
- Modify: files that directly reference third-party constants
- Test: `spec/agentilda/load_spec.rb`

**Interfaces:**
- Produces: `require "agentilda"` succeeds without eager-loading every domain file manually.
- Produces: `bundle exec tilda` reaches CLI help behavior.

- [ ] **Step 1: Write the failing load test**

```ruby
# spec/agentilda/load_spec.rb
require "open3"

RSpec.describe "agentilda load path" do
  it "loads the gem entrypoint without eager-load NameError failures" do
    output, status = Open3.capture2e(
      RbConfig.ruby,
      "-Ilib",
      "-e",
      "require 'agentilda'; puts 'loaded'"
    )

    expect([status.success?, output]).to eq([true, "loaded\n"])
  end
end
```

- [ ] **Step 2: Run the executable to capture the current failure**

Run: `eval "$(rbenv init -)" && bundle exec tilda`

Expected before the fix: a `NameError` or `Zeitwerk::NameError`.

- [ ] **Step 3: Move third-party requires to owning files**

Add direct requires such as `dry/monads`, `tty/command`, `unicode/display_width`, `fileutils`, `shellwords`, and `parallel` to the files that use those constants.

- [ ] **Step 4: Fix acronym inflections**

Configure Zeitwerk inflections in `lib/agentilda.rb` for constants Ruby code already exposes:

```ruby
loader.inflector.inflect(
  "api" => "API",
  "cli" => "CLI",
  "github" => "GitHub",
  "ui" => "UI"
)
```

- [ ] **Step 5: Remove manual require loops**

Delete the component loop in `lib/agentilda.rb` and the part loop in `lib/agentilda/linear.rb` once all constants autoload correctly.

- [ ] **Step 6: Verify**

Run: `eval "$(rbenv init -)" && bundle exec ruby -Ilib -e 'require "agentilda"; puts "loaded"'`

Run: `eval "$(rbenv init -)" && bundle exec tilda`

Expected: both commands succeed.

### Task 2: Introduce Domain Namespaces Without Behavioral Changes

**Files:**
- Modify/create: `lib/agentilda/tui/**`
- Modify/create: `lib/agentilda/plans/**`
- Modify/create: `lib/agentilda/runtime/**`
- Modify/create: `lib/agentilda/integrations/**`
- Modify/create: `lib/agentilda/agents/**`
- Modify/create: `lib/agentilda/resync/**`

**Interfaces:**
- Produces: domain constants under their new namespace.
- Preserves: existing top-level constants through aliases during transition.

- [ ] **Step 1: Move low-risk UI files**

Move display-only classes and modules first: `UI`, `Screen`, `Console`, `Board`, `Keyboard`, `Clock`, `ProgressLog`, and `Tally`.

- [ ] **Step 2: Move integration wrappers**

Move `GitHub` to `Agentilda::Integrations::GitHub` and Linear files to `Agentilda::Integrations::Linear`, keeping aliases for current callers.

- [ ] **Step 3: Move plan model and document files**

Move `Tree`, `Feature`, `Subject`, `Ordinal`, `Status`, `StateFile`, `Frontmatter`, `Markdown`, `Ledger`, `PullRequests`, `Creator`, `Brief`, `Documentation`, `Diagram`, and `Index`.

- [ ] **Step 4: Move runtime orchestration**

Move `Runner`, `Dispatcher`, `Executor`, `Child`, `Transcript`, `Control`, `Mailbox`, `Unblocker`, `Worktree`, and `Publisher`.

- [ ] **Step 5: Move agent roster files**

Move `Agent`, `Agents`, `Roster`, and `Viewer` under `Agentilda::Agents`.

- [ ] **Step 6: Move resync domain**

Move `Resync::Dirs`, `Resync::Prs`, and `Adoption` under a coherent resync namespace.

- [ ] **Step 7: Verify after each batch**

Run the focused specs for files moved in the batch, then run `bundle exec tilda`.

### Task 3: Slim Command Classes Into Adapters

**Files:**
- Modify: `lib/agentilda/cli/create/create.rb`
- Modify: `lib/agentilda/cli/run/run.rb`
- Modify: `lib/agentilda/cli/unblock/unblock.rb`
- Modify: `lib/agentilda/cli/resync/subcommands/prs.rb`
- Create: workflow objects in the relevant domain namespace

**Interfaces:**
- Produces: command classes that parse options, call a workflow, print results, and exit.
- Produces: workflow objects returning explicit result values, preferably `Dry::Monads::Result`.

- [ ] **Step 1: Extract create workflow**

Move seed parsing, PR fetching, spec drafting, folder settling, and next-step calculation out of `CLI::Create`.

- [ ] **Step 2: Extract run workflow**

Move agent filtering, plan scoping, runtime setup, state-file setup, runner construction, and run summary generation out of `CLI::Run`.

- [ ] **Step 3: Extract unblock workflow**

Move target resolution reporting, preflight rendering, outcome reporting, footer rendering, and exit status calculation out of `CLI::Unblock`.

- [ ] **Step 4: Extract resync PR presentation**

Move change reporting and adoption summaries out of `CLI::Resync::Prs`.

- [ ] **Step 5: Verify**

Run all CLI specs and the executable smoke test.

### Task 4: Full Verification

**Files:**
- Modify only if verification exposes behavior-preserving fixes.

**Interfaces:**
- Produces: green RSpec suite or a clearly documented external blocker.
- Produces: `bundle exec tilda` works.

- [ ] **Step 1: Run loader verification**

Run: `eval "$(rbenv init -)" && bundle exec ruby -Ilib -e 'require "agentilda"; Zeitwerk::Loader.eager_load_all; puts "eager loaded"'`

- [ ] **Step 2: Run CLI smoke**

Run: `eval "$(rbenv init -)" && bundle exec tilda`

- [ ] **Step 3: Run tests**

Run: `eval "$(rbenv init -)" && bundle exec rspec`

- [ ] **Step 4: Document remaining work**

If the TUI redesign is still pending, leave it out of this refactor and capture it as the next task.
