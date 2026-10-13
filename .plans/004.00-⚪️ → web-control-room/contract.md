# Contract: engine, API server, page

The shapes are in `web/src/api/types.ts`, the single source of truth. `web/src/api/fixtures/snapshot.json` is one valid `Snapshot`; the Ruby suite checks `Live::Snapshot#to_h` has the same keys at every level, and the TypeScript suite type-checks the fixture.

## Processes

- **Engine:** `tilda run`. Runs the dispatcher. Every tick it publishes a `Snapshot` and reads commands.
- **API server:** started by `tilda run` beside the engine (a separate process, `tilda web` on its own), Sinatra 4 on Puma, `127.0.0.1:4747`. Holds no state: reads Redis, writes Redis, serves `web/dist`.
- `tilda run --no-web`: engine only. `--no-open`: do not open the browser. `--port`, `--redis-url`.
- `tilda web --demo`: the API server over a demo engine that publishes sample snapshots and answers commands, with no agents. Cypress and the front-end dev server run against it.

## Redis keys

`P = agentilda:<repo>`, `<repo>` the normalised GitHub URL (`github.com/owner/name`), `<node>` 24 hex digits of SHA-256(`user@host`), `<checkout>` 12 hex digits of SHA-256(realpath of the checkout).

| Key | Type | Written by | Holds |
| --- | --- | --- | --- |
| `P:nodes` | hash | each engine | `<node>:<checkout>` → JSON `Node`, refreshed every heartbeat |
| `P:<node>:<checkout>:snapshot` | string | engine | latest `Snapshot` JSON, `EX 30` |
| `P:<node>:<checkout>:board` | stream | engine | `{seq, json}` per published snapshot, `MAXLEN ~ 100` |
| `P:<node>:<checkout>:commands` | stream | API server | `{json}` one `Command`; engine reads with group `engine` |
| `P:<node>:<checkout>:replies` | stream | engine | `{json}` one `Reply`, `MAXLEN ~ 1000` |
| `P:<node>:<checkout>:done` | hash | engine | command id → `Reply` JSON, for redelivery (W13); trimmed after a day, unreadable entries dropped |
| `P:<node>:<checkout>:run` | hash | engine | `seq` and `json`: the run state a person set (held questions, held cars, queued models), written in the same `MULTI` as the reply that changed it; mirrored into `.plans/agentilda-state.json` under `live`, and on start the copy with the higher `seq` wins (W6) |
| `P:claim:<ordinal>` | string | engine | `<node>:<checkout>`, `SET NX EX 90`, renewed by heartbeat, released by compare-and-delete |

A node is alive while its `snapshot` key exists. Whoever reads `P:nodes` drops the fields whose snapshot has expired, and an engine that closes cleanly removes its own. A checkout with no `origin` is `local/<dirname>-<12 hex of SHA-256 of its real path>`. The API server reads every node's snapshot for the repository; it writes commands only to its own node's stream.

## HTTP

| Method, path | Does |
| --- | --- |
| `GET /` and static | `web/dist`; `index.html` for unknown non-API paths |
| `GET /api/board` | `Board` JSON now |
| `GET /api/events` | SSE: first `event: cursor` with `id:` and `{id}` set to the newest reply id (`0-0` when there is none), so a reconnect always has a `Last-Event-ID`; then `event: board` with a `Board` whenever any snapshot's `seq` changes (checked every 250 ms), `event: reply` with each `Reply`; a `: ping` comment every 15 s |
| `POST /api/commands` | body `Command`; header `X-CSRF-Token` must equal the token in `GET /api/session`; `202` with `Reply{status: "accepted"}` once queued, `422` with `Reply{status: "refused"}` for an invalid command |
| `GET /api/session` | `{csrf, node, repo}` |
| `GET /api/plans/:ordinal/files/:name` | the Markdown of a plan file (spec.md, plan.md, blocked.md), for the drawer and preview |
| `GET /healthz` | `ok` and the Redis address, password masked |

The page reconnects with `@microsoft/fetch-event-source`, and on reconnect fetches `/api/board` once.

## Commands, as the engine applies them

| kind | effect |
| --- | --- |
| `answer` | append `## A<n>` with the text, "Answered by <user> on <date>" and `<!-- cmd:<id> -->`, to blocked.md; once every `B<n>` has an answer the dispatcher hands the plan to the agent that handles its state (lando-broker) through `Lifecycle::Unblocker`, on a thread, and picks the plan up again in the same run. Each answer set is tried once; a failed drain waits for blocked.md to change |
| `hold_blocked` / `release_hold` | mark the question held in the run state; the page shows the pill solid red ⏸ |
| `resume` | resume the interrupted agent from its last-known-state with the note in its mailbox |
| `discard` | plan-wide (W9): stop every agent on the plan (STOP, then SIGKILL after 15 s), `git reset --hard` and `git clean -fd` in the plan's own worktree (its branch's last commit; agents never commit), then move the folder back one state through `StateMachine#retreat!`. The reply waits until all of it is done. Refused up front under `--isolation shared` or a dry run, and for a state with nothing behind it on the spine (🔴 💩 ⏪) or whose earlier state the folder does not fit |
| `message` | append to the plan's mailbox, from `human`, to the agent; the entry carries the command id, so a redelivered command appends nothing |
| `hold`, `wrap_up`, `stop` | write the word to that agent's control file (`HOLD`, `WRAP_UP`, `STOP`) |
| `compact` | write `COMPACT` to the control file; the agent runs `/compact` at its next step |
| `stop_all` | `Execution::Control.quit!` on this node |
| `set_model` | the model for that agent's next round on this plan, normalised to the id the CLI will run (a model above the adapter's ceiling is refused) |
| `switch_model` | stop the agent with INTERRUPT, so it leaves a resume note, and start it again on the new model in the same round, from that note in a fresh session. Not `--resume` plus `/compact`: agents run with `--disable-slash-commands`, so `/compact` cannot be sent, and a fresh session is already compact |
| `add_plan` | claim the plan, add it to the run's scope |
| `create_plans` | `Lifecycle.create` a plan from the idea, its spec.md carrying `<!-- cmd:<id> -->`, then `add_plan`; a plan already carrying the marker is added rather than created again |

Every reply goes on `replies` and into `done`. A command whose id is already in `done` is acked and answered with its first reply. Effects outside Redis are idempotent by command id (the markers above, the mailbox's `command`), so a command applied again after a failed `MULTI` changes nothing twice.
