# Manual check: OpenCode / dev-terminal layout (HITL)

**Type:** human-in-the-loop. Not part of `make test`.
**Why this exists:** `tests/term_layout_spec.lua` is headless. It tests the
`utils.term_layout` *primitives* for real and asserts window geometry, but it
**cannot** catch two things:

1. **Orchestration drift.** The spec copies the `on_open` wiring inline and uses
   a `sleep` job — it does not call the real `term_toggle.toggle_dev` /
   `opencode.toggle`. If someone edits the real `on_open` in
   `lua/utils/term_toggle.lua` or `lua/utils/opencode.lua`, the spec still
   passes. This checklist drives the **real keybindings**, so drift shows up.
2. **Blank/black OpenCode (TUI redraw).** A `sleep` job is not a TUI. The
   blank-OpenCode regression (POST-MORTEM iteration 2, 2026-06-15) was a redraw
   bug — moving a live full-screen TUI's window stranded it on a stale screen.
   Only a **real OpenCode TUI, looked at by a human**, catches this.

Run this when you touch any of: `lua/utils/term_layout.lua`,
`lua/utils/term_toggle.lua`, `lua/utils/opencode.lua`,
`lua/plugins/toggleterm.lua`, or `lua/plugins/opencode.lua`.

## Prerequisites

- OpenCode installed at `~/.opencode/bin/opencode` (`opencode.is_available()`).
- A real terminal (NOT `nvim --headless`). Use your normal terminal emulator.
- toggleterm + plugins synced (`:Lazy sync` if unsure).

Keybindings under test:
- `<C-x>` → dev terminal (`term_toggle.toggle_dev`), `mode = { "n", "t" }`.
- `<leader>oc` → OpenCode panel (`opencode.toggle`).

## Canonical layout (the target)

```
┌───────────────────────┬──────────────┐
│                       │              │
│  editor / dashboard   │  OpenCode    │
│                       │  (vertical,  │
├───────────────────────┤   ~40%,      │
│  dev terminal strip   │  full-height)│
│  (~10 rows, editor    │              │
│   width only)         │              │
└───────────────────────┴──────────────┘
```

OpenCode = full-height right panel. Dev strip = short, **under the editor
only** — never spanning the full width under OpenCode.

## Steps + success criteria

Open `nvim` on a real file inside a project (e.g. `nvim lua/utils/opencode.lua`)
unless a step says otherwise.

### S1 — dev first, then OpenCode
1. Press `<C-x>`. → dev strip appears at the bottom, editor width only.
2. Press `<leader>oc`. → OpenCode opens as the right vertical panel.
- [ ] Layout matches canonical (strip beside OpenCode, not under it).
- [ ] **OpenCode TUI is rendered** — prompt/UI visible, not blank/black.

### S2 — OpenCode first, then dev (the order that regressed)
1. Fresh nvim. Press `<leader>oc`. → right panel, TUI rendered.
2. Press `<C-x>`. → dev strip homes under the editor.
- [ ] Strip sits under the editor only (NOT full-width under OpenCode).
- [ ] **OpenCode TUI still rendered** after the strip appears — not blanked.

### S3 — reopen while OpenCode is up (the blank-TUI case)
1. With OpenCode open (from S2), press `<C-x>` to close the dev strip.
2. Press `<C-x>` again to reopen it.
- [ ] OpenCode stays open and **stays rendered** across close→reopen.
- [ ] OpenCode is NOT blank/black/stranded — its own content still shows.
- [ ] Layout still canonical.

### S4 — no file open (alpha dashboard anchor)
1. Launch bare `nvim` (no file) → alpha dashboard.
2. Press `<leader>oc`, then `<C-x>`.
- [ ] Dev strip homes under the dashboard, **beside** OpenCode (not full-width
      under it).
- [ ] **OpenCode TUI rendered**, not blank.

### S5 — `<C-x>` from inside the OpenCode TUI (terminal-mode bind)
1. With OpenCode focused (you're in terminal mode inside the TUI), press `<C-x>`.
- [ ] Dev terminal toggles — the bind reaches `toggle_dev` from terminal mode.

## On failure

- Blank/black OpenCode → suspect a redraw/window-move regression in
  `term_layout.place_horizontal` or `place_vertical` (don't move/focus/resize
  OpenCode's window; see POST-MORTEM iteration 2).
- Strip full-width under OpenCode → editor-anchor detection regressed
  (`EXCLUDE_FT`; see POST-MORTEM iteration 3).
- `<C-x>` does nothing from the TUI → the `mode = { "n", "t" }` bind regressed
  (POST-MORTEM root cause #2).

File any failure as a `[BUG]` TODO and route through `/diagnose`.
