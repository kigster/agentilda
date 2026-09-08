# Semantic PR Resync

## Goal

Make `agentilda resync prs` file every pull request under the plan it actually implements, by judgment rather than by path arithmetic, and make `agentilda resync` a single command that reconciles folders, then titles, then folders again.

Today a pull request is matched by its branch name, then by which `.plans/` folder its diff touches, and everything else is stamped `[dev]` or given a folder in the gap after the furthest plan it can see. Titles already wearing `[DEV.00]` are restamped to `[dev]` without ever being looked at. Every one of those prefixes was written by this tool, not by a person, and a number of them are wrong. This plan replaces the fallback with a model that reads the pull request and the plan index, and it stops treating an old automatic prefix as a settled fact.

## Non-goals

- Embeddings, vector stores, or a similarity graph between plans and pull requests. Considered and rejected: cosine distance between a spec and a diff is a proxy for the question, and a model reading both answers it directly.
- A second agent runtime. RubyLLM and OpenRouter were considered and dropped; every model call goes through `claude -p`, the same seam every other agent uses.
- Ractors or a process supervisor gem. Each model call is already its own `claude` process on its own core; the existing thread pool fans them out.
- Porting the seven existing agents to anything. Only `jabba-resolver` is new.
- Drafting `spec.md` with a model for folders minted here. A minted folder copies the pull request description into `spec.md` and `plan.md` and stops.

## Decisions

### Which pull requests are judged

Every pull request whose title is unprefixed or carries `[dev]`, `[DEV.00]`, `[none]` or `[XXX]`. A title with a numbered `[NNN.MM]` prefix is left alone.

`--force` strips every prefix, numbered ones included, and runs the whole pipeline on every pull request. There is no seniority between the old algorithm's answer and the new one; the branch name still gets its vote in pass one, which is where most old numbers came from.

The `[DEV.00]` restamp shortcut is deleted. A stale marker is re-judged like any other unprefixed title.

### Pass one, deterministic

1. **Branch name.** `kig/018.01-verify` names `018.01`. Unchanged from today. A branch naming a plan that has no folder falls through instead of being flagged.
1. **Plan-folder paths.** When the diff's changed lines under one `.plans/NNN.MM/` folder are at least `FOLDER_SHARE` (0.8) of all changed lines, the pull request belongs to that plan. Lines, not files: `gh pr list --json files` returns `additions` and `deletions` per path. Paths matching `DevWork::NEUTRAL` other than plan folders are left out of the denominator.

What survives pass one goes to Jabba.

### Pass two, Jabba

`agents/jabba-resolver.md` is a definition file like the other seven. Frontmatter:

```yaml
name: jabba-resolver
description: Judges which plan a pull request implements, from its description and diff.
handles: []
model: haiku
effort: xhigh
budget: 0.50
allowed_tools: []
```

`handles: []` keeps it out of `run`'s dispatch. No `advances_to`, so it is read-only. `budget:` is a new frontmatter key forwarded as `--max-budget-usd`.

**One `claude -p` process per pull request**, fanned out with `Parallel.map` on `UI.default_jobs`. Accuracy over cost: the plan index travels with every call, which on Haiku is cents.

The prompt carries, for the pull request: number, title, body, branch, and every changed path with its added and deleted line counts. For every plan in the tree: the folder name and the first `SPEC_EXCERPT` (2,000) characters of `spec.md`.

Jabba answers through `--json-schema`, so the CLI guarantees the shape and Ruby parses it with no scraping:

```json
{
  "plan": "003.00",
  "confidence": 0.92,
  "reason": "Adds the DSL printer the visual builder spec calls for.",
  "dev": false
}
```

`plan` must be an ordinal that exists in the tree or `null`. A response that fails validation, names an unknown plan, or does not arrive is **no verdict**, never a guess.

**Verdicts are cached** under `~/.cache/agentilda/<owner>-<repo>/verdicts/<number>-<head_sha>.json`. A rerun asks the model nothing about a pull request whose head has not moved.

### Reading a verdict

In this order:

