# Control room design direction

The mockup beside this file is `control-room.html`: open it in a browser. It runs on sample data, and its simulation fakes the live updates.

## Subject, audience, job

- **Subject:** a run of agentilda. Plans move through a fixed set of states, each handled by a named agent, and end at a pull request that gets reviewed.
- **Audience:** one engineer, often late at night, with several plans in flight at once.
- **Primary job:** see at a glance where every plan stands and what each agent is doing and costing, then step in (answer, message, interrupt) without leaving the page.

## The idea: a transit board

The state machine already has the shape of a transit line. The spine is the trunk; the full, plan and quick lanes enter at different stations; a rejection loops back to Building. So every plan is drawn as **its own horizontal line**, and every line passes through **the same station columns**. Reading across a row tells you a plan's journey. Reading down a column tells you everything in Building right now.

- The station columns come from `StateMachine::SPINE`, and the agent under each station from `Agents::Registry` (`handles:`). Neither is hard-coded in the front end (decision W4).
- A **filled line** marks travelled stations. A **hollow ring** is a station the plan's lane skips. A **dotted line** is the road ahead.
- The **agents at work** hang under the plan's current station as cars. A pair (luke and rey) is two cars side by side. Each car shows the agent, its model, elapsed time, tokens in (↑) and out (↓), and its latest activity line. The model is a small borderless dropdown in the car's top-right corner (decision W24): the adapter's models, most capable first, with the current one selected. A change is queued for the agent's next round, so the car shows it in bold and the drawer reads "Sonnet 5.5, Fable 5.1 from its next round". The agent's name is the button that opens the drawer, and its hit area covers the whole car, so the dropdown sits on a layer above it rather than inside a button.
- The **PR terminus** shows the PR number, the CI result and the review label from plan 005 (L1).

## Tokens

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `--enamel` | `#E9EDF1` | `#0E1522` | page |
| `--plate` | `#FFFFFF` | `#151E2F` | rows, rail, drawer |
| `--ink` | `#13233F` | `#E4EAF3` | text, trunk |
| `--ink-soft` | `#5A6A82` | `#8D9AB0` | secondary text |
| `--lane-full` | `#1F5FD1` | `#5B8DF0` | full lane line |
| `--lane-plan` | `#C98700` | `#F0B43C` | plan lane line |
| `--lane-quick` | `#1E8C3A` | `#4CC76A` | quick lane line |
| `--alarm` | `#D1343B` | `#F06A6F` | rejected, failing CI, stop |
| `--highlight` | `#D35728` | `#D35728` | the highlight colour: the logo's orange, RGB (211, 87, 40). Machine bands in the merged board; white text on it |

The review labels keep the colours of plan 005 (L1).

**Lane washes:** each plan row is washed in its lane colour, blue for full, yellow for plan and green for quick, mixed into the plate at 18% in the light theme and 9% in the dark one (`--wash`). The author first asked for 40%, then for "much much darker" once it was on screen.

**Lane grooves:** rows are separated by a groove pressed into the board rather than a hairline: a 6 px channel inset 10 px from each edge, shadowed along its top and catching light along its bottom (`--groove`, `--groove-shade`, `--groove-light`). The channel is deeper and the highlight fainter in the dark theme.

**Type:** Overpass for everything. It descends from Highway Gothic, the US road-sign face, which is wayfinding type for a wayfinding board. Station names are set bold and tight. Barlow Condensed SemiBold sets the machine bands of the merged board, at the author's request, and nothing else. Overpass Mono appears in exactly one place: agents' activity lines, which really are terminal output. Every number uses tabular figures, so ticking counters don't jitter.

**Layout:** a top bar with the run's totals, the board on the left, and a rail on the right listing "Needs you" items (questions, interrupts). Selecting a car opens a drawer in place of the rail, with that agent's transcript and the message controls. Everything is left aligned. Below 960 px the rail drops beneath the board, and the board scrolls sideways inside its own frame, never the page.

