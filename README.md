# The Agentilda Ruby Gem

This gem implements an agentic workflow using five specialized agents defined in the `./agents` directory.

The best resource that describes it in detail is the result of running `tilda docs -o <file>` command, or the file [docs/WORKFLOW.md](docs/WORKFLOW.md).

The gem offers a CLI command `tilda` (as well as `agentilda`) that performs a slew of commands aimed at producing, updating, keeping in sync any project's root directory `.plans`, that will initially contain just the `spec.md` and pull requests documents in the `.plans`, and drives a team of specialist agents over them. The agents implement the following workflow:

```
# Hppy path
⚪️ New ──▶ 
    🔎 Researched ──▶ 
        ⭐️ Planned ──▶ o
            🟡 Building ──▶ 
                🎨 Building UI ──▶ 
                    🟢 Ready for Review ──▶ 
                    👀 In Review ──▶ 
                        ✅ Approved
```

## Agents

There are a total of six individual agents that are named after the "StarWars®" theme. But before any of them can do their work you should probably drop a specification into one of the folders under `.plans` with the name of your feature. You do this with the help of the script `bin/create-plan-folder`:

```bash
bin/create-plan-folder -h

USAGE:
  create-plan-folder [-D <dir>] <status> <topic words...>

WHERE:
  -D <dir>   Enclosing directory (default: .)

DESCRIPTION:
  Status is a name or the emoji itself:

  white  | spec               ⚪️   spec.md only, not yet planned
  blue   | planned  | plan    🔵   spec.md + plan.md
  yellow | open     | wip     🟡   PR raised, not yet merged
  green  | done               🟢   all PRs merged
  red    | declined           🔴   decided never
  hole   | blocked            ⭕️   needs a human decision (write blockers.md)
  brown  | later    | defer   🟤   deliberately deferred (state the trigger)
  purple | merged             🟣   PR-level status; see note below

EXAMPLES:
  create-plan-folder spec implement login and logout functionality
  create-plan-folder [ -D docs/plans ] spec implement agentic workflow CLI
```

If you execute the two examples above ( without overriding the enclosing directory), you'll end up with `.plans` folder with the following directories inside:

```
.plans/001-⚪️--implement-login-and-logout-functionality
.plans/002-⚪️--implement-agentic-workflow-cli
```

The idea behind these colored circles is they effectively represent the state the folder is currently in, and make it easy to visually identify problematic stories, blocked stories, and so on.

The gem implements a state machine internally using the `aasm` gem. The directories follow almost the entire graph, which you can review by running `tilda states`.

Speaking of running `tilda` , a help screen, and then we'll move onto the agents.

![help-screen](./.img/help.avif)

### Agents — Who Are They?

-
- `leah-researcher.md` is the first one to graresearch,
- then a written specification,
- then a plan,
- then a frontend end, backend,
- submit PR,
- and perform an adversarial review.

Install the gem with `gem install agentilda` and then run `tilda -h` for more options. It's also recommended to add command completion to your shell. Eg, for zsh:

```bash
# ~/.zshrc
grep -q agentilda "${HOME}"/.zshrc || echo 'eval "$(agentilda completion zsh)"' >> "${HOME}/.zshrc"
```

______________________________________________________________________

## The Workflow

```bash
just              # pick a recipe
just test         # rspec
just lint         # standardrb (reports; never rewrites)
just format       # standardrb --fix, then mdformat
just ci           # lint + coverage
just doctor       # what bin/install would copy and link, touching nothing
```

CircleCI runs the suite and the linter, and asserts `bin/setup` reaches a fixed point by running it twice and diffing — the bug it exists to prevent is drift going unnoticed, not a first run failing.

Nothing here installs anything. The other half of the repository, the part that decides which skills, plugins and coding agents a machine should have, is documented in [the top-level README](../README.md).

```bash
agentilda --help          # or `tilda`, a symlink beside it
agentilda states          # the state machine, as a diagram
agentilda list-plans      # every plan, its state, its pull requests
```

______________________________________________________________________

## Spec → Plan → Build

This repo comes with an opinionated and formalized workflow for designing product features and moving forward.

Every project keeps its plans in a `.plans/` directory. Each feature gets one folder, and **the folder's name is its state**.

```
.plans/000.00-⚪️--initial-spec
       001.00-✅--dev-foundation
       001.01-✅--schedule-k1-backfill   ← shipped between 001 and 002,
       002.00-⭐️--tenancy-households        specified afterwards
```

Three phases, each with a file that proves it happened:

