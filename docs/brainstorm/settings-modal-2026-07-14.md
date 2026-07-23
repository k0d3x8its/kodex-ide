# Design: Rich tabbed settings modal for the Claude Code panel

> Brainstorm output, 2026-07-14. Pipeline: /brainstorm → /grill-me → /write-plan.
> Status: Gate-3 attacked (inline + cold-context subagent, ce-adversarial-document-reviewer)
> — 6 hardenings folded in as constraints; design survives, no premise reversed. Remaining
> open questions below are for /grill-me before /write-plan.

## Problem

The Claude Code TUI has a `/status` view: a multi-tab dashboard (Settings · Status ·
Config · Usage · Stats) showing session info, token/cost usage, rate-limit gauges, and
historical stats (tokens-per-day chart, activity heatmap, streaks). The kodex-ide panel
has none of this. We want a **rich, read-only** tabbed modal in the panel that replicates
that view, using data the plugin can actually source.

The panel drives `claude --print --output-format stream-json`, in which `/status`,
`/usage`, `/cost`, `/config`, `/stats` are **interactive-only** — they cannot be
forwarded. So the modal renders from disk + the existing stream (see data investigation
in `.work/FINDINGS.md § Settings-modal`).

**v1 scope (decided):** read-only dashboard; tabs **Status + Usage + Stats** (the three
fully-sourceable ones). Config and the weekly-usage gauges are a follow-up; the shell is
designed to accept them without a rewrite. Changing a setting still routes through the
existing controls (`/effort`, `/model`, …) — the modal does not mutate settings in v1.

## Context & constraints

- **Focus-trap already shipped** (commits f8b4757..6062107): `active_modal_win()` +
  a `WinEnter` bounce keep a modal focused when the panel is clicked; Alt+w still reaches
  the editor. The settings modal registers its window there and inherits this for free.
