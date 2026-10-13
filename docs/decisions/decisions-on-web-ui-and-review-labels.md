# Decisions on the web control room and review labels

Date: 2026-10-12. Taken in conversation with the author, without a separate grilling session. Items marked **(proposed)** were filled in by the agent and await the author's review.

Plans: `004.00` web control room, `005.00` review state labels.

## Web control room

### W1. The web is the only interactive view

`tilda run` starts the web server and opens the browser. With no display (SSH, CI, no TTY), the URL is printed rather than opened, and `--no-open` forces that. There is no `--tui`: the terminal UI is removed (W22). Agentilda is now a web-based software factory.

### W2. A `View` contract, not a virtual terminal

Every view implements `open`, `draw(board)`, `attach(console)` and `close`. After W22 there are two: the web view, and a headless view that writes one line per change to STDERR, for CI and for `--no-web`, so a run never needs a browser to finish. The views are decoupled at the level of data (`Engine::Board`), not terminal cells. Streaming a cell buffer to xterm.js would give a browser view for free, but no forms. With one viewer per run, `Board` keeps its per-viewer fields (`selected`, `dialog`, `help`), and `Console` remains the single gate through which every intent reaches the dispatcher.

### W3. Stack: Sinatra 4 + Puma, React + TypeScript + Vite, shadcn/ui, Motion

- Hanami 3 was considered and rejected. It expects to be the application, with its own root, container, settings and database scaffolding, and its guide covers no streaming, SSE or WebSockets. It also needs Node for assets, so it saves nothing over React.
- Sinatra's `stream` helper serves SSE on Puma. The server binds to `127.0.0.1` only, with a CSRF token on every write.
- The front end uses React with shadcn/ui (Tailwind) for widgets and Motion for animation. It is built with Vite, and the built `web/dist` ships inside the gem, so Node is needed only to build it and to run Cypress.

### W4. Animations follow the state machine

Each plan is a card that travels between agent lanes, then becomes a pull request node, then a review outcome (rejected, approved, approved with caveats, approved despite CI). The lanes and edges come from an API endpoint derived from `StateMachine` (`SPINE`, `FAMILIES`, `.edge?`) and `Agents::Registry`, never from a hand-written list in the front end.

The visual direction (a transit board: one horizontal line per plan through shared station columns, with agents hanging under the current station as cars that show live tokens in and out) is in `.plans/004.00-⚪️ → web-control-room/design/design.md`, with a working mockup beside it in `control-room.html`.

### W5. The frontmatter form is generated from a schema **(proposed)**

A JSON Schema for the `spec.md` frontmatter is published next to `schemas/plan-state.schema.json`. The server validates against it with `json_schemer`, and react-jsonschema-form renders the form from it. `Plans::Spec` and the schema must not diverge: a spec asserts they agree.

### W6. Redis holds the runtime, the filesystem holds the plan

Builds on plan `003.00` (inter-agent communication), whose D4 already made Redis a hard dependency, failing with a clear error when absent, and chose Streams over pub/sub.

- A plan's state remains its folder name and its `state.json`.
- **Redis is the live record of the run:** which agents are running, their PIDs, trace paths, inbox keys, session ids and why each was started. The engine and the API server read and write the run there, and nowhere else, while it is going.
- **The engine flushes that record to disk**, as `.plans/agentilda-state.json` through `Engine::StateFile`, for two reasons the author gave: a person can read it without `redis-cli`, and it is a backup if Redis loses its data. The flush is atomic (write a temporary file, then rename), happens at most every two seconds while something changed, and always on shutdown.
- **On start, the engine takes whichever copy is newer.** Both carry a sequence number that the engine increments on every change. Normally Redis wins; if Redis was flushed or restarted empty, the file is loaded back into it.
- This settles the conflict with plan 003's D7: the state file stays, with the PIDs and `last-known-state` in it, but it is a snapshot of Redis rather than a second source of truth. Only the engine writes it. (Settled by the author, 2026-10-12.)
- The board and the commands travel on Redis Streams (W13), not pub/sub. Pub/sub discards messages when nobody is subscribed, which is exactly the moment the other process is restarting.
- Redis is a seam with an in-memory fake, so the suite never reaches the network. There is no file-store fallback: plan 003's D4 rules it out.