| Phase     | State    | The file that proves it |
| :-------- | :------- | :---------------------- |
| **spec**  | ⚪️ New   | `spec.md`               |
| **plan**  | ⭐️ Ready | `plan.md`               |
| **build** | 🟡 → ✅  | `pull-requests.md`      |

A folder may not claim a phase whose file is missing. That is not a convention anyone has to remember — it is a state machine with guards, and the tool refuses transitions whose requirements do not hold.

The canonical folder spelling is `NNN.MM-<emoji>--<slug>`, with **two dashes after the emoji**: an emoji renders two cells wide and visually swallows a single dash beside it. Folders named with the older single dash still decode, and `resync dirs` renames them to the canonical form on contact.

### The lifecycle, step by step

A feature moves through five specialists, one state at a time, never two at once, and never further than its own documents currently justify:

1. **⚪️ New.** `agentilda create tax rule dsl` mints `.plans/003.00-⚪️--tax-rule-dsl/`. For a genuinely new feature it also scaffolds `spec.md` with a title and four fixed headings (*What we are trying to achieve*, *Why it matters*, *What already exists*, *What research needs to settle*), makes a best-effort attempt at them from what the project already has on disk, and opens it. You finish the brief by hand.
1. **🔎 Researched.** `leah-researcher` fans work out across parallel sub-agents and appends spec.md's `## Research` chapter: themes, findings, licensing, a closing `### Findings, Conclusion & References`. Nobody else may write that heading. It *is* the state transition, so an empty one seeds a lie.
1. **⭐️ Planned.** `yoda-writer` turns the brief plus the research into a complete specification: Goal, Non-Goals, In/Out of scope, Open questions, Conclusion. Or it writes `blocked.md` instead, when a question is a human's to answer, not a guess. `palpatine-planner` then decomposes the finished spec into `plan.md`'s non-overlapping work units, sized for independent sub-agents.
1. **🟡 Building → 🎨 Building UI.** `luke-backend` writes `implementation-plan.md` first — the interfaces the front end will call, their shapes, their errors, who owns which files, and the test that will prove the halves are joined — then builds the back end: schema, domain, API, source and tests, no commits. Units that own disjoint files are built as one concurrent wave rather than in series. It hands off once no back-end unit is left.
1. **🎨 Building UI → 🟢 Ready for Review.** `rey-frontend` opens `implementation-plan.md`, builds the interface against the API that now exists rather than the one the spec imagined, and runs the integration test named there — a front end green against a stub and a back end green against a test client are two passing suites and no working feature. It loads the design skills as it goes and fans out over independent units. A plan with no front-end work says so and passes through. The pull request titled `[003.00] …` opens here, for what both halves built.
1. **👀 In Review → 🔴 Changes Requested, or ✅ Approved & Merged.** `hansolo-reviewer` reads the diff against the plan and either requests changes (back to 🟢 once addressed) or approves. Nothing merges automatically: approving is reversible and attributable, merging changes a branch everyone else builds on, and that line is enforced in code, not just in the prompt.

Off to the side, at any point: ⭕️/🅱️ **Blocked** (an engineering or product decision only a human can make) and ☢️ **Deferred** or ❌ **Discarded**. Blocked plans are never assigned to an agent by the loop; one that could move them would make the states meaningless. `agentilda states` draws the whole machine, every legal transition included.

Blocks drain by hand, and in pieces. Answers are written into `blocked.md` as they arrive, and `agentilda unblock 003 --commit` hands the folder to `lando-broker`, which folds each answered question into the document it was stopping (`spec.md` for what and why, `plan.md` for how and in what order), deletes it, and deletes the file once nothing is left. `blocked.md` holds open questions and nothing else, so the pass that empties it is the pass that lets the folder out of ⭕️. Three answers out of four is a normal run: the plan stays blocked on the fourth, which is the truth.

### How you invoke it

Both paths end up running the same `exe/agentilda` binary, which `tilda` is a symlink to. The question is just who's driving.

- **Directly, from a terminal or a script**: `agentilda create …`, `agentilda run --commit`, etc. (see "Day to day" below). This is the whole tool; nothing about it requires Claude.
- **As a Claude Code slash command**, via `src/commands/*.md` (`/plan-create`, `/plan-research`, `/plan-run`, `/plan-status`, `/plan-resync-dirs`, `/plan-resync-prs`, `/plan-docs`, `/plan-insert`, `/plan-linear-import`). Each one is a thin wrapper around the same binary, plus the guardrails that erode if left to memory. `/plan-create` won't seed a `## Research` heading or write Goals ahead of the research. `/plan-run` insists you confirm scope, `--commit`, and parallelism before it runs anything.

