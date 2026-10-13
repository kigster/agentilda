---
name: tilda
description: The agentilda software factory (`tilda` CLI) that drives `.plans/` folders through spec → plan → build → review with specialist agents. Use when a project has `.plans/` or `.tilda.yml`, when the user mentions tilda, agentilda, plan folders or the factory, or asks how a plan moves between states, or wants to start a project or set up tilda. Loads before tilda-start, tilda-spec, tilda-documents, tilda-run, tilda-status and tilda-sync.
---

# tilda: the software factory

`tilda` (alias of `agentilda`) turns a few words into a merged pull request. A human writes intent into `spec.md`; specialist agents research, plan, build and review it; `tilda` moves the plan from state to state until nothing changes. Merge and deploy stay human.

## Which skill does the job

| The user wants to                                            | Load           |
| ------------------------------------------------------------ | -------------- |
| start a project on tilda, or fix a missing project root (exit 66) | `tilda-start` |
| start a feature or task, pick its lane, add implementation detail | `tilda-spec`   |
| write or fix a file in a plan folder: `blocked.md`, `spec.md`, `pull-requests.md` | `tilda-documents` |
| run the agents until the plans are done; clear a blocked plan | `tilda-run`    |
| see where plans stand, a plan's history, an agent's mailbox, the control room | `tilda-status` |
| fix folder names, PR titles, or export to Linear             | `tilda-sync`   |

## Before any command

1. `command -v tilda` must answer. Otherwise tell the user to install the gem (`gem install agentilda`) and stop. These skills ship inside the gem; after a gem upgrade, `tilda skills install --overwrite` refreshes them in `~/.agents/skills`.
1. `tilda` finds the project root by itself: the nearest ancestor holding `.tilda.yml` or `.plans/`, else the nearest `.git`. With none of them, project commands exit 66; load `tilda-start`. `init`, `docs`, `states`, `agents`, `describe`, `skills`, `eval`, `completion` and `version` need no project and still work.
1. Bundler errors inside a Ruby project (a Gemfile that is not agentilda's) come from the calling shell's Bundler variables. Re-run in a subshell: `(unset BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION RUBYOPT RUBYLIB; tilda …)`.
1. A flag these skills use being rejected (`-n`, or output saying `Re-run with --commit`) means the `tilda` on PATH is older than the skills: an rbenv shim or a stale gem shadowing the one that installed them. `which -a tilda` and `tilda version` show which; call the right one by its full path and tell the user.
1. `--help` on any command or subcommand is the source of truth for flags (`tilda resync dirs --help`). Read it rather than guessing a flag.

## The model in four facts

- **The folder name is the state.** `.plans/003.00-⭐️ → tax-rule-dsl` is plan `003.00`, state Planned, slug `tax-rule-dsl`. There is no database. Folder names hold emoji and spaces, so quote every path. Refer to a plan by its ordinal (`003`, `003.01`) wherever a command accepts one.
- **Numbers are identity.** `NNN.00` is a new feature; `NNN.MM` with `MM > 0` documents work that already shipped (Retroactive). An ordinal is never renumbered.
- **Lanes route a plan.** `full`: research, spec, plan, build, review. `plan`: the author's spec stands; plan, build, review. `quick`: one agent (`r2d2-mechanic`) does a short mechanical change, then review. The lane lives in `spec.md` frontmatter.
- **Blocked means a human decides.** ⭕️ is a technical block (engineer), 🅱️ a product block (product). The questions sit in the plan's `blocked.md`; agents step around the plan until they are answered.

Live references, never copied here so they cannot go stale:

- `tilda states`: every state, its emoji, and the legal transitions.
- `tilda agents list`: which agent handles which state, its model, its lanes.
- `tilda docs`: the full conventions document, generated from the state machine.

## Project config: `.tilda.yml`

At the root, written by `tilda init`. Keys: `project` (name), `lane` (default lane for new specs), `frontend` (whether the project has a front end; a spec's own `frontend:` wins), `jobs` (plans worked at once), `redis_url` (the Redis behind the control room), and `commands:` (per-command option defaults, e.g. `run: { timeout: 1800 }`). Precedence: CLI flag, then the plan's `spec.md`, then `.tilda.yml`, then built-in defaults.

## Every write is real

Commands do their work when run. `-n` / `--dry-run` previews and changes nothing. A run pushes branches and opens pull requests, so preview before a broad command whenever the user has not already said to go ahead.