### W7. Two processes: the engine and the API server

- **The engine** is the runner. It supervises the agents, spawning each with `Process.spawn(pgroup: true)` and sending its stream-json output straight to its trace file, so the agent does not depend on a pipe to its parent.
- **The API server** is a multi-threaded Puma process running Sinatra. It holds no run state of its own: everything it shows comes from Redis, and everything it is told to do goes back through Redis.
- `tilda run` and `tilda start` start both and open the browser. `tilda run --no-web` starts only the engine, with the headless view (W2).
- **If the API server crashes,** nothing is lost. A restarted server reads the streams again, and an open tab reconnects by itself, because the port is fixed (default `4747`, `--port` to change it).
- **If the engine crashes,** agents keep running. The restarted engine reads the running set from Redis, checks each PID, tails each trace again, and carries on.
- Einhorn was considered and rejected. It keeps N copies of one long-lived program alive and stops its children when it exits, while these agents are all different, run once, and must outlive their parent.

### W8. Messages reach an agent at every tool call, through hooks

Plan `003.00` D6 already adds a `PostToolUse` hook (`agentilda mail poll`) passed through `--settings`, which injects waiting messages after each tool call. This plan reuses that channel for messages from the person and adds three things:

- **Message kinds:** `stop`, `shutdown`, `wrap_up`, `hold` ("more info is coming"), `message` and `answer`. They replace the bare words in `execution/control.rb`.
- **(proposed)** A `PreToolUse` hook beside 003's `PostToolUse` hook. On `stop` or `shutdown` it blocks the agent's next tool call and gives the reason. Injecting text after the fact cannot stop a tool from running; blocking it before it starts can.
- **`hold`** makes the agent run `agentilda mail wait --plan NNN`: one blocking tool call that checks every 10 s and returns when something new arrives. Waiting then costs one turn, not one per check.

Why not just ask the agent to check every 10 s: an agent only acts between turns, and a single `rspec` call can last minutes. The hooks fire at every turn boundary whether or not the agent remembers, and `Control::GRACE` with the harness's hard kill remain the final guarantee. Adapters without hooks (Codex, Pi) still get the instruction in their prompt.

### W9. Interrupt offers discard or keep

After an agent is interrupted, the page offers a choice:

- **Discard:** reset the plan's worktree and send the plan back one state through an `aasm` event.
- **Keep:** resume from the agent's `last-known-state` record (plan `003.00` D7), with the person's feedback added to its mailbox.

The choice is made per interrupt and is never a global setting.

### W10. Talking to agents uses the existing channels first

A person's message to a running agent goes into the plan's mailbox (plan `003.00`) as a `human` entry, from which the hooks of W8 deliver it. The mailbox is also the record that outlives the run. Questions in `blocked.md` appear as answer forms, which run the unblocker on submit. Live stream-json input to `claude -p` (`--input-format stream-json`, `--resume`) is a later spike, not a prerequisite.

### W11. `--commit` still governs writes

Without `--commit`, the page shows a dry run and its write controls are disabled.

### W13. The engine and the API server talk over Redis Streams, both ways

A direct bidirectional socket was considered. Streams won because they keep what the other side missed while it was down, which a socket does not, and because the agents' mailbox (plan `003.00` D4) is already on them, so there is one transport rather than two.

| Stream | Direction | Carries |
| --- | --- | --- |
| `board` | engine → API | one `Board` snapshot per tick, trimmed to the last few minutes |
| `commands` | API → engine | `kill`, `extend`, `interrupt`, `discard`, `keep`, `answer`, `message`, `create_plan`, `save_spec` |
| `replies` | engine → API | one reply per command id: accepted, refused (with the reason) or done |