Use the slash commands inside a Claude Code session, since they carry the constraints. Use the binary directly for scripting, CI, or any other agent. `skills/` and `agents/*.md` are a separate concern: those are Claude's general skill/specialist library, not part of invoking `agentilda` itself.

**The full conventions are generated, never hand-written:**

```bash
agentilda docs -o context/workflow.md
```

The status vocabulary and transition table live in `lib/agentilda/status.rb` and `state_machine.rb`, the numbering rules in `ordinal.rb`, and the document is derived from all three. This system previously had three hand-maintained copies of that table and they disagreed — the folder-creation script could mint statuses the reader did not recognise, and could not mint six that it required.

### The number is an identity

`NNN.MM`, always. `000.00` is the first plan of a project; after that it is the highest major plus one. `MM` is `00` for an ordinary plan and `01`–`99` for a **retroactive** one — work that shipped with no specification and was documented afterwards.

`001.01` is a *sibling of 001 that arrived later*, not a part of it.

The number is set once and never changes: branch names, pull request titles and every `pull-requests.md` join on it, and renumbering breaks all of them silently. `status` reports any number claimed by two folders.

______________________________________________________________________

## Day to day

```bash
agentilda create tax rule dsl          # 003.00-⚪️--tax-rule-dsl
agentilda create --from notes/dsl.md   # named by the file's frontmatter title; its body opens spec.md
agentilda create --after 002 k1 sync   # 002.01-⬜️--k1-sync (retroactive)
agentilda list-plans                   # the table; exits 1 if a name lies
agentilda resync dirs                  # folder emoji vs folder contents
agentilda resync prs                   # [NNN.MM] prefixes on PR titles
agentilda linear import --prefix TAX   # the plans, as Linear projects and issues
agentilda docs                         # regenerate the conventions
agentilda states                       # the state machine, as a diagram
agentilda run --commit --plan 003      # hand specific plans to the agents
```

**Everything that writes is a dry run until `--commit`.** Folder names and pull request titles are things other people join on; changing one silently is how work ends up filed under a plan that did not do it.

### `resync dirs`

Renames folders whose emoji their contents do not support — a ⚪️ that has grown a `plan.md` becomes ⭐️; a ✅ with an open pull request is walked back to 🟡. It records *why* for each rename, and it is idempotent.

It will never reclassify between ⭕️ Blocked and 🅱️ Product Blocked. Those share an invariant on purpose — both mean "a human must decide" — and only the folder name records *which* human.

### `resync prs`

Reads the branch name first, then the diff, and only when the diff touches exactly one plan. Anything ambiguous is **reported and never edited**, even with `--commit`. A pull request that resolves to no plan is proposed as `[dev]` and marked *assumed*, because asserting "this implements no specification" is the author's call, not the tool's. Where even that cannot be asserted the marker is `[none]`, which claims nothing and leaves the question open.

Requires `gh`. If `gh` prints nothing while exiting zero — the signature of an invalid `GH_TOKEN` shadowing a working keyring login — the tool says so rather than reporting an empty repository.

### `linear import`

Each plan folder becomes a Linear **project**; each `PR-n` work unit inside its `plan.md` becomes an **issue** in that project, carrying the pull requests that implement it. `--prefix` is the team key — the part before the dash in `TAX-41` — and Linear assigns the numbers itself.

It runs **one way**. The folder is the source of truth and Linear is a window onto it; nothing typed into Linear travels back to `.plans`.

The whole decision is made from disk, which is what makes the dry run worth reading: it is not a description of what a push would do, it is the object the push consumes. Each plan then records what it owns in a committed `linear.md`, and that record — a fingerprint per issue — is what makes the second run cost nothing.

Two transports apply the same plan:

```bash
agentilda linear import --prefix TAX --commit        # needs LINEAR_API_KEY
agentilda linear import --prefix TAX --format json   # for /plan-linear-import, over MCP
```

The JSON is shaped as the Linear MCP server's own `save_project` and `save_issue` arguments, so both transports read one contract and cannot drift apart.

Two states — 💩 Scrapped by Review and 😱 Rolled Back — are **not imported at all**. Where they belong on a board is a statement about how a team works, not about the plan, and this tool does not know that. It says so and skips them; deciding is one entry in `Linear::PLACEMENTS`.

A pull request that names no work unit its plan declares is likewise **reported, never guessed at** — filing it under the nearest unit would bury exactly the discrepancy worth seeing.

______________________________________________________________________

## The multi-agent harness

