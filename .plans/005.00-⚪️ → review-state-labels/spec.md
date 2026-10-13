# Review State Labels

## What we are trying to achieve

Every pull request a plan opens carries exactly one review-state label, which shows on GitHub where its review stands:

| Label | Colour | Meaning | Applied by |
| --- | --- | --- | --- |
| `ready-for-review` | light green | PR open, reviewer not yet on it | the harness, when it opens the PR |
| `review-in-progress` | light yellow | hansolo-reviewer is reviewing it | hansolo-reviewer, when it starts |
| `approved` | deep green | approved, CI green | hansolo-reviewer |
| `approved-with-caveats` | yellow | approved, with findings worth a follow-up | hansolo-reviewer |
| `rejected` | red | changes requested | hansolo-reviewer |
| `approved-despite-ci` | orange | approved while CI is red, with a PR comment saying why | hansolo-reviewer |

Labels that are missing from the repo are created before first use. Moving to a new state removes the previous state's label.

No pull request is approved while its CI is red, unless it also carries `approved-despite-ci` and a top-level PR comment explaining why the failure does not block it. The harness enforces this; the prompt only asks for it.

## Why it matters

Today a reviewed PR looks the same on GitHub whether it is waiting, being reviewed, approved or rejected. Its state lives only in `pull-requests.md` and `state.json`. Nothing stops an approval over red CI.

## What already exists

- Settled decisions: `docs/decisions/decisions-on-web-ui-and-review-labels.md` (L1 to L7).
- `agents/hansolo-reviewer.md`: currently `may: [gh pr review, gh pr comment]`.
- `lib/agentilda/execution/executor.rb:127`: `FORBIDDEN_COMMANDS` (includes `gh pr edit`, through which labels are set) and `UNGRANTABLE`.
- `lib/agentilda/vcs/publisher.rb`: opens the PR, the place to apply `ready-for-review`.
- `lib/agentilda/vcs/github.rb`: the `gh` seam, which specs replace with a double.
- `lib/agentilda/plans/pull_requests.rb`: `STATES`, the review vocabulary as `pull-requests.md` records it.

## What research needs to settle

- Which `gh` calls create and swap labels idempotently (`gh label create --force`? `gh pr edit --add-label/--remove-label`?), and how do they fail on a fork or a repo where the token cannot manage labels?
- What counts as "red CI" in `gh pr checks`: failing only, or failing and cancelled? How should pending checks be treated? (Decision L5 proposes waiting.)
- Should the label states be derived from `PullRequests::STATES`, or the other way round, so the vocabulary is written down only once?

## What we are trying to achieve


## Why it matters


## What already exists


## What research needs to settle

