# Ratatui TUI dashboard for `agentilda run`

Date: 2026-09-11
Status: approved, pending implementation plan

## Problem

`agentilda run --commit`'s live dashboard (`Screen`, driven by `Board`/`Console`/
`Keyboard`) redraws by clearing to end-of-screen and reprinting raw ANSI escape
sequences once a second. It works, but the fixed-width-cell-plus-manual-fit
approach reads as noisy/flickery in practice, has no real widgets (gauges,
sparklines), and hand-rolls row selection by inverse-painting text.

## Goal

Add a second, opt-in rendering backend built on the `ratatui_ruby` gem
(v1.5, native Rust bindings), selectable per run, without touching the
existing default path or any other `UI.concurrently` caller.

## Non-goals

- Replacing the default backend. `spinner` (today's `Screen`) stays the
  default; nothing changes for a run that doesn't opt in.
- Touching any UI surface other than `agentilda run`'s live dashboard
  (spinners/boxes/progress bars elsewhere are untouched).
- A fallback path for a missing/broken `ratatui_ruby` install — it is a hard
  gemspec dependency (decided), so `--tui ratatui` either works or the gem
  failed to install, same as any other dependency.

## Selection

- `--tui ratatui|spinner` CLI flag on `agentilda run`, default `spinner`
  (today's `Screen`, kept under that flag name since it's the one users
  already associate with the existing dashboard).
- `AGENTILDA_TUI` env var as a fallback when the flag isn't passed.
- Flag wins when both are set.

## Architecture: reuse the data/interaction layer, replace only rendering + input

Today: `Dispatcher#tick` builds a `Board` (pure data, one snapshot per second)
and calls `on_board.call(board)`, which is `Console#paint`. `Console` holds
selection/dialog state and calls `@screen.draw(board...)`. `Keyboard` reads
raw stdin on its own thread and calls methods on `Console` (`select_next`,
`toggle_kill`, `extend`, `apply`, `escape`, `toggle_help`) plus a few that go
straight to `Control` (`wrap_up!`, `stop!`, `quit!`).

None of `Board`, `Console`, `Keyboard`'s *behavior*, or `Dispatcher` changes.
Only `Screen` gets a sibling implementation.

### Why the loop has to invert

`ratatui_ruby` does not support "call draw whenever you have new data" from a
background thread — it owns a blocking loop:

```ruby
RatatuiRuby.run do |tui|
  loop do
    tui.draw { |frame| ... }
    event = tui.poll_event   # ~60fps default tick; Event::None if nothing
    break if quit
  end
end
```

`RatatuiRuby.run` also enters raw mode + the alternate screen itself and
restores the terminal on exit, so a second stdin reader (today's `Keyboard`
thread, via `io/console#getch`) would fight it over terminal state.

### `Screen::Ratatui`

- `#open` spawns a dedicated thread running `RatatuiRuby.run`. That thread
  owns the render+input loop for the rest of the run.
- `#draw(board)` — called by `Console#paint` from the dispatcher's own
  thread, exactly as today — just stores the `Board` behind a `Mutex`. No
  rendering happens on this call; the ratatui thread picks it up on its next
  tick (~16ms later, imperceptible).
- Each tick: render from the stored `Board`, then `tui.poll_event`. A key
  event is translated to the string `Keyboard#handle` already expects
  (`"h"`, `"?"`, `"s"`, `"\e[A"`, `"\e[B"`, `"k"`, `"x"`, `"\r"`, `"\e"`,
  `"w"`, `"n"`, `"q"`, ctrl-c → `""`) and handed to a `Keyboard`
  instance built with `Keyboard.new(sink: console)` — never `.start`, so it
  never spawns its own stdin thread. All key semantics are reused verbatim;
  nothing about kill/extend/wrap-up/quit/dialog logic is reimplemented.
- `#close` signals the loop to stop and joins the thread, so
  `RatatuiRuby.run` has a chance to restore the terminal before `run.rb`'s
  `ensure` block returns.
- In `run.rb`, when `--tui ratatui` is selected (`spinner` is the default),
  `Keyboard.listen` (which starts the stdin-reading thread) is skipped; a
  non-started `Keyboard.new` is built instead and handed to
  `Screen::Ratatui`, so `interactive:` and `keyboard&.stop` at the call site
  keep working unchanged.

## Layout

Built with `tui.layout_split(area, direction:, constraints:)` using
`constraint_length`/`constraint_fill`, top to bottom:

1. **Top bar** — status/clock/plans-in-work/token totals, same content as
   today's `top_bar`, as a styled `paragraph`.
2. **Table** — `tui.table(header:, rows:, widths:, row_highlight_style:)`
   rendered via `frame.render_stateful_widget(table, area, table_state)`.
   Columns: timestamp, plan, feature/file, agent (**bold yellow**), round,
   model, subagent count, tokens ↑↓, elapsed (`tui.line_gauge`), time left
   (`tui.line_gauge`), then the activity message as the last column,
   stretching to fill remaining width (a `constraint_fill(1)` column).
   - `TableState` replaces the current hand-rolled "inverse-paint the
     selected row" and "count what doesn't fit" logic: build one `TableState`
     per frame, call `.select(index)` for `board.selected`'s row (nil when
     nothing is selected), and let the widget's own scroll offset handle
     rows that don't fit rather than a manual `split`/"+N more" count.