Specialists are defined in `agents/*.md`. The frontmatter routes them (`handles:`/`advances_to:` are exactly what `agentilda run` reads to decide who takes a plan); the body is the prompt. An agent's `model:` picks what it runs on; `run --model NAME` overrides that for every agent in the run, typed flag beating declared frontmatter. An agent's `timeout:` does the same for its clock; `leah-researcher` declares 1200 because research has no natural stopping point and will otherwise fill whatever it is given.

| Agent               | Handles | Advances to | Does                                                                    |
| :------------------ | :------ | :---------- | :---------------------------------------------------------------------- |
| `leah-researcher`   | ⚪️      | 🔎          | fans out parallel research, writes spec.md's `## Research` chapter      |
| `yoda-writer`       | 🔎, 🕰️  | ⭐️          | writes Goal/Non-Goals/Conclusion, or blocks with numbered questions     |
| `palpatine-planner` | ⭐️      | 🟡          | decomposes the spec into `plan.md`'s concurrent work units              |
| `luke-backend`      | 🟡, 🔴  | 🎨          | writes the contract, then builds the back end: data, domain, API, tests |
| `rey-frontend`      | 🎨      | 🟢          | builds the interface against that contract, and proves the halves join  |
| `hansolo-reviewer`  | 🟢, 👀  | ✅          | adversarial review; requests changes or approves, never merges          |
| `lando-broker`      | ⭕️, 🅱️  | ⭐️          | folds answered blocks into spec.md/plan.md; never invoked by the loop   |

```bash
agentilda run                              # dry run: who would take what
agentilda run --commit                     # one git worktree per plan, in parallel
agentilda run --commit -j 4                # …four at a time
agentilda run --isolation shared           # one tree, serial; no git needed
agentilda run --commit --plan 003,005.01   # only these plans, see below
agentilda run --commit --timeout 1800      # give slow agents 30 minutes, not the default 15
agentilda run --commit --agent yoda-writer --prompt "Rework the risks section first"
agentilda run --commit --skip hansolo-reviewer   # everyone but the reviewer; its plans wait
agentilda run --commit --model opus        # this model for every agent, whatever each declares
agentilda run --commit --max-tokens 200000 # per-invocation budget, stated to the agent and enforced
agentilda unblock 003                      # what 003 is still waiting on a human for
agentilda unblock 003 --commit             # fold in whatever has been answered
agentilda states                           # the whole machine, as a diagram
```

### Handing off several plans at once with `--plan`

`run` with no `--plan` loops the **whole tree**. That is exactly wrong right after a batch step creates several plans at once: a bare `run` per `create` starts N overlapping whole-tree loops, each claiming worktrees for plans the others are also touching. `--plan NNN,NNN.MM,...` scopes a round to just the plans named, refusing up front if one doesn't exist rather than silently running everything, and it scopes pushing along with it. The shape that works: create every plan, verify each with `status`, then one `run --commit --plan ...` handoff at the end. Full constraints for that shape (the four headings, what a brief must never write, when to block instead of guess) live in `src/commands/plan-create.md`.

### Chaining: one plan, several agents, one round

When an agent finishes and the plan has genuinely advanced — its folder renamed, or its contents now justifying the next state — the runner hands it straight to the next state's agent **in the same round**: researcher to writer to planner, without paying a full round per hop. Chaining is on by default and forced off by `--agent`, since chaining past a restriction would un-restrict it; `--no-chain` turns it off explicitly. The chain stops exactly where round assignments stop: at a blocked or finished state, a human decides.

### Steering one agent, or stepping around one

`--agent NAME` restricts the round to that one agent: plans in every other state are left unassigned, and chaining is off so the restriction holds. An agent that handles none of the in-scope plans' current states is refused up front — naming the state each plan is in and the agent that would take it — rather than running an empty round that exits 0 in silence. `--prompt "…"` rides along with it, appending extra instructions to that agent's prompt for this run only — it refuses to work without `--agent`, because a sentence aimed at one specialist would otherwise reach every agent in the round.

`--skip NAME` (comma-separated for several) is the inverse: the named agent is never assigned, its plans simply wait, and the rest of the pipeline runs as usual. A skipped agent whose work already exists on disk costs nothing — the per-round resync still advances any folder whose contents justify the next state, which hands it to the next agent. A misspelled name is refused rather than silently skipping nobody, and `--agent X --skip X` is refused as the contradiction it is.

### The keyboard, while a run is in flight

When STDIN is a terminal, the loop listens for single keys. `h` or `?` pops up the bindings; the others reach the running agents:

