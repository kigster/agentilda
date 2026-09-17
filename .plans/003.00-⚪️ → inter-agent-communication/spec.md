# Inter Agent Communication

## What we are trying to achieve

Replace `mailbox.md` with a structured, machine-readable channel between the agents building one plan, carried over Redis and recorded as JSON committed beside the plan. Along the way, give the harness a place to record what an interrupted agent had done, so a restart resumes instead of guessing.

## Why it matters

`luke-backend` and `rey-frontend` build one plan in one worktree at the same time as two separate `claude -p` processes. Today their only channel is `mailbox.md`: append-only Markdown, parsed by a regex (`lib/agentilda/mailbox.rb:29`), polled only when an agent remembers to. Three things follow from that:

- Nothing knows whether a message was read. An agent that stopped reading its mail looks exactly like an agent with no mail.
- Delivery latency is whatever the agent's own judgement of "each significant step" turns out to be (`lib/agentilda/executor.rb:586`).
- A resume note after Ctrl-C is free text (`RESUME: ...`), so the next round has to read and believe prose rather than act on a record.

## What already exists

| Piece                     | Where                                            | Shape today                                                                                              |
| :------------------------ | :----------------------------------------------- | :------------------------------------------------------------------------------------------------------- |
| Mailbox                   | `lib/agentilda/mailbox.rb` (141 lines)           | Markdown, append-only, `flock` + append, numbered headings                                               |
| `mail send` / `mail read` | `lib/agentilda/cli/mail/subcommands/` (86 lines) | the only writer/reader an agent uses                                                                     |
| Run state                 | `lib/agentilda/state_file.rb`                    | `.plans/tmp/agentilda-state.json`, gitignored, one writer, whole-file write + `File.rename` every second |
| Control file              | `lib/agentilda/control.rb`                       | one file per invocation, polled by the agent; `WRAP_UP`, `STOP`, `INTERRUPT`, `WARN:`                    |
| Per-agent wrapper         | `lib/agentilda/dispatcher.rb:312`                | `Thread.new` per running agent, streaming `child.each_chunk` live, with a `Clock` on a timer             |
| Invocation                | `lib/agentilda/executor.rb:358`                  | where `claude -p`'s argv is composed                                                                     |
| Ledger                    | `lib/agentilda/ledger.rb`                        | dated NOTE lines an agent writes into the file named by its `ledger:` frontmatter                        |

## Constraints that shaped every decision below

These are properties of the runtime, not preferences. Each one killed an option that looked reasonable first.

