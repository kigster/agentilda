# Resync Evals

## Goal

Put a number on how well `agentilda resync` files pull requests, so a change to the matcher, the prompt, or the model is measured rather than eyeballed. The number comes from running the full command against a fictional project whose correct answers are committed beside it, and it is recorded in Braintrust so runs can be compared over time.

## Non-goals

- Running the evals in CI. Every run spends model tokens and logs an experiment. They run by hand.
- Copying real qualified-at plans or pull requests into the fixture. The project is invented.
- A Python or TypeScript eval runner. The `braintrust` Ruby gem has native `Eval`, scorers and datasets, so the evals are Ruby inside the gem, and `bt` is for looking at results.

## Decisions

### The fixture

`example-project/` at the gem's root is a fictional product with:

- `.plans/` holding around eight plan folders in mixed states, each with a `spec.md` describing distinct work, some with `pull-requests.md`.
- `.prs/` holding around fifteen pull requests as `<number>.md` files in the `FakeGitHub` format from plan 002.00: frontmatter `number`, `title`, `branch`, `state`, `created_at`, `merged_at`, `head_sha`, `files` with `path`, `additions`, `deletions`; the description as the body.
- `plans.csv` with columns `before,after`: every folder the run should rename, by name. A folder that should not move is absent.
- `prs.csv` with columns `number,before,after`: every pull request the run should retitle. One that should not move is absent.

One pull request per pipeline path: branch match, plan-folder match by lines, Jabba high confidence, timeline placement into `NNN.01`, dev plumbing by regex, dev by Jabba's flag, a straggler minting a folder at the end of the stack, a stale `[DEV.00]`, a `[none]`, and a numbered title that is wrong and only fixable under `--force`. The only person named anywhere is Alan Turing.

### The run

`just eval` copies `example-project/` to a temporary directory, runs

```sh
agentilda resync --commit --fake-github-path .prs
```

inside the copy, then dumps what changed into `.plans-resync/plans.csv` and `.plans-resync/prs.csv` in the same shapes as the committed pair. A second case runs the same copy with `--force` and scores against `prs-force.csv`.

### Scoring

Per file, keyed on `before` for plans and `number` for pull requests:

- an expected row whose `after` matches is a hit;
- an expected row whose `after` differs, an expected row missing from the output, and an output row nobody expected are each one discrepancy.

`score = 100 × hits / (hits + discrepancies)`, so all right is 100 and all wrong is 0. The experiment records `plans_score`, `prs_score` and their mean, plus tokens and dollars spent, as metrics.

### Braintrust

`evals/resync_eval.rb` uses the `braintrust` gem's `Eval` with the two cases as the dataset, the run as the task and the two scorers above. `BRAINTRUST_API_KEY` comes from the environment, via the sopsy-encrypted `.env`, and `just eval` refuses with a message naming the variable when it is missing, and likewise when `claude` is not logged in. `bt experiments list --project agentilda` shows the history.

## What already exists

- Plan 002.00 supplies `--fake-github-path` and `FakeGitHub`.
- `bt` 0.16.2 and the `braintrust` gem 0.4.1 are installed.
- `just` recipes already wrap lint and test.

## Acceptance

- `just eval` with the committed fixture produces two scores and an experiment in Braintrust.
- Deleting one expected row from `prs.csv` lowers `prs_score` by exactly one row's worth.
- The fixture covers every branch of the pipeline, verified by a spec that runs `FakeGitHub` against it with a stubbed resolver and asserts each path is taken at least once.

## What we are trying to achieve


## Why it matters


## What already exists


## What research needs to settle