1. **Dev.** `DevWork.developer?(title, files)` first, free. Then Jabba's `dev: true`. Either gives `[dev]`.
1. **Assign.** `confidence >= ASSIGN` (0.8): the pull request takes that plan's prefix.
1. **Timeline.** `TIMELINE <= confidence < ASSIGN` (0.5 to 0.8): the pull request is placed in time. Each plan's span is the earliest to latest merge time of the pull requests already carrying its prefix; an open pull request contributes its creation time. The pull request becomes `NNN.01` (next free minor) of the plan whose span contains its time and whose last merge is nearest, or of the last plan whose span ends before it. A new folder is minted for it.
1. **Straggler.** Below `TIMELINE`, and not dev: a new folder at the end of the stack, `Ordinal.next_major`, retroactive status, `spec.md` and `plan.md` both holding the pull request description verbatim under a heading, `pull-requests.md` holding the row. `--no-adopt` flags it for a human instead of minting.

The three thresholds are constants in one place, `Resync::Prs::FOLDER_SHARE`, `ASSIGN`, `TIMELINE`.

### Writes under `--commit`

- Retitle on GitHub through `GitHub#retitle`.
- Rewrite `pull-requests.md` **wholesale** for every plan that gained or lost a pull request, from every pull request whose title carries that plan's prefix, via `PullRequests.upsert` so prose below the table survives.
- Mint the timeline and straggler folders.

### Dry run

The default. It runs every deterministic step **and every Jabba call for real**, caches the verdicts, prints the full proposed outcome, and touches neither `.plans` nor GitHub. It reports the tokens each call spent, read from the `result` event's own accounting, and their cost from the model's published rate, and prints the total at the end. A following `--commit` reuses the cache and asks the model nothing new.

### The composite command

`agentilda resync [--commit]` runs `dirs`, then `prs`, then `dirs` again. The second pass exists because `pull-requests.md` changes which state a folder's contents justify. It accepts the union of both subcommands' flags and forwards each to the child that understands it. If the first `dirs` fails it stops and says so; `prs` must not match titles against a tree that is half old names. `resync dirs` and `resync prs` keep working alone, unchanged in interface.

### A fake GitHub, for evals

`--fake-github-path DIR` swaps `GitHub` for `FakeGitHub`, which reads pull requests from `DIR/<number>.md` files with frontmatter `number`, `title`, `branch`, `state`, `created_at`, `merged_at`, `head_sha`, `files` (list of `path`, `additions`, `deletions`) and the description as the body. `retitle` rewrites `title` in the file. This is the seam plan 003.00's evals stand on.

## What already exists

- `Resync::Prs` with `from_branch`, `from_files`, `no_plan`, `flag`, and the `[DEV.00]` restamp.
- `Adoption`, which mints folders after the furthest visible plan. Its allocation logic survives; its choice of major is replaced by the timeline and straggler rules.
- `DevWork.developer?` with title patterns and the plumbing path list.
- `Executor`, which runs a definition file through `claude -p` with `--model`, `--effort`, `--allowedTools`, stream tracing and a token meter. Jabba needs a lighter invocation with no ledger, mailbox or control file, so a small `Resolver` spawns the same `Child` with `--output-format json --json-schema`.
- `Agents` parses frontmatter; it gains `budget`.
- `GitHub#pulls` fetches `files` as paths only; it gains `additions`, `deletions`, `createdAt`, `mergedAt` and `headRefOid`.
- `PullRequests.upsert` rewrites the table in place.
- `lib/agentilda.rb` already lists `resolver` among the components it loads when the file exists.

## Acceptance

- `agentilda resync prs` on a tree with an unprefixed pull request whose branch names a plan resolves it with no model call.
- A pull request whose diff is 90% under one plan folder resolves from the folder with no model call.
- A pull request with a `[DEV.00]` title is judged, not restamped.
- A pull request with a `[007.00]` title is skipped without `--force` and re-judged with it.
- A Jabba verdict at 0.85 assigns; at 0.6 places on the timeline and mints `NNN.01`; at 0.3 mints at the end of the stack; a malformed verdict is treated as none.
- A dry run calls the model, writes the cache, and changes no file and no title. The next `--commit` reads the cache and calls nothing.
- `agentilda resync --commit` renames, retitles, rewrites `pull-requests.md`, renames again.
- Coverage stays above the bar the suite already enforces.

## What we are trying to achieve


## Why it matters


## What already exists


## What research needs to settle