3. **Bottom bar** — working directory, running-agent count, live tokens,
   plus a `tui.sparkline` showing the running-agent count over time.
4. **Overlays** — dialog (kill/extend confirmation) and help, both as a
   centered `tui.block`, same content as today's popups.

## Color rules (as specified)

- Agent name: bold yellow, always.
- Elapsed-time gauge: green under 15 minutes, yellow at/over 15 minutes.
- Time-left gauge: green over 15 minutes remaining, yellow under 15 minutes,
  red under 5 minutes.
- Everything else keeps today's palette (magenta ↑ tokens, cyan ↓ tokens,
  red/white for failed rows, etc.) translated 1:1 into `tui.style(fg:, bg:,
  modifiers:)`.

## Sparkline history

A small ring buffer of running-agent counts, sampled every 10 seconds off a
monotonic clock and shifted left as new samples arrive — owned by
`Screen::Ratatui` itself, not by `Board`. This is a display-only concern:
`Board` stays exactly the pure, timestamped snapshot the `spinner` backend
already relies on, so nothing about `Dispatcher`'s tick rate or `Board`'s
shape changes for either backend.

## Testing

`ratatui_ruby` ships `RatatuiRuby::TestHelper` — an in-memory `TestBackend`
(`with_test_terminal`, `assert_fg_color`, `assert_area_style`, snapshot
assertions) and plain `MockFrame`/`StubRect` doubles, so a `render(frame,
area)` method can be unit tested without a real terminal, no mocking of our
own objects, matching the project's existing "don't mock what you can build
for real" convention. `spec/agentilda/screen_ratatui_spec.rb` covers this
the same way `screen_spec.rb` covers the `spinner` renderer: real `Board`/`Row`
data in, cell content and style asserted out.

## Files touched

- `agentilda.gemspec` — add `ratatui_ruby` as a runtime dependency.
- `lib/agentilda/screen/ratatui.rb` — new.
- `lib/agentilda/screen.rb` — no behavior change; this is the `spinner`
  backend, possibly renamed/namespaced for symmetry with `Screen::Ratatui`
  (implementation plan's call).
- `lib/agentilda/keyboard.rb` — no behavior change; used both started
  (`spinner`) and unstarted (`ratatui`, driven externally).
- `lib/agentilda/cli/run/run.rb` — add `--tui` option, `AGENTILDA_TUI` env
  fallback, backend selection at the `screen = ...` line.
- `spec/agentilda/screen_ratatui_spec.rb` — new.
