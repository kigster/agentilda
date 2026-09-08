# Tidewatch, an example project

A fictional product — tide tables, mooring bookings and invoicing for small harbours — whose `.plans/` and `.prs/` exercise every path of `agentilda resync`. The only person named anywhere is Alan Turing.

- `.plans/` is a plan tree in mixed states, including one folder written before the `NNN.MM` padding rule.
- `.prs/` stands in for GitHub: one markdown file per pull request, frontmatter for the facts and the body for the description. `agentilda resync --fake-github-path .prs` reads them and writes retitles back.
- `plans.csv` and `prs.csv` are the right answers: every folder rename and every retitle the run should make. `prs-force.csv` is the answer under `--force`.
- `verdicts.yml` is what `jabba-resolver` is expected to say about each pull request that reaches it. The offline spec stubs the judge with it; the live eval measures how close the real model comes.

Run the evals with `just eval`.
