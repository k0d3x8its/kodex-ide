# Composited-screen harness

A feedback loop for **paint bugs** — float stacking, clamping, overlap. These are
the bugs that geometry logging cannot settle.

Not picked up by `make test` (which globs `tests/*_spec.lua`, top level only).
Run manually.

## Why

`nvim_win_get_config().row` and `nvim_win_get_position()` report the values a float
was _configured_ with, not where it _rendered_. nvim silently clamps a float that
would not fit on screen and keeps reporting the pre-clamp numbers. So a log built
on those APIs is self-consistently wrong — it will agree with itself and disagree
with the screen.

This bit the subagent drill-in overlap bug for three investigation passes
(`widgets.lua`'s own `subagentlog()` is built on exactly those APIs; treat its clean
output as evidence of nothing where paint is concerned).

## How it works

`screen_harness.lua` runs a child nvim inside a `:terminal` buffer. The terminal
buffer holds the **composited frame — floats included — as plain text**, readable
with `nvim_buf_get_lines`. That makes overlap assertable.

Two things matter and are easy to get wrong:

- The child must start a real TUI in the pty (`-c luafile <scenario>`). `-l` runs
  headless and never paints.
- `screenstring()` in a plain `--headless` parent sees only the base grid; floats
  are absent entirely.

## Usage

```sh
CHILD_SCRIPT=$PWD/tests/screen/child_subagent.lua \
  nvim --headless -u NONE -l tests/screen/screen_harness.lua
```

The child prints a census to `CENSUS_PATH` (configured vs rendered) and the parent
dumps the numbered composited screen to stdout.

### Scenario knobs (`child_subagent.lua`)

| env             | default | purpose                                                                                                                                                                                   |
| --------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LASTSTATUS`    | `2`     | statusline rows                                                                                                                                                                           |
| `CMDHEIGHT`     | `1`     | cmdline rows — the bar's `vim.o.lines - 2` anchor assumes `1`                                                                                                                             |
| `TOP_OFFSET`    | `0`     | `1` adds a tabline; at `0` the view's top border wants row `-1` and gets clamped                                                                                                          |
| `BAR_ROW_COUNT` | `2`     | subagent rows in the switcher bar                                                                                                                                                         |
| `PANEL_PAD`     | `0`     | `1` emulates `set_bottom_pad` — **set this**, or the panel has content at every row and any uncovered row leaks a transcript line (a harness artifact that once got mistaken for the bug) |

## Known limitation

`SCREEN_ROWS`/`SCREEN_COLS` do not propagate to the pty — the child comes up 22x80
regardless, because `vim.o.lines` does not take in an `-l` headless parent. Fix by
sizing the window holding the terminal buffer rather than the global. The mechanisms
found so far are offset arithmetic and size-independent, but do not trust a
_negative_ result until this is fixed.

## The bug this was built for

`update_subagent_bar()` anchored the switcher bar with `row = vim.o.lines - 2`, which
assumes exactly one statusline row plus one cmdline row. Swept against rendered
frames:

| `cmdheight` | shipped                                                                                 | `relative="win"` fix |
| ----------- | --------------------------------------------------------------------------------------- | -------------------- |
| `0`         | **overlap** (8/8 combos) — view's bottom border paints over the bar's titled top border | ok                   |
| `1`         | ok                                                                                      | ok                   |
| `2`         | gap of 1 row                                                                            | ok                   |

Fixed by anchoring to the panel window instead (`widgets.lua subagent_bar_position()`).
36/36 across `cmdheight` × `laststatus` × tabline × bar count.

Reproduce the original failure (revert the fix first, or run the child's
`FIX_ANCHOR=0`):

```sh
FIX_ANCHOR=0 CMDHEIGHT=0 LASTSTATUS=2 TOP_OFFSET=1 PANEL_PAD=1 BAR_ROW_COUNT=2 \
  CENSUS_PATH=/tmp/census.txt CHILD_SCRIPT=$PWD/tests/screen/child_subagent.lua \
  nvim --headless -u NONE -l tests/screen/screen_harness.lua
```

The bar's `╭ SUBAGENTS ───╮` top border is absent from the output when the bug is
present. `FIX_ANCHOR=2` renders it correctly.

## Findings

`.work/findings/subagent-drill-in-overlap.md`