```
┌ agentilda   Run 18 min   4 agents working   ↑ 1.24M  ↓ 86k   $14.20     [Stop All Local] [?] ┐
├─────────────────────────────────────────────────────────────────┬───────────────────┤
│           New  Researched  Planning  Building  UI  Review  PR   │ Needs you  2      │
│ 001.00    ●━━━━━━●━━━━━━━━━━●━━━━━━━━◉┄┄┄┄┄┄┄○┄┄┄┄┄○┄┄┄┄┄┄○     │ ┌ question ──────┐ │
│ Clean…                               [luke-backend][rey-frontend]│ │ answer box     │ │
│ 005.00                ○      ○       ●━━━━━━━━━━━━━━━━◉┄┄┄┄○     │ └────────────────┘ │
│ Review…                                         [hansolo]        │ ┌ interrupted ───┐ │
└─────────────────────────────────────────────────────────────────┴───────────────────┘
```

## Car colours and logs

- **A car is tinted by its agent's state:** green while it works, red while it is blocked. A red car swaps its activity line for the reason it is red (the question it asked, or "You interrupted it"), in up to two lines of plain type, and the label in its corner changes to "needs you" or "interrupted". A blocked agent's tokens stop counting, because it is waiting, not working.
- **Answering** works from the Needs you rail or from the agent's drawer, and needs actual text. ⌘ Enter (Ctrl Enter off a Mac) sends from any answer or message box, and each placeholder says so. The question and the answer both go into the agent's transcript.
- **The Logs tab** tails `.agentilda/log/engine.log` and `api.log` (decision W14) through the API server: filters for source and level, a text filter, and Follow, which turns itself off when you scroll up and back on at the bottom. While the tab is closed, a count of new warnings and errors shows on it.

## Test tabs and PR links

- **Each test run gets a tab** next to Board and Logs, labelled `001.00 tests` and carrying a small chip: "137 of 358" while running, "✓ 412" once passing, "3 failed" otherwise. The tab can be closed only once the run has finished. Inside: passed, failed and pending counts, a progress bar segmented by outcome, the failures with `file:line`, and the output with follow (decision W15).
- **While its agent runs tests,** a car's activity line reads "Running bundle exec rspec: 137 of 358".
- **PR numbers are links** that open the pull request on GitHub in a new tab. The URL comes from the board (`Board::Row#pr`), and is never assembled in the front end.

## Header and copilot

- **The logo** sits in the top-left corner, 30 px tall, set off by a divider: `docs/logos/long-rectangle-transparent.png` (light letters) on the dark theme and `long-rectangle-transparent-ink.png` (ink letters) on the light one, both without the tagline, which is unreadable at that height. The favicon is `docs/logos/square-large.png`.
- **The header names the project** (decision W18): its title from the manifest, its one-line description and its path, beside the logo.
- **The copilot** (decision W17) is a pop-up in the bottom right, 440 by 560 px, in its own colours, the same in both themes: a translucent blue header (`--copilot-head`, `#88b6ffe3`), a sage conversation (`--copilot-body`, `#bad6bf`), both with black text, and the composer on the header's blue with its text box and Send button on the inverted surface (`--inv-*` tokens), so it reads as floating above the board rather than as part of it. The author first had the whole pop-up inverted, then changed the header and conversation once it was on screen. Minimising it leaves a dark tab fixed to the right edge, reading "Copilot" vertically, with a green dot when there is a reply you have not seen. Esc minimises it. Stop and discard come back as a red card to confirm; a drafted answer comes back as a quiet card that puts the draft in the answer box without sending it. Its header shows its model and tokens, like a car. **It can be dragged** by its header (or moved with the arrow keys on its grip, Shift for bigger steps), stays inside the window and above the status bar, and keeps its place for the visit; every page load starts it glued to the bottom-right corner again. Double-click the header, or press Home on the grip, to put it back in the corner.
- **The status bar** is fixed along the bottom: one small pill per plan, showing the plan number and, on a second line, the time it has taken so far.
  - **Green with ✓:** reviewed and approved, ready to merge.
  - **Yellow with 🛠️:** an agent is working on it.
  - **Red with a block emoji from `status.rb`:** 🅱️ for a product question, ⭕️ for a technical block or an interrupted agent.
  - Working and blocked plans come first, in plan order. Finished plans sit after a divider on the right, in the order they finished, and a plan that finishes slides across to join them. Its clock stops when it finishes. In the unblock widget, an **Edit | Preview** switch sits just above the editor, flush with its right edge: Preview swaps the editor for the rendered answer at the same size (marked 12.0.2, sanitized by DOMPurify 3.1.6, fenced blocks coloured by highlight.js in Gruvbox), and Edit swaps back. Every question card, in Needs you and in the unblock widget, has **Hold blocked** beside Send answer: it parks the agent on purpose (no timeout or default answer moves it) and turns the plan's status-bar pill solid red with ⏸. The card says so, then fades out over 0.5 s and leaves Needs you (the widget closes the same way); the red pill is the way back. Opened from the pill, the card is tagged *held blocked* and offers *Release hold*, which returns the question to Needs you. Clicking a red pill toggles the **unblock widget**, docked at the top under the tabs and ringed in the highlight colour: the plan's question with an answer box as wide as the widget, a Markdown editor highlighted like the idea dialog's, 180 px tall and resizable, with Send answer to its right (or Keep work and resume, and Discard work). The draft is shared with the plan's card in Needs you. Clicking the same pill again hides it, as do Hide and Esc; another red pill swaps it to that plan, and it closes itself once the plan is unblocked. A blocked agent with no request opens its drawer instead. Any other pill switches to the Board and scrolls its row into view. A summary on the right reads "2 of 6 ready to merge, 3 blocked".

