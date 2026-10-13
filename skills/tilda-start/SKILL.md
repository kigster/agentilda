---
name: tilda-start
description: "Start a project on tilda: check the prerequisites, run `tilda init`, install the skills, and create the first plan. Use when the user wants to start a new project with tilda, set up tilda, bring an existing repository onto it, or when a tilda command exits 66 with no project root."
---

# tilda-start: put a project on tilda

Load the `tilda` skill first if it is not in context. Read `<command> --help` before using a flag here.

## 1. Prerequisites

Check each, then report every gap at once with its fix. Ask before installing anything system-wide.

| Check | Fix when it fails |
| --- | --- |
| `command -v tilda && tilda version` | `gem install agentilda` |
| `git rev-parse --show-toplevel` | offer `git init`; without git, `tilda run` needs `--isolation shared` and opens no pull request |
| `gh auth status` | `gh auth login`; a "token in GH_TOKEN is invalid" line means `unset GH_TOKEN` and retry |
| the agents' CLI: `command -v claude`, the default adapter, or `codex` / `pi` when the plans' `spec.md` select them per phase | install the CLI the plans use; `tilda agents list` shows each agent's adapter |
| Redis answers at the URL tilda will use (order below): `url=$(ruby -ryaml -e 'puts((YAML.safe_load_file(".tilda.yml") rescue {}).to_h["redis_url"])' 2>/dev/null); redis-cli -u "${url:-${REDIS_URL:-redis://localhost:6379/0}}" ping` | start `redis-server`, or point tilda at another Redis (below) |

Redis carries the control room, its commands and plan claims. Without it `tilda run` still works, headless, and says so. tilda looks for it in `--redis-url`, then `redis_url:` in `.tilda.yml`, then `$REDIS_URL`, then `redis://localhost:6379/0`; `tilda web` checks `$AGENTILDA_REDIS_URL` before all of those but the flag.

## 2. `tilda init`

Run it at the repository root. Infer values from the repository, say them in one line, and wait for a yes:

- `--project`: the product's name, else the directory name.
- `--lane`: `full` unless the user writes complete specs themselves (`plan`).
- `--[no-]frontend`: `--frontend` when there is a `web/`, `app/javascript/`, `package.json` with a UI framework, or views; `--no-frontend` for a library or CLI; leave it out when plans differ.
- `-j`: leave the default unless the user wants to limit load.

> Project **Acme**, lane **full**, **front end** (a `web/` React app), default jobs. OK?

Then `tilda init -y <flags> -n` to show the file, and the same without `-n` to write `.tilda.yml` and create `.plans/`. An existing `.tilda.yml` is kept unless `--overwrite`.

If the repository has a database and a `CLAUDE.md` or `AGENTS.md`, offer one line there naming its PostgreSQL class (`PG-lax`, `PG-strict` or `PG-analytics`), so every agent assumes the same rules.

## 3. Skills

```bash
tilda skills install -n                      # what would be installed, kept, replaced
tilda skills install                         # into ~/.agents/skills
tilda skills install --into ~/.claude/skills # when the user's agent reads another directory
```

After a gem upgrade, `--overwrite` replaces the copies already there.

## 4. The first plan

Hand off to `tilda-spec` to create and write the first plan. A new project's first plan is `000.00`. Then:

```bash
tilda run -n --plan 000
```

and offer `tilda-run` to start the agents.

## Done when

- [ ] `tilda status` lists the plan.
- [ ] `tilda run -n --plan 000` names its first agent.
- [ ] With Redis up, `tilda web --demo` opens the control room on a sample run (Ctrl-C to stop).
