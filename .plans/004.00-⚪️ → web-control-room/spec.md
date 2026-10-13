# Web Control Room

## What we are trying to achieve

`tilda run` opens a browser page that shows the whole run live and lets a person steer it: the board of plans moving through the stations, the agents working on each, what they cost, what they are asking, and every control a person needs to answer, redirect, pause, compact, switch or stop them. Several machines sharing one Redis see each other's work read-only and never take the same plan.

The page replaces the terminal UI, which is gone (#55, W22). It is the only interactive view; a headless view keeps runs working without a browser (W2).

What it looks like and how each control behaves is settled in `design/design.md` and the working mockup `design/control-room.html`. The decisions behind it are W1–W30 in `docs/decisions/decisions-on-web-ui-and-review-labels.md`. This spec does not repeat them; it says what has to exist and how we know it works.

## Why it matters

A run is a dozen agents over hours. Today a person learns that an agent is blocked by reading a file, answers by editing it, and stops an agent by killing a process. The control room puts every one of those moments on one screen, as they happen, with the action next to the thing it acts on.

## Scope

### In

- **Engine and API server as two processes over Redis** (W6, W7, W13): the engine publishes the board to a Redis stream and reads commands from one; the API server (Sinatra 4 on Puma, `127.0.0.1:4747`) serves the page, an SSE stream of the board, and a `POST /api/commands` endpoint. Either can restart without losing the run.
- **Redis seam** with an in-memory fake for the suite; the address comes from `--redis-url`, `.tilda.yml` `redis_url:`, `$REDIS_URL`, then localhost (W16). Keys as W26 lays them out, the repository part being the normalised GitHub URL (W29).
- **Node identity and plan claims** (W26): `username@hostname` digested to 96 bits, the `meta` hash with a heartbeat, `SET NX EX` claims renewed by the heartbeat and released by compare-and-delete. The dispatcher steps around plans another node holds.
- **Commands** with stable ids and idempotent handling (W13): `answer`, `hold_blocked`, `release_hold`, `resume`, `discard` (plan-wide, W9), `message`, `hold`, `wrap_up`, `compact`, `stop`, `stop_all`, `set_model` (next round, W24), `switch_model` (now, W27), `add_plan`, `create_plans`.
- **The page** (React + TypeScript + Vite, W3), built into `web/dist` and shipped in the gem. Every element of the mockup: header and run totals, tabs (Board, Logs, per-run test tabs, per-machine tabs that toggle), the board with its rows, stations, cars and model dropdowns, the agent drawer (model switch, context bar, transcript, composer, Action menu), Needs you with Yes/No and Hold blocked, the unblock widget with the Markdown editor and preview, the status bar with its pill rules, the Action menu (New idea, Choose an existing plan), the idea dialog and frontmatter form, Stop All Local with its confirmation, the help dialog, light and dark themes.
- **Libraries over hand-written code** wherever one fits: TanStack Query for server state, Radix primitives for menus, dialogs, tabs and selects, Tailwind for styling, Motion for animation, CodeMirror 6 for the Markdown editor, highlight.js for code, marked and DOMPurify for preview, `@microsoft/fetch-event-source` for SSE with reconnect.
- **Autocompact at 40%** for every Claude agent (W28), and the agents' prompts asking yes/no questions as yes/no (W30).

### Out, for now

- The copilot (c3po-operator, W17): the panel ships, wired to nothing but a placeholder, until its agent exists.
- Linear, review labels (plan 005) and plain `NNN` numbering (W21): their own plans.
- Authentication: the server binds to localhost and trusts its machine (W29).

## Done when

- [ ] `tilda run` starts the engine and the API server, prints the URL, opens the browser (unless `--no-open` or there is no display), and `--no-web` runs headless.
- [ ] The board updates within a second of a change in the engine, over SSE, and a reloaded or reconnected page shows the same state.
- [ ] Every command in the list above reaches the engine, is applied once even if delivered twice, and its reply shows on the page.
- [ ] Killing the API server or the engine mid-run loses nothing: on restart each picks up from Redis, and the page reconnects by itself.
- [ ] Two engines on two checkouts against one Redis each show the other read-only, and neither takes a plan the other has claimed.
- [ ] The page passes an axe check with no serious violations, works by keyboard alone, and respects `prefers-reduced-motion` and both themes.
- [ ] Ruby: `just lint` and `just test` green, line coverage of the new code at least 95%.
- [ ] Front end: `npm run lint`, `npm run typecheck` and Vitest green, coverage at least 95% of statements; Cypress runs the main flows (answer a question, hold blocked, add an existing plan, stop all local with confirm, switch model) against the API server on a fake engine, in CI.
- [ ] CircleCI builds the front end, runs Vitest and Cypress, and the gem package contains `web/dist`.

## How to verify

1. `redis-server` running, then `bin/tilda run` in a repository with plans. The browser opens on the board.
2. Answer a blocked agent's question from Needs you; the row moves on and the transcript shows the answer.
3. Start a second checkout of the same repository with `bin/tilda run`; each page shows the other machine's tab, read-only.
4. `kill -9` the API server; the page shows "reconnecting", then catches up when the server is restarted.
