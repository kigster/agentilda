---
name: tilda-run
description: Run tilda's specialist agents over `.plans/` until every plan reaches a fixed point, then clear blocked plans by getting the human's answers and running `tilda unblock`. Use when the user wants to run, start, resume or finish the agents, build or ship a plan, or unblock a ⭕️ / 🅱️ plan.
---

# tilda-run: drive the plans to a fixed point

Load the `tilda` skill first if it is not in context.

`tilda run` loops in rounds. Each round hands every movable plan to the agent its state and lane call for and renames the folder when the agent finishes. When a builder lands a plan at 🟢 Ready for Review, `tilda` pushes its branch and opens the pull request, titled `[NNN.MM]`; `hansolo-reviewer` then reviews that pull request. It stops at a **fixed point**: a round in which no plan changed state. Your job is to start it, watch it, and turn what it stops on into questions for the human.

## 1. Scope and preview

Decide the scope from what the user asked: the whole tree, or `--plan 003,005.01`. Then preview, unless the user has already told you to run:

```bash
tilda run -n --plan <NNN,...>
```

Each line names a plan, the agent it would get, and the round. Show the user the lines that matter in a few bullets and ask once: "Run these?" One yes covers the whole loop below.

Pick flags from the situation, and read `tilda run --help` for the rest:

| Situation                                        | Flag                                 |
| ------------------------------------------------ | ------------------------------------ |
| limit machine load or API spend                  | `-j <n>`, `--max-tokens <n>`         |
| the repository has no git                        | `--isolation shared` (serial; see below) |
| one agent is misbehaving                         | `--skip <agent>`                     |
| re-drive one agent with extra guidance           | `--agent <name> --prompt "<text>"`   |

Keep the defaults (`--isolation worktree`, pushing on) whenever the user wants plans reviewed. `--isolation shared` and `--no-git-push` open no pull request, so every plan stops at 🟢 and the reviewer never starts; `tilda run` warns when that is the case. Use them only when the user asks to keep work local, and say that review waits for a PR they open (`tilda resync prs` then records it).

## 2. Run it

```bash
tilda run --plan <NNN,...>
```

A run takes minutes to hours: each agent may take up to 15 minutes per round, over several rounds. Start it in the background and wait for it to exit; it prints its progress log path at the start, which is what to read when the user asks how it is going. Avoid polling in a tight loop.

A warning about `ANTHROPIC_API_KEY` (or a similar variable) at the start means every agent will authenticate with that key instead of the user's claude.ai login. Stop and ask before running with it; a stale key fails every agent with `401` after minutes each.

## 3. Read where it stopped

When it exits, `tilda list-plans` shows where each plan stands. Sort them into three groups:

- **Advanced to a human gate**: at ✅ Approved & Merged the reviewer has approved, and merging and deploying are the human's. Report the PR links (`gh pr list`).
- **Blocked** ⭕️ / 🅱️: go to step 4.
- **Unmoved without a block**: an agent failed or ran out of rounds. Read the plan's history with `tilda state show --plan <NNN>` and say which agent stopped and why. Re-run with a fix (`--agent`, `--prompt`, `--timeout`) only after telling the user what you will change.

## 4. Unblock

For each blocked plan:

1. `tilda unblock <NNN> -n` prints the open questions.
1. Put them to the human **one at a time**. ⭕️ questions are for an engineer, 🅱️ for product; say which.
1. Write each answer into the plan's `blocked.md` under `## A<n>`, matching its `## B<n>`. An answer counts only when it names who decided (a role is enough), carries today's date, and settles the question. "Leaning towards B" does not count, and the broker will leave it in place.

   ```markdown
   ## A2
   Decided 2026-10-12 by the CTO: rates are read from the vendor feed, never cached.
   ```

1. `tilda unblock <NNN>` folds the answers into `spec.md` / `plan.md` and renames the folder.

## 5. Loop

Go back to step 2 for the plans that moved. Done when a run ends at a fixed point with every remaining plan at a human gate or blocked on a question the human has chosen not to answer yet. Report:

- [x] plans that reached review or merge, with PR links
- [ ] plans still blocked, and whose decision each waits on
- [ ] plans that failed, and the reason
