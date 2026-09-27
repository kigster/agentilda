# Agent and workflow evals

This directory starts the evaluation corpus for [the factory proposal](../docs/software-factory-proposal.md). `cases.jsonl` contains synthetic scenario specifications with expected outcomes. There is no executable evaluation runner yet, and these cases have not been run against live agents.

Each row has a stable `id`, a `target`, a `problem_type`, an `input` evidence object, an `expected` contract and `checks` naming deterministic or human-reviewed assertions. Never give the expected answer to the agent being evaluated. These initial cases belong to the development set, not a claimed held-out benchmark.

## Execution contract to implement

1. Load a case and construct an isolated fixture repository or replay provider.
2. Run the target with only its input, pinned prompts and configured limits.
3. Capture artifacts, changed files, process events, usage and exit status.
4. Score actual behavior against `expected`; a claim in a response is not proof.
5. Export sanitized scores and trace references to a Braintrust experiment, with dataset, prompt, provider and config versions.

PR 7 in the proposal adds `run.rb`, fixture repos, scorers and offline/live recipes. Ordinary CI should run fixtures and replays without credentials. Live evaluation must require an explicit mode and a total spending cap. Do not run live credentialed jobs on untrusted pull requests.

## Coverage to expand

| Target | Primary measure | Additional problems |
| --- | --- | --- |
| Leah | Correct reuse references per bounded lookup | Upstream uncertainty; no existing reusable component |
| Yoda | Acceptance criteria clarified without scope changes | Contradictory brief; unresolved product choice |
| Palpatine | Executable graph with correct ownership | Shared schema; independent tasks; oversized task |
| Luke | Acceptance tests pass within owned code | Migration, concurrency bug, review repair |
| Rey | Functional and accessible interaction | Loading/error/empty states, API incompatibility, terminal UI |
| Han | Seeded defect recall and false findings | Missing authorization, stale evidence, valid implementation |
| Lando | Answer applied only to its matching blocker | Partial answers, contradictory answers |
| Routing | False skip rate and abstention | Backend only, UI only, mixed work, absent evidence |
| Scheduler | No unsafe concurrent admissions | Shared resources, restarts, unmerged dependencies |
| Readiness | Zero false-ready decisions | New commits, base changes, missing CI, unresolved findings |

Add executable acceptance tests to coding fixtures and seeded defects to review fixtures. Human-label routing cases before using them for threshold selection. Split by repository/problem family into development and held-out datasets; evaluate each live case repeatedly and report failures as well as cost and latency. Keep secrets and private source out of committed fixtures.