| Key | What it does                                                                                                      |
| --- | ----------------------------------------------------------------------------------------------------------------- |
| `w` | ask every running agent to wrap up the essential remainder as fast as possible                                    |
| `n` | ask agents to write out what they have and stop; the loop continues, so chaining hands the plan to the next agent |
| `q` | write out, stop everything, and quit — agents get a 60-second grace to save, then are terminated                  |

`claude -p` takes no input once started, so the keys work through a **control file** per invocation: the agent's prompt names the file and tells it to poll between steps; a keypress writes `WRAP_UP` or `STOP` into every file currently registered. Like the rest of the prompt that is a request — an agent mid-tool-call reacts at its next step — which is why `q` also arms a deadline the harness enforces: anything still running when the grace runs out is aborted, and `--timeout` remains the backstop behind that. Control files only exist when somebody is actually at the keys; a piped or scripted run gets neither the listener nor the polling instructions.

### Token budgets

`--max-tokens N` caps what one invocation may spend — input plus output, sub-agents included. The number is stated in the agent's prompt so it can plan the work to fit and write results to disk before the meter runs out; the harness aborts the invocation once the live token count crosses N, reported like a timeout. A prompt is a request, a check is a guarantee — the statement in the prompt is only honest because the meter makes it true.

### Timeouts, and defaults from a config file

One agent gets `--timeout` seconds before it is abandoned (default: 900). A researcher that reads two sibling repositories can genuinely need more, and an agent killed at the cap loses everything it had not yet written. An agent can also declare its own clock with `timeout:` in its frontmatter, which beats the run-wide value for that agent alone. Whichever clock applies is drawn on the agent's progress line as a countdown, grey until the last minute and red from there, so "working" and "about to be abandoned" stop looking identical. The agent is told the same number in its prompt, so it can pace itself rather than discovering the ceiling by dying on it, and no agent's prose can name a figure that has gone stale.

Defaults for `run` can live in `~/.local/config/agentilda.json`, keyed by command:

```json
{ "run": { "timeout": 1800, "jobs": 4 } }
```

A flag actually typed beats the file, the file beats the built-in, and an unreadable file is refused rather than silently ignored. The file can supply `timeout`, `jobs`, `rounds`, `log`, `chain` and `max_tokens` — never `--commit`: a run that writes is something a person asks for each time.

### Isolation, and why it is the default

Under `--isolation worktree` each plan gets **its own git worktree on its own branch**, named `<user>/NNN.MM-slug`. Agents on different plans then share nothing, and the round runs genuinely in parallel — `cores - 2`, capped at 12.

Two agents editing one checkout produce no git conflict: same branch, same files, so the last writer simply wins and the loser's work vanishes with nothing anywhere to say it happened. A lock coordinates a shared tree; a worktree removes the sharing. **Concurrency is therefore refused without isolation** — `--isolation shared` forces one job.

The branch name is not decoration: `<user>/002.00-slug` is exactly what `resync prs` reads first, so the plan number carries itself from worktree creation to a merged pull request with nobody having to remember it.

Worktrees an agent left untouched are pruned. Dirty ones are kept — they are the output. Review one with `git -C <repo>.worktrees/<plan> diff`.

### When it stops

The loop ends at a **fixed point** — a round in which no plan changed state — after two consecutive dry rounds, or at the `--rounds` ceiling. `settled?` reports when every plan is done or deliberately parked.

Progress is read from disk, never from what an agent claims: after each attempt the runner re-runs `resync dirs` and re-reads the folder name, so an agent that reports success but wrote nothing shows as `no change`.

**Blocked plans are never assigned to anyone.** ⭕️ and 🅱️ mean a human decides; an agent that could move them would make the states meaningless. They are reported at the end with a pointer to their `blocked.md`.

### The autonomy boundary

Agents may read anything and write source, tests and a plan's own markdown. They may **not** commit, push, or create or edit a pull request.

That is enforced twice: `--disallowedTools` before, and a check that `HEAD` has not moved after. A round that committed is reported as a failure. A prompt is a request; a check is a guarantee, and only one of the two survives a model deciding it knows better.

______________________________________________________________________

## Working on the gem

The gem lives in `workflow/` and has its own `Gemfile` and `gemspec`, but the checks run from the repository root so that they see the installer half too:

```bash
just test         # rspec, from workflow/
just lint         # standardrb, from the root, across both halves
just ci           # both, the way CircleCI runs them
just docs         # regenerate the conventions from the state machine
```

`agentilda.gemspec` declares what the gem needs in order to run; the `Gemfile` beside it declares only what you need in order to work on it. The executables in `exe/` resolve `BUNDLE_GEMFILE` from their own location, so they behave the same run from `PATH` as from another project's root.

______________________________________________________________________

© 2026 Konstantin Gredeskoul
