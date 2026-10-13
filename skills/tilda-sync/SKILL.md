---
name: tilda-sync
description: "Bring tilda's `.plans/` back in step with reality: rename folders whose names lag their contents, prefix pull request titles with their plan's `[NNN.MM]`, adopt orphan PRs as retroactive plans, and export plans to Linear. Use when folder names, PR titles or Linear issues disagree with the plans, or the user wants plans in Linear."
---

# tilda-sync: reconcile the plans with git, GitHub and Linear

Load the `tilda` skill first if it is not in context. Each of these writes to something shared, so preview with `-n`, show the user what would change, and run without `-n` once they agree.

## Folder names: `tilda resync dirs`

A folder's name is its state, and its contents say which state it has earned (a `plan.md` means at least Ready for Planning). When the two disagree, `resync dirs` renames the folder to match, through `git mv` so history follows. `tilda run` does this itself every round; run it by hand after editing plan files directly.

## Pull request titles: `tilda resync prs`

Every PR belonging to a plan is titled `[NNN.MM] …`. `resync prs` adds missing prefixes. A PR that matches no plan gets a retroactive plan folder of its own (`--no-adopt` lists them for the human instead). Use `--state open` to stay clear of old, closed PRs. Needs `gh` logged in; a `401 Bad credentials` usually means a stale `GH_TOKEN`, so retry under `(unset GH_TOKEN; tilda resync prs …)`.

## Linear: `tilda linear import <TEAM> -p <project>`

One issue per plan, one child issue per work unit, filed under one Linear project. `tilda linear projects <TEAM>` lists the team's projects and which plans each already covers; use it to pick `-p`. The command computes the issues but does not write to Linear itself: run it with `--format json` and create each issue through the Linear MCP tools with exactly the arguments it emits. It is a one-way export: edits made in Linear are never read back. Narrow with `--since 010.00` or `--status building,in_review`.

Done when the preview of each command you ran shows nothing pending.