## Start dialog

- **`tilda start`** opens the page at `#start`, and **New idea** opens the same dialog during a run (decision W19). It is a native `<dialog>`: focus stays inside, and Esc steps back one view (plan editor → plans → idea) instead of discarding anything.
- **Three views in one dialog.** The idea ("What is the product or feature you'd like to build?"); the split, "Here is your idea broken up into plans. Confirm?", with one row per plan (`[009 Accounts and imports] [Accept] [Modify]`) and sub-plans indented under their parent; and one plan in the editor, titled "Editing 010: Import bank statements as CSV", with **Revert ↶** and **Save ✔**. Saving accepts the plan. **Create N plans** stays disabled until every plan is accepted.
- **The editor** is a transparent textarea over a highlighted copy of its own text, so typing, selection, undo and spellcheck stay native. Overpass Mono, the second place it appears, because Markdown source is code. Highlighting is done by **highlight.js** (11.9.0, cdnjs): Markdown for the prose, YAML for the frontmatter, and each fenced block in the language its fence names (Ruby, Python, JavaScript, TypeScript, shell, SQL, YAML, JSON and the rest of its common bundle). The page only colours its token classes, in **Gruvbox**: the light palette on the light theme, the dark one on the dark. Without the script, the text shows plain.
- **Frontmatter is a form above the editor, never text in it.** Lane, research, front end and depth are segmented controls in one row (the lane options carry their lane colours). Under each, two lines of soft text say what the current choice means and change with it (decision W23); they hold two lines' height even when shorter, so the row never jumps. Research is disabled, and says why, on the plan and quick lanes; "More settings" opens per-phase adapter, model and effort and the four list fields. The idea dialog shows the first three as defaults for every plan it becomes.
- **Plan numbers are plain `NNN`** everywhere in the mockup (decision W21).

**Tabs** are very faint pills: the ink colour at 4% with a 9% hairline, 8% on hover, 14% when selected, so they read as a quiet row rather than underlined tabs. A test tab's pill holds its close button.

## Other machines