- The engine reads `commands` through a consumer group, so a command sent while the engine was restarting is executed when it comes back, and it is acked only once it has been applied.
- In the engine, the web view is a `View` like the TUI (W2): its `draw(board)` appends to `board`, and its command reader feeds the same `Console` gate the keyboard uses.
- Key names include the checkout, as plan `003.00` D4 requires, so two checkouts never read each other's streams: `agentilda:<checkout>:board`, where `<checkout>` is a hash of the checkout's absolute path (D4 has the format).

### W14. One logging library, one log directory

- Every component logs through SemanticLogger: the engine, the API server and each CLI command. Agents' raw traces stay in `Dir.tmpdir/agentilda-traces`, for the reason `Executor::TRACE_DIR` gives.
- By default, logs go to `.agentilda/log/engine.log` and `.agentilda/log/api.log` in the project root, one file per process so two processes never interleave lines in one file. One line per entry by default; `--log-format json` for machines.
- `.agentilda/` is created when missing and added to `.gitignore`.
- This departs from the global `log/` convention on purpose: agentilda runs inside other people's projects, and their own `log/` belongs to them.
- `-l`/`--log`, `-L`/`--log-level` and `--log-format` work as the global CLI rules describe, with the paths above as defaults.

### W15. Every test run gets its own tab, fed by a tee

- While an agent runs a test command, the page shows a tab labelled with the plan (`001.00 tests`), with a live count of examples run. If two agents test the same plan at once, the agent's name is added to the label.
- The tab shows passed, failed and pending counts, a bar whose segments are proportional to how examples ended (green passed, yellow pending, red failed), the failures with `file:line`, and the output as it arrives. It stays after the run ends, showing ✓ or the number of failures, until it is closed. When the same agent tests again, the run reuses its tab.
- **Why a tee:** stream-json reports a Bash call's output only once the call has finished, so the engine cannot watch a test run live by reading the transcript. Agents run tests through `agentilda test -- <command>`, which tees the output to `.agentilda/log/tests/<plan>-<agent>.log` and appends progress to a Redis stream. The prompt asks for this, and **(proposed)** a `PreToolUse` hook rewrites known test commands (`rspec`, `just test`, `npm test`, `pytest`, `cypress run`) to go through the wrapper. Whether hooks can rewrite a tool's input is one of plan 004's research questions.
- Pass and fail counts come from the runner's structured output where one exists (RSpec's JSON formatter, JUnit XML), not from parsing human-readable text.

### W16. Agentilda never reads `REDIS_URL`

Agentilda runs inside other people's projects, and there `REDIS_URL` usually belongs to the application, often pointing at a shared or production Redis. Writing agentilda's streams into it would be a quiet, damaging mistake. So the Redis address comes from three places, in this order, and nowhere else:

1. `--redis-url` on the command line.
2. `redis_url:` in agentilda's configuration file.
3. `AGENTILDA_REDIS_URL`.

Without any of them, agentilda uses `redis://localhost:6379/0`. On startup, the engine and the API server each log the address they use, with any password masked. This supersedes the `$REDIS_URL` fallback in plan `003.00` D4.

### W17. A copilot to talk to about the run: c3po-operator

The dispatcher is code, not an agent, so there is nothing there to chat with. The copilot is a new agent, **c3po-operator**, whose only job is to talk to the person about the run.

- **Where:** a pop-up in the bottom right of the page. Closing it shrinks it to a small tab fixed to the right edge of the screen, which shows a dot when the copilot has said something you have not seen.
- **What it reads:** the board, the logs, each plan's `state.json`, the mailboxes and the agents' transcripts. It runs only the `agentilda` commands that read state.
- **What it does:** it answers questions ("why has 002 not moved?"), drafts answers to blocked agents, and summarises. Actions go through the same command gate as the page's buttons (W13), so it can never do anything the page cannot. Reversible ones (message, hold, extend) can be sent directly. **Stop, discard and stop run** appear in the chat as a card that the person confirms.
- **What it never does:** edit code or plan documents. That is the other agents' job, and two writers on one file is the race plan `003.00` D8 is about.
- **How it runs:** one `claude -p` session, resumed on each message (`--resume`), on a cheap model by default. Its tokens are shown in its header, as a car's are on the board.
- **When:** after W8 to W10, whose channels it reuses.