- **Existing modal pattern** (`effort.lua`, `advisor.lua`, `gate.lua`): a focusable float
  built with `nvim_open_win`, anchored to the panel column via `panel_float_geom()`
  (returns the panel's screen `col` + `width`), own buffer + namespace, own keymaps,
  `close()` restores `prev_win`. The settings modal follows this shape but is **full-panel
  height** and **multi-tab**.
- **Geometry:** `panel_float_geom()` → `(panel_col, panel_w-2)`. A full-panel float is
  `relative=editor, col=panel_col, row=0, width=panel_w, height=vim.o.lines-2`, zindex
  above the other floats (they're 60–75; use 80).
- **Data sources (confirmed, FINDINGS.md):**
  - Status: plugin `system/init` (version, model, cwd, session_id, mcp) + `settings.json`
    + `~/.claude.json` `oauthAccount` (login/email/org).
  - Usage: plugin `session_cost` (`total_cost_usd`) + per-turn usage tokens +
    `stats-cache.json` `modelUsage{model→{inputTokens,outputTokens,cacheRead,…}}`.
  - Stats: `~/.claude/stats-cache.json` v4 — `dailyModelTokens[]` (tokens/day chart),
    `dailyActivity[]` (heatmap + active days), `modelUsage` (per-model %), `totalSessions`,
    `longestSession`, `hourCounts`, `firstSessionDate` (streaks/overview).
- **Charts:** tokens-per-day line chart + an activity heatmap, rendered as braille/ASCII
  into buffer lines with highlights. The panel already has chart-ish renderers to mirror
  (`claude_bar_meters`, the burn bars) for style consistency.
- **Trigger:** typing `/status` should open OUR modal, not forward to the CLI — intercept
  it client-side exactly as `/effort` is intercepted (client-side slash command). A direct
  keymap is a secondary entry point (exact key → /grill-me).
- **Standing rules:** Lua code follows `~/.claude/references/code/LUA`; comments explain
  the *why*; no single-letter identifiers; new logic gets headless spec coverage
  (`tests/*_spec.lua`, `make test`).
## Hard constraints (from Gate-3 — inline pre-attack + cold-context subagent review)

These are requirements, not open questions. The subagent verified each against shipped code
(file:line cited); the design **survives Gate 3 with these folded in** — no premise reversed.

1. **Block open while `gated()` (CRITICAL).** Opening the settings float (zindex 80) over a
   live permission/diff/question card (zindex 60, `gate.lua:482`) covers it opaquely, and
   `active_modal_win()` (`init.lua:633`) would bounce focus to the *hidden* `state.perm.win`
   → the turn deadlocks on a decision the user can't see or reach. The focus-trap's comment
   (`init.lua:631`) explicitly assumes one modal at a time. So: settings `open()` must
   **refuse while `gated()` is true** (`init.lua:621`), and while settings is open, an
   arriving gate must take precedence (settings closes or the gate wins). Not cosmetic.
2. **Re-home the Clawd pet on open/close (HIGH).** The image.nvim pet draws on a separate
   graphics layer NOT governed by float zindex — this is why `effort.lua` calls
   `pet_attach_surface(modal.win)` on open (`effort.lua:188`) and `pet_attach_panel()` on
   close (`effort.lua:149`). Without the same wiring the pet renders over the charts,
   bottom-right. Settings `open()`/`close()` must do the identical re-home (or suspend the
   pet while open).
3. **Intercept the full modal-backed command set (HIGH).** `submit()` (`init.lua:1394`)
   currently intercepts only `/effort` and `/advisor`; everything else forwards to the CLI.
   `/usage` and `/stats` are advertised commands (`slash.lua:96`) but are NOT real
   interactive commands in `--print` mode — forwarding them sends the literal string to
   Claude, burning tokens and answering conversationally with no modal. Intercept
   `/status`, `/usage`, `/stats` (and `/config` when it lands) → open the modal on the
   matching tab.
4. **`stats-cache.json` defensive read (MEDIUM).** Undocumented, version-pinned (`version:
   4`), may be absent (fresh install), up-to-a-day stale, or partially/concurrently written.
   The `version==4` gate checks the *envelope shape only* — a v4 cache from an older build
   can pass the gate then nil-index (`longestSession.duration`, `dailyActivity[i].*`). So:
   `pcall` the **entire** parse→render, treat **every field as optional** (per-field
   nil-guards + defaults), degrade to a clean empty-state, surface `lastComputedDate` so
   staleness is visible. Watch timezone: `dailyActivity` date strings vs `os.date()` local
   time can shift the "today" heatmap cell / streak by one across a tz boundary. Same
   defensive posture for `~/.claude.json` (mode 600, may be unreadable).
5. **Own full-height resize path (MEDIUM).** A's tradeoff line over-claims "reuses the
   resize handler" — `attach_panel_float_resize` (`gate.lua:382`) hardcodes
   `c.row = float_bottom_row()` (SW/bottom-pinned) and would snap a full-panel float to the
   bottom on the first `VimResized`. Need a full-height resize path that recomputes
   `col`/`width` only, keeping `row=0`. Also reconcile width: `panel_float_geom()` returns
   `panel_w-2` (`gate.lua:361`, the SW rounded-border interior); a full-panel float needs
   its own explicit width contract.
6. **Snapshot-on-open, not live-update (MEDIUM — locked, was an open question).** A's
   headline safety property (no stream coupling) holds ONLY under snapshot-on-open.
   Live-update would read `session_cost`/tokens *while a turn streams* and could trigger
   disk reads from a stream callback — a fast-event context where `vim.fn.json_decode`/
   `readfile` are unsafe (render.lua wraps file work in `vim.schedule`, `init.lua:1838`, for
   exactly this reason). Lock snapshot-on-open + a manual refresh key. Parse the cache
   **once per open** and cache it in the modal — do not re-decode on every `switch_tab`.

## Approaches

### A — Full-panel float + pure data providers + line-based tab renderers

A new `lua/utils/claude/settings.lua` owns the modal, mirroring `effort.lua`/`advisor.lua`:
`open()`, `close()`, `active()`, `win()`, `switch_tab(delta)`, `render()`. It opens one
full-panel-height scratch float over the panel column, registers its window in
`active_modal_win()` (one-line add), and owns its keymaps (`←/→`/`<Tab>` switch tabs,
`Esc`/`q` close, `j/k` scroll). Tab content is produced by a separate
`lua/utils/claude/settings_data.lua` of **pure functions** — `read_stats()` (parse
`stats-cache.json`), `status_fields()` (from `state` + settings.json + ~/.claude.json),
`usage_summary()` — each returning a plain Lua table. The renderer turns a data table into
`{lines, highlights}` per tab and stamps them into the buffer on open + on every tab
switch. Charts are helper functions (data → braille/ASCII rows).

**Tradeoffs:** Reuses existing patterns (float, focus-trap, geometry helpers, pet re-home)
so blast radius is contained to two new files + a slash-intercept + one line in
`active_modal_win()` — but NOT the bottom-anchored resize handler (needs its own
full-height path, see constraint 5) and it must gate against concurrent modals (constraint
1) and re-home the pet (constraint 2). Pure data providers are **unit-testable headlessly** (feed a fixture
JSON, assert the rendered lines) — matches the repo's spec-first norm. Doesn't touch the
transcript buffer, chat bar, pad, streaming, or pet, so no risk of a mid-turn stream
corrupting the view. Cost: a full-panel float over the panel isn't *literally* the panel
buffer, so the transcript is hidden (not scrolled) beneath it — fine for a modal, and it's
how the TUI behaves too. Chart rendering is net-new code.

### B — Panel-buffer takeover

No float: on open, swap `state.panel_win`'s buffer to a dedicated settings scratch buffer
(saving the transcript buffer handle + view), render tabs into it, and restore on close.

**Tradeoffs:** Uses the full panel naturally with no float geometry, and visually *is* the
panel. But it fights the whole panel machinery: the streaming renderer appends to the
transcript buffer by handle (a mid-turn event would write into a detached buffer or the
wrong one), the chat bar / bottom pad / pet / bottom widgets all anchor to `panel_win` and
would need suspending + restoring, and view state (scroll, folds) must be saved/restored
exactly or the transcript jumps on close. Many more coupling points and failure modes for
the same visual result. The focus-trap also assumes a *modal window* to bounce to; a
buffer swap has no separate window, so that integration would need rework. Reject as
primary — higher risk, no offsetting benefit for a read-only view.

## Recommendation

**A — Full-panel float + pure data providers.** It reuses the shipped focus-trap and every
existing modal/geometry pattern, isolates all new logic in two testable files, and never
risks the live transcript/stream — the exact properties fable-mode's thin-slice + verify
discipline wants. B's only advantage (it *is* the panel) is cosmetic for a read-only view
and costs a large coupling surface. Build the shell + Stats tab first (thinnest end-to-end
slice: proves float + focus-trap + tab-switch + chart rendering against real
`stats-cache.json`), then add Status and Usage tabs as pure-provider additions.

## Open questions → for /grill-me

Resolved by Gate 3 (now hard constraints above, not open): gate interaction (→ block while
`gated()`), intercept set (→ `/status` `/usage` `/stats`), refresh model (→ snapshot-on-open
+ manual refresh), pet bleed (→ re-home). Still genuinely open:

- **Direct keymap entry point:** the slash commands are decided, but is there also a direct
  keymap to open the modal, and to which tab? No obvious free key — candidates `<leader>cs`,
  a chat-bar command. Decide whether a keymap is even wanted for v1.
- **Empty/stale-state wording:** when `stats-cache.json` is absent (fresh install) or stale,
  what exactly does the Stats tab render — a one-line "no stats yet / last computed
  <date>" empty state, a partial view of whatever fields ARE present, or a hint to open the
  TUI once to populate it? Define the copy + threshold for "stale."
- **Chart fidelity vs panel width:** the tokens/day line chart + heatmap must fit a narrow
  panel column (~40–80 cols) in both light/dark themes. How faithful to the TUI — braille
  pixel-ish, or a simpler always-fits sparkline/bar? Define the degrade-on-narrow rule and
  the min width below which charts collapse to numbers.
- **Tab-provider contract:** lock the interface now so the deferred Config tab (settings.json,
  reduced scope) and weekly-usage gauges drop in later without reworking the shell. What
  does a provider return — `{lines, highlights}`, or a richer structured model the renderer
  formats? This decides testability shape.
- **Vertical scroll within a tab:** Stats/Usage can exceed the panel height (the screenshots
  scroll). Is it plain `j/k` buffer scroll within the one full-panel buffer, or per-tab
  scroll state preserved across tab switches?
