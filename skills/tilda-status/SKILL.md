---
name: tilda-status
description: "Report where tilda plans stand: every plan's state and pull requests, the INDEX.md, one plan's agent history from state.json, or the messages in its mailbox. Use when the user asks for the status, progress or history of plans, what an agent did or said, or wants .plans/INDEX.md regenerated."
---

# tilda-status: where the plans stand

Load the `tilda` skill first if it is not in context. Every command here only reads, apart from `index`, which writes one file.

| Question                                         | Command                                                     |
| ------------------------------------------------ | ----------------------------------------------------------- |
| every plan, its state, its pull requests         | `tilda list-plans`                                          |
| a shareable page of every plan                   | `tilda index` writes `.plans/INDEX.md`; `-o -` prints it    |
| which agents ran on a plan, how long, what model | `tilda state show --plan <NNN> \| jq '.stages[] \| {agent, round, status, model, seconds}'` |
| what one agent told another                      | `tilda mail read --plan <NNN> --for <agent>`                |
| what a blocked plan is waiting on                | `tilda unblock <NNN> -n`                                    |
| which agent picks a plan up next                 | `tilda run -n --plan <NNN>`                                 |

## Reporting

`list-plans` draws a table on STDOUT; pass `-C` when you parse it. Summarise for the user rather than pasting the table:

- a count per state, from the footer line
- each blocked plan, and whether it waits on engineering (⭕️) or product (🅱️)
- each plan in review, with its PR
- anything that looks wrong: a plan whose folder name lags its contents, or a PR without an `[NNN.MM]` title prefix. Both are `tilda-sync`'s to fix; offer it.
