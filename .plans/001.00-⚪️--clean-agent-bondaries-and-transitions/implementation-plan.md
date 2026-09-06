# Implementation plan for 001.00, the live contract between luke and rey

Written by luke-backend on 2026-09-06. `plan.md` already holds every line of code; this file records what actually landed, the interfaces the front end calls, who owns which file, and the proof that the halves are joined.

## Architecture in one paragraph

Agents state their progress in the documents they own. `Ledger` parses those dated notes. `Dispatcher` ticks once a second: it polls each running agent's document, settles exited processes against `StateMachine`, renames folders (the harness is the only thing that renames), starts successors, and persists each stage to `.plans/tmp/agentilda-state.json` through `StateFile`. `Child` owns the `claude` process and its pid; `Clock` writes WARN, WRAP_UP and STOP into the control file and kills sixty seconds past the deadline. `Executor` wires those together per invocation. `Board` is the read model the screen draws from. Rey's `Screen`, `Console` and `Keyboard` draw and take keys; `cli/run/run.rb` boots it all.

## The contract, what Rey's half calls

| Interface | Shape | On failure |
| :--- | :--- | :--- |
| `Board::Row` | `Data.define` in `lib/agentilda/board.rb`; fields as written in plan.md Task 8 | none, a value |
| `Runner::Attempt` | gains `round`, `file`, `model`, `status` | none, a value |
| `Dispatcher#board` | current `Board` snapshot for the tick | never raises |
| `Dispatcher#kill(ordinal)` / `#extend(ordinal, seconds)` | via `Executor::Handle`; kill writes STOP, waits 15 s, SIGKILL | unknown ordinal is a no-op |
| `Runner#call` | drives the dispatcher; Task 11 (Rey) adds the `yield dispatcher` before the loop | returns the attempts list |
| `Control::WARN`, `Control.write(path, word)` | in `lib/agentilda/control.rb` | raises on an unwritable path |

## Ownership

- Luke: everything listed in `plan-backend.md`, plus the component list in `lib/agentilda.rb`, plus `.standard.yml`.
- Rey: everything listed in `plan-frontend.md`.
- Shared, luke first: `lib/agentilda/runner.rb` (Rey applies one small edit after), `lib/agentilda.rb` (Rey adds one `require "tty/cursor"` line).

## Waves

Recorded in `plan-backend.md` and `plan-frontend.md`. Luke's units 1-8 ran as one concurrent wave of sub-agents because the code is pre-written and the files are disjoint.

## Integration proof

`spec/agentilda/dispatcher_spec.rb` (Task 8) drives a real `.plans` fixture through `Dispatcher` with a stubbed `Executor` and asserts the folder rename plus the state file. Rey's `spec/agentilda/cli/run_spec.rb` (Task 11) runs `agentilda run` end to end over the same fixture with `Console#paint` as `on_board`. Both green together is the proof.

## Amendments

- amended: `lib/agentilda.rb` component list carries `screen` and `console` already (luke added them; the `File.exist?` guard makes that safe before the files exist). Rey does not need to edit the list.
- amended: `.standard.yml` already existed on the branch with `ruby_version: 4.0` and `parallel: true`, which already stops the walk-up to `~/.standard.yml`. Task 13 Step 1 is therefore a no-op; the plan text (`ruby_version: 3.4`) is older than the file and was not applied.
- amended: `.gitignore` gets no `.plans/tmp/` line by hand; `StateFile#ensure_ignored!` writes it at runtime, per Task 7's code.
- amended: `spec/agentilda/clock_spec.rb` builds the lazy `subject(:clock)` in a `before` hook. As written in plan.md, examples that move `now[:t]` before their first reference to `clock` armed the deadline late and four examples failed. Implementation untouched.

## Status log

See the ledger block at the bottom of `plan.md`.