1. **An agent cannot catch a signal or spawn a thread.** `luke-backend` is a `claude -p` process running a model's turn loop. It acts only between tool calls, one at a time, and a long `Bash` or a `Task` wave is minutes during which nothing is checked. This is why `control.rb` exists and why `Control::GRACE` (60s) backs it: the prompt asks, the harness guarantees.
1. **Nothing can put text into a running turn from outside.** The two crossings inward are the control file (agent polls, cadence is the agent's) and a Claude Code hook (runtime injects, cadence is one per tool call). There is no third.
1. **`File.rename` defeats `flock`.** The lock lives on the inode. `StateFile#save` writes a temp file and renames it over the target, giving the file a new inode, so a concurrent writer's lock protects a file that is now unlinked and its write is lost. This is why the run's state file and a multi-writer mailbox cannot be one file.
1. **Redis pub/sub is lossy.** `PUBLISH` to a channel with no subscriber discards the message silently — no error, no queue.

## Decisions

### D1. The state file moves up, out of `tmp/`

`.plans/tmp/agentilda-state.json` → `.plans/agentilda-state.json`. It stays gitignored and machine-local. `StateFile::DIRNAME` goes away; `StateFile::IGNORE` becomes a file line rather than a directory line, and `.for` loses a segment.

Existing checkouts have `.plans/tmp/` in `.gitignore` and a live file in it. Decide at implementation time between migrating on load and leaving the stale directory; do not silently orphan a running harness's state.

### D2. The mailbox becomes JSON, committed with the plan

One `mailbox.json` per plan folder: a time-ordered array of messages, each with `from`, `to`, `at`, `body`, and `read`. It is committed, because the exchange is part of the plan's record and must survive across machines and runs.

JSON rather than Markdown because agents should do as little parsing as possible. Human readability is recovered by rendering, not by storage: `agentilda mail render` produces the Markdown view on demand. The regex-and-heading machinery in `mailbox.rb` (`HEADING`, `parse`, `SEPARATOR`) is deleted.

### D3. `read` is written by the reader, not by delivery

A Redis consumer-group ack says the bytes arrived. It does not say anyone read them. `read: "yes"` is set by an explicit `agentilda mail ack`, which each agent's prompt tells it to issue immediately on reading.

Surface the unacked count on the dashboard. An agent that stopped acking is an agent that stopped reading its mail, which is currently invisible.

### D4. Redis is required, and it carries Streams

Redis is a hard dependency with a clear error when absent, not a silent degrade. Local Redis with no auth, or `$REDIS_URL`.

**Streams (`XADD` / `XREADGROUP`), not pub/sub.** Same effort, and it gives three things pub/sub cannot: a message survives the reader being down, a stream replays what an agent missed, and consumer groups ack delivery.

TTL: Streams have no per-message TTL. The equivalent of the 60-minute window is `XTRIM <key> MINID <now - 60min>` on each write plus `EXPIRE` on the stream key. Nothing is lost by trimming, because the committed JSON is the durable record and Redis is only the transport.

**Key naming must include the checkout, not just the plan ordinal.** Ten sessions run at once here, and two worktrees of this repo both running `001.00` would otherwise cross-talk into each other's streams.

### D5. No broker process. The harness thread is the single writer

An earlier draft had one lightweight Ruby process per running plan as the sole writer of the JSON. Dropped: `dispatcher.rb:312` already gives each agent its own thread inside the harness process, already streams the child's output live, and already runs a `Clock` on a timer beside it. That thread drains Redis every second and writes the plan JSON directly, single-writer under a `Mutex`, exactly as `StateFile` does.

This removes the broker's whole lifecycle — spawn, reap, kill on Ctrl-C, orphan cleanup when the harness dies, and "who restarts the broker". Redis keeps the one job only it can do: carrying messages *out* of `claude -p` processes, which are the only actors genuinely outside our process.

Cuts this phase from roughly 4–5 days to 2–3.

### D6. A PostToolUse hook accelerates delivery inward

`Executor#argv` (`executor.rb:358`) gains `--settings` with a **PostToolUse** hook running `agentilda mail poll --plan N --for <agent>`. It fires after every tool call the agent makes and returns waiting messages and any `INTERRUPT` as context the model sees immediately.

What it changes: polling stops being a request in the prompt that the agent may forget, and becomes something the runtime does whether or not the agent cooperates. Latency drops from "next time the agent remembers" to "next tool call".

What it does not change: an agent four minutes into one `Bash` call is still unreachable for four minutes. `GRACE` remains the backstop.

Risks: a hook that errors or prints too much disrupts every tool call the agent makes. It must fail silent and cap its output. This is the one item in scope that can be cut to a follow-on without invalidating the rest.

### D7. `last-known-state`, with two writers and a precedence

A `last-known-state` section in the plan's JSON, keyed by agent name, last entry wins, with `round` inside it — an agent interrupted in rounds 1 and 3 should not accumulate entries nobody prunes.

Flow on Ctrl-C: keypress → control file → agent polls (or the hook fires) → agent publishes its state to Redis → harness thread writes it into the JSON. Cooperative and polled, per constraint 1.

Three cases leave the agent writing nothing: terminated when `GRACE` expires mid-tool-call, never reaching another polling point, or dying outright — which is not hypothetical, the state file in the previous worktree shows `"exit": "harness died"` on all four stages. So **the harness is a fallback writer**, from what it already observes: last ledger line, last transcript phrase, round, tokens, exit reason.

The agent's own entry always wins when present. Each entry says which wrote it:

```json
"last-known-state": {
  "luke-backend": {
    "source": "agent",
    "at": "2026-09-17T13:37:04-07:00",
    "round": 1,
    "status": "Interrupted",
    "done": ["Ledger#parse extracted", "specs green"],
    "remaining": ["wire Dispatcher#read_ledger"],
    "next_step": "run bundle exec rspec spec/agentilda/ledger_spec.rb",
    "files_touched": ["lib/agentilda/ledger.rb"]
  },
  "rey-frontend": {
    "source": "harness",
    "at": "2026-09-17T13:37:04-07:00",
    "round": 1,
    "status": "Interrupted",
    "note": "harness died; last seen writing plan-frontend.md"
  }
}
```

A **fixed schema, not freeform**. Freeform JSON is prose with braces, and the next round could not act on it any better than it acts on `RESUME:` today.

**Split:** the semantic resume note goes in the committed plan JSON; pids, tokens and exit codes stay in `.plans/agentilda-state.json`, which is machine-local. Otherwise every interrupted run churns a committed file with process detail nobody reviews.

### D8. `plan-backend.md` / `plan-frontend.md` fold into `plan.md`

`palpatine-planner` writes `## Backend` and `## Frontend` sections inside `plan.md` instead of two sibling files. Touches `status.rb` invariants, `linear/units.rb`, `documentation.rb`, and three agent prompts.

**Open problem, must be solved as part of this:** those files are also ledgers. `agents/luke-backend.md:11` declares `ledger: [plan-backend.md, pull-requests.md]`, luke signs `Started` and `Completed` into its own plan file, and `dispatcher.rb:467` appends the harness's `Interrupted` line there too. Merge them and two concurrently running agents do read-modify-write on one file through Claude's `Edit` tool, with no lock. Last writer wins, silently.

Note the race already exists — both agents list `pull-requests.md` as a ledger today. Merging doubles it rather than inventing it.

Options:

- **(a)** Accept it. Both sign into `plan.md`. Simplest; matches the existing tolerance of `pull-requests.md`.
- **(b)** Units merge into `plan.md`, signing moves to a per-agent ledger file. No race, one more file per agent.
- **(c)** *Recommended.* Units merge into `plan.md`, and signing goes through `agentilda ledger sign`, a CLI call that takes `flock` and appends. Agents stop hand-editing ledgers entirely. `Ledger.append` already exists, so this is small, and it fixes `pull-requests.md` at the same time.

### D9. `implementation-plan.md` → `contract.md`

The name is wrong in the same direction as everything else called "plan". `plan-backend.md` says *what luke will build*; `implementation-plan.md` says *what luke built and how to call it* — the interfaces, their shapes, their errors, which files each half owns, which units may run concurrently, and the one integration test proving the halves are joined. `lib/agentilda/documentation.rb:326` calls it "the one file no state requires". Every comment in the repo already calls it the contract.

Nine references: `executor.rb:602`, `documentation.rb:323,326`, `agents/luke-backend.md`, `agents/rey-frontend.md`, `agents/hansolo-reviewer.md`.

### D10. OpenAPI is an optional companion, never the contract

When a plan exposes HTTP endpoints, `luke-backend` also writes `openapi.yaml` beside `contract.md`, and `contract.md` links to it. `palpatine-planner` decides in `plan.md` whether the plan has an HTTP surface. A later `agentilda api docs` collects every `.plans/*/openapi.yaml` for Redoc.

OpenAPI is not the contract itself, for three reasons:

- **Most splits are not HTTP.** `luke-backend` is "data, domain, and the API an interface will call" — often a Ruby service object, a GraphQL schema, a TypeScript module, or a CLI. This gem, the thing dogfooded on, has no HTTP surface at all.
- **Half the contract has no OpenAPI slot.** File ownership, unit concurrency, and the integration proof are the half that stops the two agents colliding, and OpenAPI cannot express any of it.
- **It is a harder write target.** A malformed `$ref` breaks the file for rey silently.

Validation starts cheap — parses as YAML, has `openapi:` and `paths:` keys. A real validator gets added only if agents actually produce broken files.

## Phases and effort

| Phase | Content                                                                     | Files | Effort    | Risk                                                |
| :---- | :-------------------------------------------------------------------------- | :---- | :-------- | :-------------------------------------------------- |
| A     | D1 — elevate the state file                                                 | 4     | ~1 day    | low                                                 |
| B     | D2, D3, D8, D9 — JSON mailbox, ack, plan merge, rename                      | ~15   | ~3 days   | medium; the risk is the agent prompts, not the code |
| C     | D4, D5, D6, D7 — Redis Streams, harness as writer, hook, `last-known-state` | ~8    | ~2–3 days | medium                                              |
| D     | D10 — optional OpenAPI and `api docs`                                       | ~5    | ~1 day    | low                                                 |

A ships alone. B ships alone. C depends on B's JSON format. D is independent of all of them.

## Non-goals

- **Not replacing the Markdown ledger.** `Ledger`'s NOTE entries stay human-readable in the documents; only *who writes them* is in question (D8).
- **Not committing `agentilda-state.json`.** It is about one machine's run.
- **Not push delivery into a running turn.** Constraint 2 says it cannot be built. The hook is the closest achievable thing.
- **Not OpenAPI for non-HTTP interfaces.**
- **Not a broker daemon.** Explicitly dropped, D5.
- **Not fixing the `pull-requests.md` write race**, except as a side effect of D8 option (c).

## What research needs to settle

1. D1: migrate the old `.plans/tmp/` state file and `.gitignore` line, or leave the stale directory?
1. D8: confirm option (c). The recommendation stands but has not been chosen.
1. D3: what does an unacked message older than N minutes *mean* to the harness — a warning on the dashboard, or an input to the round's decisions?
1. D6: hook in the first cut, or follow-on? Recorded as in scope, marked cuttable.
1. What happens to a `mailbox.md` already in flight when the format changes — converted, or left as history beside the new JSON?
1. Does `agentilda mail render` write a file or print to STDOUT? The house rule is that STDOUT carries the deliverable.
1. Which Redis client, and how it becomes an injectable seam so the suite never reaches the network, as `GitHub` and `Linear::API` already are.

## Conclusion

When this ships, two agents on one plan talk over Redis Streams with durable delivery and explicit read receipts; the exchange is committed as JSON and rendered to Markdown on demand; an interrupted agent leaves a structured resume record that the harness completes when the agent could not; the four files with "plan" in the name become two with the right names; and an HTTP plan carries an OpenAPI description that Redoc can render across the whole `.plans` tree.