- **Machines sharing one Redis** (decision W26) each get a tab at the far right of the tab bar, labelled `username@hostname` with a 🖥️, drawing that machine's plans exactly as the board draws ours, minus every control: cars are plain cards with the model as text, and the tab opens with "Read only. alex@build-01 is working on these in ~/src/agentilda; this machine will not start them. Last seen 4s ago."
- **All machines** in the header is a pressed-state toggle that appends every other machine's rows under ours on the Board, each machine opening with a band in the highlight colour (Barlow Condensed SemiBold, `username@hostname` at 24 px, then its IP, plan count, "read only" and last seen; ours gets one too, marked "this machine"), its rows at 85% opacity (first 25%, raised by the author once it was on screen). Fading by opacity rather than colour keeps the lane colours legible as lanes, while making it obvious which rows are not ours to touch.
- **The status bar** lists other machines' plans at its right end, after a hairline, as their tabs sit at the right of the tab bar: number and time like ours, 🖥️ while working and ✓ once approved, at 85% opacity. The tooltip names the machine and the station; a click opens that machine's tab.
- **This machine's name** sits in the project line under the logo ("On dana@studio-mini"), not among the run's numbers, which is where it was first put and where it pushed Stop run (now Stop All Local) onto a second line.

## Principles

1. **One bold thing: the lines.** Colour and motion go to the tracks. The cars, the rail and the drawer stay quiet: no shadows, a single hairline, white plates.
2. **Live is not loud.** Counters, timers and activity lines update in place, with no flashing and no animation. The one orchestrated motion is a plan **advancing**: its line fills to the next station and its cars slide there. Seeing a plan move is news; a ticking counter isn't.
3. **Structure carries information.** Station columns are real states, lane colours are real lanes, a hollow ring is a real skip. Nothing is numbered unless it really is a sequence.
4. **Words say what happens.** The buttons say "Send answer", "Keep work and resume", "Discard work", "Stop agent". Each action keeps one name all the way to its confirmation.

## Checked against the generic defaults

- The obvious agent-dashboard answer is a dark page with one neon accent, KPI tiles and a card grid. **Changed:** a light enamel page by default (dark is still supported), no KPI tiles (the run's totals are plain text in the top bar), and cars hanging off lines instead of a card grid.
- A first draft drew one shared transit map with plans as moving tokens. **Changed** after the author asked for one horizontal plane per plan: it hid per-agent tokens, and it stacked badly beyond about five plans.
- The meta strings in the top bar were going to be joined with middle dots. **Changed** to separate, spaced segments.
- A monospace face for labels is the common tell. **Kept** only for real terminal output.

## For the build (rey-frontend)

- React with shadcn/ui primitives: `Sheet` for the drawer, `Tooltip`, `Textarea`, `Button`, `Badge`. They are restyled with the tokens above, not left with the default shadcn look.
- Motion `layout` and `layoutId` move a car between stations; the line fill is a CSS transition on the segment. Under `prefers-reduced-motion`, both jump instead.
- One `EventSource` on the `board` stream (decision W13). Counters render straight from each snapshot; there is no client-side interpolation.

## Agent drawer: model and context

- **Model**, at the top of the drawer, switches that one agent now: the harness stops it at its next safe point, resumes the same session on the chosen model and runs `/compact` first. Its car's dropdown follows. The car's own dropdown still queues a change for the next round (W24); the drawer's is for an agent that is stuck or struggling now (W27).
- **Context** shows how full the agent's window is, as a bar with a highlight-colour mark at 40%, where every agent autocompacts (W28). An autocompaction lands in the transcript and the log ("Autocompacted at 40% of its context: 80.2k → 17.6k").

## Stop All Local and the help pill

- **Stop All Local**, formerly Stop run, stops every agent on this machine. Other machines keep running; nothing here can stop them (W26, W29).
- A round **?** pill to its right opens the help dialog: a native `<dialog>`, closed by Got it, Esc or a click outside, returning focus to the pill.

### Help dialog

> **Copy: the author writes this.** The mockup carries a draft so the dialog has something to show; replace it here and in `control-room.html` (`#help`).

What it has to say:

- This is a distributed software factory: every machine on the same repository and the same Redis works the same set of plans.
- You join by sharing `$REDIS_URL`. There is no other mechanism.
- Anyone connecting from a clone of the same GitHub repository is in. Nobody can be kept out or kicked out.
- It is not a policy enforcement system. It assumes everyone around is friendly.
