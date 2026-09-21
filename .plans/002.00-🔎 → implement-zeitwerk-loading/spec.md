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

---

## Research

### Current State of Zeitwerk in Agentilda

**Finding**: Zeitwerk is already implemented and fully operational. The code loads cleanly without errors, the CLI runs correctly, and all tests pass.

**Evidence:**
- `lib/agentilda.rb:11-37` (current state): Zeitwerk loader is instantiated, inflections configured, collapse/ignore directives in place, and `loader.setup` called.
- Test results: `bundle exec rspec` shows 1090 examples, 0 failures, 97.28% coverage (as of 2026-09-17).
- Load verification: `ruby -Ilib -e 'require "agentilda"; puts "loaded successfully"'` succeeds without errors.
- CLI smoke test: `bundle exec tilda --help` displays help correctly.

**Implication**: Task 1 in the spec ("Stabilize Zeitwerk Boot") describes work that is already complete. The actual refactoring work is Tasks 2-4 (moving files to domain namespaces and slimming CLI classes).

### Conflict Between Specification and REFACTOR.md

**Finding**: The specification assumes Zeitwerk needs to be stabilized, but the comprehensive refactoring document at `docs/REFACTOR.md` explicitly recommends **against** using Zeitwerk.

**Evidence from REFACTOR.md (lines 84-89)**:
> "For agentilda, **explicit require is recommended** because:
> - Current codebase already uses this pattern
> - Load order matters (domain before operations before execution)
> - SimpleCov integration depends on predictable loading
> - Easier to debug than autoloading"

**The Contradiction**:
1. Gemspec line 58: `spec.add_dependency "zeitwerk"` — Zeitwerk is a hard dependency
2. `lib/agentilda.rb:11-37`: Zeitwerk is already wired up and working
3. REFACTOR.md lines 76-89: Explicit require is the recommended approach, Zeitwerk is not recommended

**Current Reality**: Zeitwerk is present, used, and functional. The codebase achieves its goal (clean loading, correct behavior) through Zeitwerk today.

### Unresolved Design Decision: File Organization Scheme

**Finding**: REFACTOR.md identifies an unresolved contradiction (Risk R1, lines 356) between two proposed directory structures, but no decision has been recorded.

**The Two Schemes**:

1. **Command-centric grouping** (from REFACTOR.md introduction, lines 4-5):
   - Move helper classes next to their command
   - Example: `creator.rb` → `lib/agentilda/cli/create/creator.rb`
   - Shared helpers go to `lib/agentilda/shared/`

2. **Layer-based grouping** (from REFACTOR.md research section, lines 91-136):
   - Organize by architectural layer: models, queries, commands, execution, reporting, etc.
   - Example: `creator.rb` → `lib/agentilda/commands/creator.rb`
   - 8 module groups with clear dependency tiers

**What the Spec Assumes**: The spec uses layer-based language (lines 94-99 reference `lib/agentilda/tui/`, `lib/agentilda/plans/`, `lib/agentilda/runtime/`, etc.), which suggests the layer-based approach, but this has not been explicitly chosen.

**Why This Matters**: Choosing the wrong scheme means all file moves must be redone. REFACTOR.md (Risk R1 mitigation) explicitly requires settling this in "Phase 0" before any files are moved.

### Grouping Scheme Analysis

**Layer-based approach (favored by spec)**:
- **Pros**: Clean separation of concerns, industry-standard pattern (matches Devise, Sidekiq), natural dependency flow
- **Cons**: Deeper nesting (Agentilda::Tui::UI vs. Agentilda::UI), requires new module entry points
- **Dependency order**: ui → models → queries → commands → execution → reporting
- **Files affected**: All 40+ files under `lib/agentilda/`

**Command-centric approach (from introduction)**:
- **Pros**: Keeps commands and their tools colocated, mirrors existing cli/ structure
- **Cons**: Leaves shared classes unclear (shared/ vs. models/ vs. queries/), harder to navigate for non-CLI code
- **Structure**: cli/{create,run,unblock}/command.rb paired with helper files
- **Files affected**: CLI files primarily; other files need a secondary home

### Recommendation to Planning Phase

The specification assumes layer-based grouping but does not explicitly declare it. Before implementing Task 2, confirm that layer-based is the chosen scheme, or revise the spec's directory structure references to match the actual design decision.

### Corrections to Task 1

Task 1 ("Stabilize Zeitwerk Boot") is descriptively accurate as written (steps 1-6 are sound practices), but its problem statement is moot: the boot is already stable. Consider relabeling Task 1 as "Verify Zeitwerk Configuration" and making it:
- A verification step that confirms inflections, collapse, and ignore directives are complete
- A baseline capture of test results for comparison during later refactoring
- Confirmation that eager-loading works (Task 4, Step 1 already requires this)

### Open Questions for Yoda-Writer

1. **Is Zeitwerk the intended loader**, or should the specification be updated to reflect REFACTOR.md's recommendation for explicit require? (Currently both are true, which is inconsistent.)
2. **Which grouping scheme has been chosen** — layer-based (models, queries, commands, execution, reporting, etc.) or command-centric (cli/{cmd}/command.rb + shared/)?
3. **Should constant names change** during reorganization, or should compatibility aliases preserve the flat `Agentilda::*` namespace?
4. **When should the `--` separator for plan folder names** be introduced — as part of this work (Phase 1 in REFACTOR.md) or deferred to a separate plan?

### Findings, Conclusion & References

**Key Findings:**
- Zeitwerk is already a working dependency, not a blocker
- All baseline tests pass; code loads cleanly
- REFACTOR.md provides comprehensive analysis and recommends explicit require instead of Zeitwerk
- Two incompatible file organization schemes are proposed without a decided preference
- The specification aligns with the layer-based approach but does not explicitly declare this choice

**Conclusion:** The specification is ready to implement but should clarify (1) the file organization scheme choice, (2) whether Zeitwerk or explicit require is authoritative when they conflict, and (3) whether constant namespace flattening is acceptable. All three have been researched in REFACTOR.md but remain unresolved product decisions.

**References:**
- Current state verification: `lib/agentilda.rb` lines 11-37; `bundle exec rspec` output (2026-09-17); test coverage badge
- REFACTOR.md: Lines 84-89 (loader recommendation), 91-136 (proposed layer-based structure), 356-357 (Risk R1 unresolved choice)
- Architecture documentation: `CLAUDE.md` Layout section (current flat structure authority)
- Gemspec: Line 58 confirms Zeitwerk as runtime dependency

> [!NOTE]
>
> [2026-09-17 01:05:10 PM PDT] [ agent: leah-researcher   status: Completed, round 1 ]
> [2026-09-17 01:05:10 PM PDT] [ next: yoda-writer ]

> [!NOTE]
>
> [2026-09-17 01:32:33 PM PDT] [ agent: leah-researcher   status: **Interrupted, round 1 (harness died)** ]

> [!NOTE]
>
> [2026-09-17 01:32:50 PM PDT] [ agent: yoda-writer   status: Started, round 1 ]
> [2026-09-17 01:33:10 PM PDT] [ agent: yoda-writer   status: Interrupted, round 1 (control file showed INTERRUPT before any spec work began) ]

> [!NOTE]
>
> [2026-09-17 01:35:47 PM PDT] [ agent: yoda-writer   status: **Interrupted, round 1 (harness died)** ]
