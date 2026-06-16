# Post-Mortem: OpenCode / dev-terminal layout + dead `<C-x>`

**Date:** 2026-06-15
**Severity:** Medium
**Component:** `lua/plugins/toggleterm.lua`, `lua/utils/term_toggle.lua`, `lua/utils/opencode.lua`, new `lua/utils/term_layout.lua`

## What happened
Three linked symptoms. (1) Opening the dev terminal (`<C-x>`) then OpenCode
(`<leader>oc`) put OpenCode as a horizontal strip **under** the terminal instead
of a vertical 40% panel on the right. (2) With OpenCode open, `<C-x>` did
**nothing** — the dev terminal never appeared. (3) After the first two fixes,
opening the dev terminal while OpenCode was up dropped it full-width **below
both** windows instead of under the editor only.

## Root cause
Two independent causes:

- **Layout coupling.** toggleterm groups terminal splits. `ui.open_split`
  (`ui.lua:310`) calls `find_open_windows()`, which matches *any* window whose
  buffer filetype is `toggleterm`. So when a second terminal opened while the
  first was visible, toggleterm set the current window to the existing terminal
  and ran its `existing` split command — `rightbelow split` for a vertical term
  (→ OpenCode stacked horizontally under the dev term) and `rightbelow vsplit`
  for a horizontal term (→ dev term as a thin full-height column right of
  OpenCode). Confirmed with a headless geometry harness against the real plugin.

- **Dead `<C-x>` in terminal mode + a duplicate binding.** `<C-x>` was bound by
  the lazy `keys` spec in normal mode only. With focus inside the OpenCode TUI
  you are in *terminal* mode, where that bind never fires, so the key fell
  through to OpenCode and did nothing. Separately, `toggleterm.setup` passed
  `open_mapping = [[<c-x>]]`, installing a competing global `<C-x>` →
  `<count>ToggleTerm` (smart_toggle, which *closes* open terminals) — a latent
  normal-mode conflict with the intended `toggle_dev` bind.

## Fix applied
- Removed `open_mapping` from `toggleterm.setup` — `<C-x>` is now owned solely by
  the lazy `keys` spec.
- Added `mode = { "n", "t" }` to that spec so `<C-x>` reaches `toggle_dev` from
  inside any terminal panel.
- New `lua/utils/term_layout.lua`: `place_vertical` (`wincmd L` + width) pins a
  panel to the far-right full-height column; `place_horizontal` re-homes a strip
  directly below the editor window via `win_splitmove`. Each terminal calls the
  matching one in `on_open`, defeating the grouping.

**Iteration 2 (blank OpenCode).** The first cut of `place_horizontal` used
`wincmd J` plus `opencode.reassert_panel()`, which focused OpenCode's window and
moved it with `wincmd L` on every dev-terminal open. Moving a live full-screen
TUI's window strands it on a stale alternate screen → OpenCode rendered
**blank/black** whenever the dev terminal opened/reopened while it was up. Fix:
`place_horizontal` now uses `win_splitmove` to relocate only the dev window
under the editor, and `reassert_panel` was deleted — OpenCode's window is never
moved, resized-by-wincmd, or focused by the layout code. Layout is
order-independent and survives dev close→reopen (verified all three orders +
the reopen case).

**Iteration 3 (strip under OpenCode on the dashboard).** `place_horizontal`'s
editor detection required `buftype==""`, so when no file was open it skipped the
alpha dashboard (`buftype "nofile"`, `filetype "alpha"`), found no anchor, and
fell back to `wincmd J` → full-width strip UNDER OpenCode. Caught with temporary
HITL logging of the live window inventory. Fix: target the main content window
by *excluding* terminals + sidebars (`EXCLUDE_FT`) rather than requiring an empty
buftype, so the dashboard counts as a valid anchor. Regression covered by the
`alpha-dashboard` scenario in the spec.

## What would have prevented this
A real-layout test seam. Every existing spec **stubs** toggleterm
(`tests/helpers.lua:15`), so split/grouping behaviour — the exact thing that
broke — was untestable. Added `tests/term_layout_spec.lua`, which loads the real
plugin and asserts the canonical 3-pane layout in both open orders.

## Follow-up
- **Test seam still partial.** `tests/term_layout_spec.lua` **duplicates** the
  dev-terminal re-pin orchestration inline rather than driving the real
  `term_toggle` + `opencode` wiring (those gate on the OpenCode binary and spawn
  real `cmd` jobs). The `term_layout` *primitives* are exercised for real, but a
  drift in the `on_open` orchestration wouldn't be caught. A HITL/`run`-based
  check that opens the real OpenCode TUI and screenshots the panel after
  dev-terminal open/reopen would close the gap.
- **`<C-x>` reaches into the OpenCode TUI.** The terminal-mode bind
  (`mode = { "n", "t" }`) means `<C-x>` is intercepted inside the OpenCode TUI
  too — deliberate, so the dev terminal can be summoned from there. Revisit if
  OpenCode itself ever needs `<C-x>`.
