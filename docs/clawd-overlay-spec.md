# Clawd Overlay Spec for Kodex IDE

> **Revision 2 (2026-07-07).** Adapted to the post-Goal-15 `lua/utils/claude/`
> package, licensing resolved (AGPL fetch-at-setup), rendering path proven in a
> Ghostty spike, `wake` dropped, `thinking` added. Change log at the bottom.

## Purpose

Add a Clawd-style animated pet overlay to the existing Claude Code integration in
Kodex IDE. The overlay renders the original Clawd animation assets (not an ASCII
approximation) and behaves as a first-class companion to the Claude panel:

- sleep when Claude is inactive
- wake (→ idle) when the Claude chat bar appears
- reflect Claude's real work states while Claude is processing
- run a staged idle loop when Claude is done and nobody interacts

This document is implementation-oriented: an implementer should be able to turn it
into code without re-deriving the architecture.

## Non-Goals

- Do not replace the existing Claude panel or chat bar.
- Do not redraw the pet as ASCII art.
- Do not couple the pet to arbitrary editor activity outside the Claude workflow.
- Do not change the Claude state machine except via the narrow, additive event
  hooks named below (the `.wire{}` injection pattern — see Event Sources).
- Do not **vendor** the Clawd assets into the repo (see Licensing).
- Do not tie the pet's "typing" animation to the *user* typing.

## Licensing & Assets (resolved — READ FIRST)

The upstream assets (`rullerzhou-afk/clawd-on-desk`, `assets/gif`) are **AGPL-3.0**.
To keep kodex-ide's own license clean, the assets are **fetched at setup, never
committed**:

- kodex-ide ships **only** `lua/utils/claude_pet.lua` (+ a fetch script). No art in
  the repo.
- `scripts/fetch-clawd-assets.sh` downloads the needed GIFs from the upstream repo
  into `assets/clawd/` on the user's machine.
- `assets/clawd/` is **git-ignored**. The extracted PNG frame cache (below) lives in
  `stdpath("cache")/kodex_clawd/` — also never committed.
- The pet module degrades gracefully (renders nothing, logs once) when assets are
  absent, so a fresh clone without the fetch step still loads.

Asset facts (from the upstream `clawd-*` set): **302×300 px, 45–48 frames each**,
~900 KB for the 13 states used here. There are three skins upstream (`clawd-*`,
`calico-*`, `cloudling-*`); `clawd-*` is the default, the skin is a config option.

**Pixel-art scaling rule (spike finding):** these are pixel sprites. Scale with
**nearest-neighbour** (`convert -filter point …`, or chafa without smoothing) and
feed full-resolution sources. Smooth/bilinear scaling blurs the hard edges (this
caused the only artifact seen in the spike).

## Current Repository Context (updated for the package)

The Claude integration was refactored (Goal 15) from the old monolith
`lua/utils/claude.lua` into a package. **All references below are to the current
tree:**