### W18. The header names the project, not the directory

The page's title is the project being worked on; "agentilda" shrinks to a small wordmark beside it. Below the title: the project's one-line description and its path, abbreviated with `~`.

The title comes from the first of these that exists in the project root **(proposed order)**:

1. `title:` and `description:` in agentilda's configuration file: an explicit override.
2. A manifest: `package.json` (`displayName` or `name`, plus `description`), `Cargo.toml` (`[package] name` and `description`), `*.gemspec` (`name` and `summary`), `pyproject.toml` (`[project] name` and `description`), `go.mod` (the module path's last segment).
3. The first `# ` heading of `README.md`.
4. The directory name.

A slug from a manifest is passed through `Plans::Feature.titleize`, so `agentilda` becomes "Agentilda" with the same acronym rules plan folders use. The path's tooltip names the file the title came from. When the project is agentilda itself, the title is left out, because the logo beside it already says it. Here, `agentilda.gemspec` gives "Agentilda" and "Agentic specification-driven development: spec, plan, build, review".

### W19. `tilda start`: from an idea to accepted plans

`tilda run` drives plans that already exist. `tilda start` is for when there are none yet, or when the person has a new idea: it boots the engine and the API server exactly as `run` does, opens the page at `#start`, and starts no agents until plans are confirmed. During a run, **New idea** in the top bar opens the same dialog.

1. **The idea.** A modal asks "What is the product or feature you'd like to build?" over a Markdown editor with syntax highlighting. Above the editor, lane, front end and depth controls set the defaults every plan from this idea starts with. The draft is kept as it is typed, so closing the tab loses nothing.
2. **The split.** A short idea (under about 120 words and at most one `##` section) becomes one plan directly. A longer one goes to **palpatine-planner**, which returns the plans as JSON, validated against a schema before the page shows them **(the threshold is proposed)**. This is a new job for palpatine, which today turns one signed-off spec into work units; the agent definition gains it as a second mode.
3. **The confirmation.** The dialog becomes "Here is your idea broken up into plans. Confirm?" and lists each plan as `[001 Set up a scaffold for the application] [Accept] [Modify]`. Sub-plans are indented under their parent, with their own **Accept** and **Modify**, because each becomes a plan of its own. **Accept all** is offered while any are left.
4. **Modify** opens the same editor on the body of that plan's opening `spec.md`, with its frontmatter as controls above it (see below), and the dialog's title becomes "Editing 001: Set up a scaffold for the application". **Revert ↶** discards the edit and goes back to the list; **Save ✔** keeps it, and saving also accepts the plan. Esc steps back one view and never throws work away.
5. **Create N plans** is enabled once every plan is accepted. It creates each folder through `Lifecycle.create`, in order, as ⚪️ New. Clicking it is the consent that `--commit` gives on the command line (W11).

**Frontmatter is never typed.** The editor holds only the body of `spec.md`. Its frontmatter is a form above the editor, generated from the schema in W5: lane, front end and depth as segmented controls, and under "More settings" the per-phase adapter, model and effort plus the four lists (`implementation_suggestions`, `implementation_requirements`, `task-completed-when`, `how-to-verify`, one item per line). When the plan is created, the form is written as YAML at the top of `spec.md`, holding only the values that differ from the defaults, so `Plans::Spec` reads it unchanged. Settled by the author on 2026-10-12.

A sub-plan is an ordinary plan with its own number. Its frontmatter names its parent (`part_of: "002"`), and it depends on the plans before it in the list **(the field name is proposed)**.

### W20. `tilda init` ends in `tilda start`

`tilda init` is new: it prepares a project for agentilda (the `.plans` directory, the configuration file, a check that Redis answers) and then runs `tilda start`, so a new project goes straight from setup to the idea dialog. `--no-start` stops after setup, for scripts and CI.

### W21. Plan numbers are plain `NNN`

Settled by the author on 2026-10-12. The `.MM` suffix goes: plans are `001`, `002`, and so on. Today `.MM` marks a retroactive sibling (`002.01` is work that shipped between 002 and 003 and was documented afterwards); a retroactive plan now takes the next free number like any other, and its 🕰️ status already says it is retroactive. Sub-plans from W19 were never going to use `.MM`, because `Ordinal` defines it as a sibling and not as containment.

Existing trees keep working: `Ordinal.parse` still reads `NNN.MM` folder names, branch names and PR titles, and everything new is written as `NNN`. The change reaches about 17 files under `lib/`, so it is its own plan rather than part of 004.

### W22. The terminal UI is removed

Settled by the author on 2026-10-12, after seeing the web mockup. The ratatui screen, the keyboard handling only it uses, and the `ratatui` dependency go, and with it the Rust toolchain that building the gem needed. The `View` seam stays (W2), with the web view and a headless view behind it. This ships in its own pull request, ahead of the web view, since nothing in the web work depends on the TUI.

### W12. Order of work

0. Plan `003.00` lands first, or at least its phases B and C: the JSON mailbox, Redis Streams, the hook and `last-known-state`.
1. Remove the TUI (W22), leaving the `View` contract with a headless view behind it.
2. SemanticLogger and `.agentilda/log/` (W14), then the Redis run registry, the engine/API split and its streams, and detached agents (W6, W7, W13).
3. The web board: read-only, then kill, extend and interrupt (W9).
4. Message kinds, the `PreToolUse` hook and `mail wait` (W8), human messages and `blocked.md` answers (W10).
5. Animations (W4).
6. The new-feature form and the spec editor (W5), then `tilda start` and the idea dialog (W19), then `tilda init` (W20).

## Review labels

### L1. Six labels, one at a time

The author asked for "three labels" and then listed five. With `approved-despite-ci`, that makes six:

| Label | Colour (hex) |
| --- | --- |
| `ready-for-review` | `b7ebc6` light green |
| `review-in-progress` | `fff3b0` light yellow |
| `approved` | `0b6e2e` deep green |
| `approved-with-caveats` | `e4c200` yellow |
| `rejected` | `d73a4a` red |
| `approved-despite-ci` | `e8590c` orange **(proposed: no colour was given)** |

A PR carries exactly one of these at a time; moving to a new state removes the previous state's label. Any label missing from the repo is created before first use, and a label that already exists is left alone, colour included.

### L2. The harness applies `ready-for-review` **(proposed)**

The author wanted hansolo-reviewer to do all the labelling. But `ready-for-review` only matters while hansolo is not running, so hansolo cannot be the one to apply it. `Vcs::Publisher` applies it when it opens the PR. hansolo applies every label after that, starting with `review-in-progress` the moment it picks the PR up.

### L3. Verdicts go through an `agentilda review` command, not raw `gh` **(proposed)**

Labels are set with `gh pr edit`, which is in `FORBIDDEN_COMMANDS`. Granting it would also let hansolo rewrite PR titles and bodies, because Bash permission specifiers match by prefix. So hansolo calls `agentilda review start|approve|caveats|reject --pr N`, which creates the labels if missing, swaps them, posts the review and checks CI. `gh pr review` is removed from hansolo's `may:`, so the CI rule (L4) cannot be bypassed by calling `gh` directly.

### L4. No approval over red CI without a label and an explanation

`agentilda review approve` refuses while any check is failing, unless it is given `--despite-ci "<reason>"`. In that case it posts the reason as a top-level PR comment, then applies `approved-despite-ci`. The rule is enforced in code; the prompt explains it but does not have to be trusted.

### L5. Pending CI waits **(proposed)**

If checks are still running, hansolo does not approve. It signs "waiting on CI", leaves the PR on `review-in-progress`, and the next round looks again.

### L6. Separate from the emoji-review labels

`ready for merge` and `do not merge` belong to the human emoji-review convention and are left untouched. The six labels in L1 record the agent review's state; those two record a reviewer's verdict.

### L7. Ships independently

Plan `005.00` does not depend on the web control room. The control room's animations (W4) read these labels once both exist.
