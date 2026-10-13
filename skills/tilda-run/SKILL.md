---
name: tilda-run
description: Start the tilda factory with `tilda start` (engine plus control room, up until Stop All, questions and new plans through the page), or run tilda's specialist agents to a fixed point with `tilda run` and clear blocked plans with `tilda unblock`. Use when the user wants to start, run, resume or finish the agents, build or ship a plan, or unblock a ⭕️ / 🅱️ plan.
---

# tilda-run: drive the plans

Load the `tilda` skill first if it is not in context.

## `tilda start`: the factory with its control room

`tilda start` is the way to run the factory for a person. It is `tilda run` with the control room on, and it does not stop at a fixed point: when a plan blocks, palpatine-planner's questions included, it idles, shows the questions in **Needs You** on the page, takes the answer from there, drains it, and hands the plan back to its agent. It picks up plans created on the page, by `tilda create` in another terminal, or edited by hand, rescanning `.plans/` every 5 s (`--rescan`).

```bash
tilda start              # engine and control room on http://127.0.0.1:4747, browser opened
tilda start --no-open    # print the URL only
```

- It takes `run`'s flags except `-n` and `--no-web`. It needs Redis and refuses without it (exit 69).
- Every human decision goes through the page: answers, hold, wrap up, stop, models, new plans. **Stop All** stops the agents, the engine and the page. The terminal is output only.
- It never ends on its own, finished plans included. It needs no plans, and makes `.plans/` when missing; the page opens on **New idea**. Stop All, Ctrl-C, `kill -TERM` or the page's server going away end it, with exit 0; agents get the graceful stop and the page goes down with it.
- `tilda run` with its control room up behaves the same way: it stays until Stop All or the page goes. Headless (`--no-web`, no Redis, `-n`), it ends at a fixed point.
- Start it in the background, give the user the URL, and leave the answering to them on the page. Steps 1 to 5 below are the scripted, headless alternative.

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
| no browser (CI, a remote shell), or no page at all | `--no-open`; `--no-web` (`tilda web` can serve it later) |
| port 4747 taken, or Redis elsewhere              | `--port <n>`, `--redis-url <url>`    |

Keep the defaults (`--isolation worktree`, pushing on) whenever the user wants plans reviewed. `--isolation shared` and `--no-git-push` open no pull request, so every plan stops at 🟢 and the reviewer never starts; `tilda run` warns when that is the case. Use them only when the user asks to keep work local, and say that review waits for a PR they open (`tilda resync prs` then records it).

## 2. Run it

```bash
tilda run --plan <NNN,...>
```

A run takes minutes to hours: each agent may take up to 15 minutes per round, over several rounds. Start it in the background and wait for it to exit; it prints its progress log path at the start, which is what to read when the user asks how it is going. Avoid polling in a tight loop.

When Redis answers, the run also serves the control room on `http://127.0.0.1:4747` and opens it in the browser: the user watches the board there and can message, interrupt or stop an agent. Without Redis the run warns once and goes on headless; that is not a failure. To get the page, start `redis-server` (or pass `--redis-url`) before the run; `tilda-setup` has the details.

A warning about `ANTHROPIC_API_KEY` (or a similar variable) at the start means every agent will authenticate with that key instead of the user's claude.ai login. Stop and ask before running with it; a stale key fails every agent with `401` after minutes each.

## 3. Read where it stopped

When it exits, `tilda status` shows where each plan stands. Sort them into three groups:

- **Advanced to a human gate**: at ✅ Approved & Merged the reviewer has approved, and merging and deploying are the human's. Report the PR links (`gh pr list`).
- **Blocked** ⭕️ / 🅱️: go to step 4.
- **Unmoved without a block**: an agent failed or ran out of rounds. Read the plan's history with `tilda state show --plan <NNN>` and say which agent stopped and why. Re-run with a fix (`--agent`, `--prompt`, `--timeout`) only after telling the user what you will change.

## 4. Unblock

For each blocked plan:

1. `tilda unblock <NNN> -n` prints the open questions.
1. Put them to the human **one at a time**. ⭕️ questions are for an engineer, 🅱️ for product; say which.
1. Write each answer into the plan's `blocked.md` under `## A<n>`, matching its `## B<n>` (the format is in `tilda-documents`). An answer counts only when it names who decided (a role is enough), carries today's date, and settles the question. "Leaning towards B" does not count, and the broker will leave it in place.

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