| Concern | Module |
|---|---|
| Public surface, state, chat bar, panel window, toggle | [`lua/utils/claude/init.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/init.lua) |
| Shared state table (`state.*`) | [`lua/utils/claude/core.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/core.lua) |
| Stream-json renderers + `dispatch(event)` | [`lua/utils/claude/render.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/render.lua) |
| Permission/diff/prewrite cards + accept/reject | [`lua/utils/claude/gate.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/gate.lua) |
| Subagent switcher/drill-in + `state.subagents` | [`lua/utils/claude/widgets.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/widgets.lua) |
| Process spawn / stdin-stdout | [`lua/utils/claude/process.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude/process.lua) |
| Post-write vimdiff review hooks | [`lua/utils/claude_diff.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude_diff.lua) |
| Plugin spec / highlights / startup | [`lua/plugins/claude.lua`](/home/k0d3x/dev/kodex-ide/lua/plugins/claude.lua) |

State the pet reads (all present in `core.lua`): `claude_active`, `panel_win`,
`job_id`, `working`, `diff_pending`, `system_ready`, `session_cost`,
`model_display`, `subagents`, `activity_t0`, `stored_root`, `permission_mode`.

## Rendering (spike-proven — decided)

**Terminal:** Ghostty 1.2.3, which implements the **Kitty graphics protocol**.

**Mechanism (locked by the L1–L3 spikes, 2026-07-07):**

- **Placement layer = `image.nvim`** (kitty backend, `magick_cli` processor → uses
  the `convert` CLI; the `magick` luarock is optional). It renders a **static** PNG
  in a Neovim floating window and coordinates with nvim's redraw. **Proven:** the pet
  renders in a bottom-right float over the transcript, and repositions cleanly on
  move/resize with no ghosting (spike Q1, Q3).
- **Animation = timer frame-swap of pre-extracted PNGs.** `image.nvim` does **not**
  animate GIFs (its processor takes frame `[0]` only), and its `clear()` wipes the
  transmit cache — so animation is driven by us: at fetch time expand each GIF to a
  numbered PNG sequence (`convert -coalesce -filter point` — **nearest-neighbour**,
  the pixel-art rule) into the cache dir; a `vim.loop` timer swaps frames.
- **Anti-flicker rule (load-bearing):** on each tick **render the next frame first,
  then clear the previous** — a frame is always on screen, so there is no blank gap.
  This made steady-state animation smooth in the spike. ~10 fps and ~16 frames/state
  is ample for an idle desk-pet and halves retransmit cost.
- **Known residual:** a brief **startup flicker** while the first loop cold-processes
  each PNG through `convert`. Fixes (in priority): warm all of the active state's
  frames off-screen before showing the pet; or hold a static first frame ~1 s; or
  (endgame) drop to **raw kitty protocol** — transmit each frame once with a
  persistent id and swap *placements* (zero retransmit, zero startup cost). Not a
  blocker; polish.

**Z-ORDER — critical constraint (spike Q2):** kitty-graphics images composite
**ABOVE** nvim text floats regardless of `zindex`. The pet **bled through on top of a
mock permission card**. Therefore the pet **must explicitly hide** (clear its image)
whenever a decision surface is up — drive this off the existing `gated()` predicate
(`state.perm | prewrite | qask | diff_card | diff_pending`, `init.lua`): `gated()`
true → `pet:hide()`, false → restore. Do **not** rely on window stacking.

Frame cache cost (measured): ~16 PNGs/state (downsampled from 45–48) at ~120 px,
~1.3 KB/frame → well under 1 MB total for all 13 states.

**The renderer must:** place at a float's screen cell, animate via the render-before-
clear frame swap, hide on `gated()`, reposition on resize, and tear down without
leaving artifacts (kitty delete). It must **never** degrade to ASCII.

**Runtime deps:** ImageMagick (`convert`) + `image.nvim`. `chafa` proved the protocol
in the L1/L2 spike but is **not** used at runtime. **Zero token cost** — all
client-side.

## State Model

`wake` is **removed** — it was mapped to the idle GIF, so it is just `idle` with a
freshly-reset idle timer. `thinking` is **added** (the panel already tracks a
distinct thinking phase via `--include-partial-messages`).

### States → assets (`clawd-*` skin)

| State | Asset (`clawd-…gif`) | Meaning |
|---|---|---|
| `sleep` | `sleeping` | no active work or recent interaction |
| `idle` | `idle` | at rest / just woke (chat bar opened) |
| `thinking` | `thinking` | Claude reasoning (thinking block active) |
| `typing` | `typing` | Claude generating output text |
| `reading` | `idle-reading` | Read / NotebookRead tool |
| `debugging` | `debugger` | tests / logs / traces / failure analysis |
| `cleaning` | `sweeping` | delete / rename / move / prune |
| `error` | `error` | assistant reports failure, or turn ended failed |
| `subagent` | `juggling` | a subagent task is running |
| `diff_wait` | `notification` | a diff/prewrite review is pending |
| `diff_approved` | `happy` | diff accepted |
| `happy` | `happy` | turn completed successfully |
| `diff_rejected` | `react-annoyed` | diff rejected |
| `headphones_groove` | `headphones-groove` | idle-progression 60–120 s |

The machine keeps three conceptual lifecycles (collapsible into one enum):
**UI** (sleep / chat-open / chat-closed), **Claude work** (idle / thinking / typing
/ reading / debugging / cleaning / subagent / error / diff_* / happy), and **idle
progression** (idle → groove → idle → sleep).

## Priority Model

Multiple conditions can be true at once; a resolver picks the highest-priority
active state:

1. `error`
2. `diff_wait`
3. `diff_rejected`
4. `diff_approved`
5. `debugging`
6. `cleaning`
7. `reading`
8. `subagent`  *(consider promoting above reading/cleaning when a subagent is the dominant activity — the Goal-17 drill-in makes subagents prominent)*
9. `thinking`
10. `typing`
11. `happy`
12. `headphones_groove`
13. `idle`
14. `sleep`

Rationale unchanged from rev 1: errors and diff-review states must never be hidden;
specific tool activity beats generic generation; groove only appears via the idle
progression; sleep is the floor.

## Idle Progression

Begins **only after Claude finishes answering** and the UI returns to idle:

- `t = 0s` → `idle`
- `t = 60s` → `headphones_groove`
- `t = 120s` → `idle`
- `t = 180s` → `sleep`

Implemented with `vim.loop` timers, **cancelled and restarted on any user
interaction** (see Definition of User Action). Sleep persists until the next user
action.

### Definition of User Action (resets the progression)

- opening the Claude chat bar
- focusing the Claude panel
- starting / sending a Claude prompt
- a Claude-specific keymap
- interacting with a diff-review flow

## Critical Timing Semantics (unchanged — the key correction)

1. user presses Enter → chat bar closes
2. Claude keeps responding
3. pet **stays in Claude work states** until Claude is actually done
4. only after Claude produces its answer → `idle`
5. only then does the 60/120/180 progression start

The pet must **not** sleep the moment the user sends a prompt. `typing` represents
**Claude** generating, never the user typing in the chat bar.

## Event Sources (mapped to the current modules)

The pet is driven by a single injected callback, `pet.on(...)`, wired into existing
seams via the codebase's `.wire{}` dependency-injection pattern (the same way
`render.wire{}`, `gate.wire{}`, `question.wire{}`, `process.wire{}` already work).
No module hard-couples to the pet; a nil `pet` is a no-op.

### 1. Chat-bar lifecycle — `init.lua`

`open_chat_float()` and its submit callback:
- bar opens → `pet.on("chat_open")` → wake to `idle`, reset idle progression, keep
  awake while the bar is visible
- submit → `pet.on("chat_submit")` → hand off to the Claude-work lifecycle (do
  **not** sleep)

### 2. Claude turn lifecycle — `render.lua` `dispatch(event)`

The dispatcher already parses stream-json (`system.init`, partial `thinking`
deltas, `assistant`, tool_use, `result`). Emit:
- thinking block active → `thinking`
- assistant generating text → `typing`
- `tool_use` → classify (below) → `reading` / `cleaning` / `debugging` / `subagent`
- `result` success → `happy` (then idle progression)
- `result` failure / error → `error`

**Tool classification is partly free:** `render.lua` already maps tool verbs
(`Read`→Reading, `Bash`→Running, `Grep`/`WebSearch`→Searching) with highlight
groups. Reuse that. `cleaning` and `debugging` are **not** distinguished today and
need content heuristics on the command/tool input (see Heuristics).

### 3. Diff lifecycle — `gate.lua` + `claude_diff.lua`

**Accept/reject signals already exist** (this was open question Q4 in rev 1 — now
resolved, no new plumbing):
- `on_diff_open()` / `state.diff_pending` → `diff_wait`
- `gate.resolve_diff_card("accept")` and `gate.on_prewrite_resolve(true)` → `diff_approved`
- `gate.resolve_diff_card("reject")` and `gate.on_prewrite_resolve(false)` → `diff_rejected`

### 4. Subagents — `widgets.lua` + `state.subagents`

Subagent lifecycle is already tracked (Goal 17). Emit `subagent` while
`state.subagents` has active entries.

### 5. Idle timers — `claude_pet.lua`

Owned by the pet module; started on the transition into idle, reset on user action.

## Heuristics for State Classification

Reuse `render.lua`'s existing verb map for `reading`/generic; add content checks for
the two states the stream doesn't label:

- **cleaning** — tool input matches remove/rename/move/prune/`rm`/`rmdir`/`mv`, or a
  Bash command whose head is a destructive filesystem op.
- **debugging** — tool activity around tests/logs/traces (test runners, `grep` of
  logs, stack-trace inspection, repeated edits to the same file after a failure).
- **error** — assistant explicitly reports failure, tool output is a hard failure, a
  tool crashes, or the turn ends failed.
- **subagent** — `state.subagents` active / explicit subagent events.
- **typing** — Claude's own generation only. Never user chat-bar typing.

Heuristics are best-effort; when ambiguous, fall to the generic tool state
(`reading`) rather than guessing `cleaning`/`debugging`.

## Placement & Z-Order (resolved by the L3 spike)

Two anchor positions:
- **Claude idle / working, no chat bar:** bottom-right of the Claude column
  (`state.panel_win`).
- **Chat bar open:** top-right of the chat bar float; track its position/width/resize.

**Reposition is clean** — moving the pet float and resizing the terminal leave no
ghost (spike Q3). Repaint the current frame after a `nvim_win_set_config`.

**Cards: hide, don't stack.** `zindex` does **not** help — kitty graphics draw ABOVE
text floats, so a lower `zindex` still bleeds the pet on top of a card (spike Q2). The
rule is therefore behavioural, not geometric: **hide the pet while any decision
surface is up.** Drive it off `gated()` (`init.lua`): on every relevant event and on
card open/close, if `gated()` → `pet:hide()`, else restore to the correct anchor.
This also covers the chat bar overlap for free (a card dismisses the bar anyway).

## Module API

```lua
pet.setup(opts)              -- assets dir, skin, size, fps, enable flag
pet.show() / pet.hide()
pet.attach_to_panel(win_id)  -- bottom-right idle anchor
pet.attach_to_chat(win_id)   -- top-right of the chat bar
pet.set_state(name)          -- direct (mostly for tests)
pet.on(event, data)          -- the wired entry point (classifies + resolves)
pet.begin_idle_progression()
pet.cancel_idle_progression()
pet.reset_idle_progression()
pet.teardown()               -- kitty delete + timers + windows
```

## Testability (new — separate the pure core from the renderer)

Split the module so the logic is headless-testable (this repo has strong
`tests/*_spec.lua` coverage; the pet must fit it):

- **Pure state machine** — priority resolver + idle-progression timers + event
  classification. No windows, no images. Unit-tested headless: feed events, assert
  the resolved state and timer transitions. Fake the clock (inject `now()`).
- **Renderer** — the only image/window code, hidden behind a small interface
  (`render_state(name, geom)` / `clear()`), stubbed in tests. The spec's rendering
  risk lives entirely here and is validated by the L3 spike, not unit tests.

## Recommended Implementation Order

1. ~~L3 spike~~ **DONE** (2026-07-07): renders + animates + repositions in a float;
   z-order needs hide-on-`gated()` (see Rendering/Placement).
2. `scripts/fetch-clawd-assets.sh` + git-ignore `assets/clawd/`; frame pre-extraction
   into the cache dir (`convert -coalesce -filter point`, ~16 frames/state).
3. `claude_pet.lua`: **pure state machine** (priority resolver + idle progression +
   classification) behind a **stub renderer** + `pet.on`. Headless spec. ← next
4. Wire chat open/close (`init.lua`) → idle/hide.
5. Wire turn lifecycle (`render.lua dispatch`) → thinking/typing/reading/cleaning/
   debugging/subagent/happy/error.
6. Wire diff accept/reject (`gate.lua`) → diff_* states; hide on `gated()`.
7. Real `image.nvim` renderer behind the interface: render-before-clear frame swap,
   placement + resize repaint, hide-on-gated.
8. Idle progression timers (60/120/180) + teardown (kitty delete, timers, windows).

## Open Questions (updated)

Resolved: **Q4** (accept/reject signals exist), **rendering feasibility** (L1–L3
spikes), **z-order** (hide-on-`gated()`), **animation driver** (image.nvim + timer
frame-swap, render-before-clear), **licensing** (fetch-at-setup).

Still open:
1. **Startup flicker** polish: off-screen warm-up vs static-first-frame vs raw-kitty
   persistent-transmit. (Bounded; not a blocker.)
2. Should panel *focus* reset the idle progression, or only explicit Claude actions?
3. Exact idle-anchor when the panel is narrow (pet size vs column width).

## Final Design Summary

- Kitty-graphics rendering in Ghostty (**spike-proven**), pixel-art nearest-neighbour
  scaling.
- Assets **fetched at setup** from the AGPL upstream, never vendored; repo stays
  license-clean.
- Separate `claude_pet` module: **pure state machine + stubbed renderer**, wired into
  existing seams via `.wire{}`.
- Claude state machine (`core.lua` state + `render.lua` dispatch) is the source of
  truth; `typing` = Claude output, never user input.
- `wake` dropped (== idle); `thinking` added.
- Diff accept/reject use the **already-existing** `gate.lua` signals.
- Pet **hides on `gated()`** (kitty images draw above text floats — can't stack under
  cards); reposition is clean.
- Renderer: `image.nvim` static placement + **render-before-clear** timer frame-swap.
- Staged idle: idle → groove (60 s) → idle (120 s) → sleep (180 s), reset on user
  action.

## Change Log

- **Rev 3 (2026-07-08):** L3 spike complete — locked renderer to `image.nvim` +
  timer frame-swap (image.nvim doesn't animate GIFs; its `clear()` wipes the transmit
  cache); **render-before-clear** anti-flicker rule (steady-state smooth; startup
  cold-processing flicker is bounded polish); **z-order resolved** — kitty graphics
  composite above text floats, so the pet must **hide on `gated()`** rather than stack
  (spike Q2); reposition clean (Q3). Runtime dep = `image.nvim` + ImageMagick; `chafa`
  used only to prove the protocol.

- **Rev 2 (2026-07-07):** adapted every file reference to the `lua/utils/claude/`
  package; resolved licensing (AGPL → fetch-at-setup, no vendoring); recorded the
  Ghostty render spike (L1/L2 pass) + pixel-art scaling rule; dropped `wake`; added
  `thinking`; noted accept/reject signals already exist; added the state-machine ↔
  renderer split for testability; expanded placement into explicit card z-order
  coexistence; reordered implementation to spike L3 (card coexistence) first.
- **Rev 1:** original concept (pre-refactor, monolithic `claude.lua` references).
