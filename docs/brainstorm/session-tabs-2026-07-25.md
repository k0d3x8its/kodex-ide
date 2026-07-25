# Design: Multiple Claude Code sessions as tabs in the panel

> Brainstorm output, 2026-07-25. Pipeline: /brainstorm → /grill-me → /write-plan.
> Status: draft — not yet grilled.

## Problem

The Claude panel runs exactly one CLI session. Running a second conversation means
losing the first. The user wants N concurrent sessions living in the panel column,
switchable by a keymap, each showing title, status, token count and cost.

The panel is single-slot by construction, so this is a state-multiplexing refactor
of `Core.state` plus a switcher UI — not a feature bolted onto existing plumbing.

Background, prior art and the full architecture audit live in
`.work/todos/session-tabs.md`. This doc assumes it and does not repeat it.

## Context & constraints

### Feasibility is proven, not assumed

Two spike rounds (2026-07-25, scripts in scratchpad, results recorded in the TODO
detail file):

1. **Transport** — 3 concurrent `claude` processes in one cwd, turn 1 sent to all
   before reading any. No hang, no serialization, no context bleed, distinct
   `session_id`s.
2. **Real workload** — full panel flag set including `--permission-prompt-tool
stdio`, each session forced into a real `Write` tool call. 3/3 `can_use_tool`
   round-trips answered, each bound to its own stdio pipes. No hang, no misrouted
   permission.

The blocking concern (`core.lua:41–47`, "`--continue` collides in the same root")
turned out to describe a **replaced architecture**. `build_args()` passes neither
`--session-id` nor `--resume`; the panel holds context in-memory over open stdin.
`state.session_id` is dead code (refs: `init.lua:3033/3036`,
`tests/claude_spec.lua:213`) and should be dropped with spec T2 in the same commit.

### Hard blocker in existing code

`Process.stdout_buf` (`process.lua:86`) is a **module-level** string holding the
partial-line tail between `on_stdout` callbacks, and `on_stdout(_, data, _)`
discards its job-id argument. With N jobs sharing the module, all N callbacks
splice fragments into one buffer and every JSON decode yields garbage. This is a
guaranteed corruption bug, not a tradeoff. Nothing works until it is keyed by job.

### The upvalue-capture constraint

All eight panel modules bind the state table once at load (`core.lua:255`,
`process.lua:46`, `render.lua:41`, `widgets.lua:19`, `gate.lua:35`,
`question.lua:22`, `effort.lua:22`, `init.lua:84` — the last is
`mod.state = core.state`, same identity). **Rebinding `Core.state` on tab switch
cannot propagate.** Any "swap the state pointer" design is broken at the outset.

### No transcript model

`render.lua` has no `state.transcript`/`state.lines`; every render path writes
straight into the panel buffer via `nvim_buf_set_lines`. The buffer _is_ the
history. So `panel_buf` is inherently per-session and cannot be swapped by copying
scalar fields. Corollary, and it is good news: give each session its own scratch
buffer, keep one `panel_win`, switch with `nvim_win_set_buf`. Extmarks ride along
on the buffer for free — no replay, no serialization.

### Per-session buffers need unique scheme-based names (KNOWLEDGE.md:18)

Naming the panel's scratch buffer with a bare relative name is a known trap: a
repo containing a real directory of that name makes netrw hijack the buffer into a
directory listing, wiping `filetype=claude` — which kills both the banner render
and the modal statusline (`in_claude()` keys off that filetype). The fix already
shipped is a `scheme://` name, `neoclaude://neoclaude` (`init.lua:1162`).

Multi-session makes this sharper: **N buffers each need a unique name or
`nvim_buf_set_name` throws E95 (duplicate name)** on the second session. The
existing `pcall` around `set_name` guards E95 but silently leaves the buffer
unnamed, which would break the statusline for that tab. Name them
`neoclaude://session-<n>` (or by session record id) and treat naming as part of
session creation, not an afterthought.

### `system/init` is per-turn, not per-session (KNOWLEDGE.md:31)

The stream-json `system/init` event fires **once per turn**, not once per session,
and only after the first user message — never on spawn. Session-scoped
initialisation must therefore hang on the process **spawn** (`ensure_process` /
jobstart), not on `system/init`, or it re-runs and wipes state every turn. This is
already true single-slot; with N sessions each spawning independently it becomes
the rule for per-session record setup too. Related: `model`, `slash_commands` and
`claude_code_version` are unavailable until a session's first turn, so a freshly
created tab has no model label until the user sends something — the switcher row
and winbar need a defined empty-state rather than blank.

### Layout facts

The panel is a **real window**, not a float: `vsplit` then `wincmd L` to the
far-right column (`init.lua:2682–2693`). nvim-tree is `side = "left", width = 35`.
All panel floats are bottom-anchored, full-panel-width, and stack through
`reflow_bottom_floats`. The panel window's `winbar` is **unused and free** — the
"panel winbar" comments in `claude_burn.lua:4` and `plugins/claude.lua:237` are
stale; the burn meters actually render inside the chat-bar box
(`init.lua:1868, 1979`).

### Keymap space

Taken in the panel: `<C-b>` (subagent switcher), `<C-o>`, `<C-i>` (steer), `<CR>`,
`<Up>/<Down>`, `<Esc>` (interrupt), `q`, `za`, `<Tab>`. Leader-c family fully
taken except `n`: `ca cb cc cm cp cq cr cx`. Reserved by the user: `<C-w>`,
`Alt+w`. Global: `<C-s>`, `<C-x>`. No tmux config present, so `<C-a>` carries no
prefix conflict.

### Glyph vocabulary

In use: `⣾` (spinner), `▌` `▎` (bars), `✔`/`✓`, `◦`, `●`/`○` (subagent selection,
`widgets.lua:755`), `▦`/`□` (todo widget, `widgets.lua:302`), `◇` (subagent bar
title, `widgets.lua:870`). A session glyph must avoid the square, diamond and
circle families entirely — `▣` was considered and **rejected** for sitting between
`▦` and `□`.

### Rejected outright (decided with the user, 2026-07-25)

- **Per-tab git worktrees.** The diff gate (`claude_diff.lua`, keyed on abs paths,
  `bufadd`s the real file) and host-context (`host_file_of`,
  `init.lua:1620–1703`) are both bound to buffers open in _this_ nvim. A worktree
  makes the panel diff files the user does not have open and send `@file` context
  from the wrong tree. Worktrees parallelise branches; tabs parallelise
  conversations. Wrong axis. Keep as a later, decoupled, opt-in per-tab mode.
- **OS sandboxing (bwrap/container).** The panel already gates at the right layer
  via `--permission-prompt-tool stdio`, per-session already. Process isolation
  would cut the agent off from the user's real files, removing the feature.
- **Vertical rail between panel and editor.** Real window, so native layout — but
  at 120 cols (tree 35 + rail 18 + panel 48) the editor is left 19 columns. Also
  gains its own per-window statusline (`init.lua:1861–1866`), inserts a third stop
  in `<C-w>` cycling, and compounds the stray-blank-pane bugs already documented at
  `init.lua:3021–3024`.
- **Left sidebar like nvim-tree.** Puts the switcher on the far left while the
  sessions it switches render on the far right — a cross-screen round trip paid on
  every switch — and competes with nvim-tree for the left slot.

## Approaches

Approach (A), "in-place field swap on one `Core.state` identity", was considered
and is **dead on arrival**: the no-transcript-model finding means tab switching
requires swapping buffer _contents_, which is not a field copy. It is recorded here
only so it is not re-proposed. The live choice is B vs C.

Lettering matches `.work/todos/session-tabs.md` so the two documents cross-reference
cleanly.

### B — Accessor refactor

Replace the module-local upvalue in all eight modules with a `core.active()` call,
so every read resolves the currently-active session record at call time. Sessions
become records in a list; switching flips one index.

**Tradeoffs:** Conceptually uniform and impossible to get subtly wrong — there is
no "did I remember to move this field" question, because nothing is classified at
all. But it touches roughly **777 `state.` call sites** (init 229, widgets 152,
render 136, gate 111, question 62, process 48, core 25, others). That is a
mechanical but enormous diff, unreviewable in one pass, and it churns every file
the open `[BUG]` items (`subagent-zorder-overlap`, `subagent-esc-shadowing`) also
touch — guaranteeing conflicts with in-flight bug work. Also a per-call function
invocation on the hottest render paths, where today it is an upvalue read.

### C — Split per-session vs panel-global

Classify each field. Per-session fields move into `state.sessions[i]` records;
panel-global fields stay flat on `Core.state`. Only call sites touching
per-session fields are rewritten. Full classification already done:

**Per-session (~29):** `job_id` · `session_cost` · `panel_buf` · `system_ready` ·
`working` · `diff_pending` · `diff_queue` · `prewrite` · `perm` · `spin_timer` ·
`typing_ph` · `model` · `model_display` · `effort` · `advisor_model` ·
`permission_mode` · `subagents` · `subagent_sel` · `queue` · `pad_rows` ·
`chat_draft` · `decision_reopen_bar` · `qask` · `diff_card` ·
`diff_card_reopen_bar` · `turn_paused_ms` · `pause_t0` · `turn_t0` (dynamic) ·
`session_id` (drop entirely)

**Panel-global (~11):** `claude_active` · `stored_root` · `panel_win` ·
`real_guicursor` · `chat_win` · `chat_buf` · `chat_close` · `slash_commands` ·
`host_file` · `host_ctx_last_path` · `host_ctx_enabled`

**Not state:** `width_pct`, `caveman_mode` live in `Core.opts` (`core.lua:290–296`).
Extmark namespace ids stay global — marks are already per-buffer, so they partition
for free once each session owns its buffer.

**Also outside `Core.state`, must be handled:** `Process.stdout_buf` (per-job, the
hard blocker above); `claude_diff.lua`'s own `M.state` (`claude_diff.lua:31`) —
per-session `current`/`scratch`/`orig_buf`/`kind`/`prewrite`/`pending_emit`/
`reveal_new`, panel-global `orig_win`/`scratch_win`/`orig_win_created`/
`orig_prev_buf`/`orig_prev_readonly`, with `pending_new`/`new_files`/`approved`/
`anchors` promoted to panel-global as the cross-tab clobber guard;
`gate.unknown_control_warned` (`gate.lua:136`, cosmetic).

**Tradeoffs:** Far smaller diff than A, and it models the domain honestly — the
classification is a design artifact worth having regardless. Risk is
misclassification: a field wrongly left global leaks between tabs, and the failure
is silent rather than loud. Mitigated by the audit above being complete and
line-referenced, and by the fact that most per-session fields are turn-scoped, so
a leak shows up immediately in manual use rather than lurking.

**Decisive argument for C over B:** the switcher must display background sessions'
status, cost, token count and subagent count. That data has to be readable while
the session is _inactive_. B gives it a home by construction — `state.sessions[i]`
records persist whether or not they are active. Under A, `core.active()` resolves
only the current session, so every background-session field the UI needs would
require a parallel registry anyway, re-introducing exactly the classification work
B claimed to avoid.

## Recommendation

**C — split per-session vs panel-global**, built in this order:

1. **Key `Process.stdout_buf` by job id.** Nothing else works first. Standalone,
   testable, no UI.
2. **Introduce `state.sessions[]` records + an active index**, with exactly one
   session in the list. Behaviour-identical; the whole suite must stay green.
3. **Migrate per-session fields** into the record, per the classification above.
   Still one session. Still behaviour-identical.
4. **Allow N > 1**: buffer per session, `nvim_win_set_buf` on switch.
5. **Winbar indicator**, then the switcher overlay.

UI shape, decided with the user:

- **Persistent indicator = the panel `winbar`.** One panel row, zero editor width,
  no float, no zindex slot, structurally immune to the unresolved z-order bug #7
  and the pet's kitty-image compositing. Shows active session title, position, and
  badges: `▎1 auth-refactor · 2 of 4  ⚑1`. Collapses to bare title at one session.
- **Switcher = transient bottom-anchored overlay**, same geometry family as the
  subagent bar (`SW` anchor, `row = vim.o.lines - 2`, full panel width, grows
  upward, joins `reflow_bottom_floats`). Opens on `<C-a>`, closes on pick.
- **Non-focusable** (`focusable = false`), steered via panel-buffer keymaps, like
  the subagent bar. **`<Esc>` is deliberately not bound** — Esc means interrupt,
  and a focusing overlay with its own Esc mapping would reproduce
  `.work/todos/subagent-esc-shadowing.md` exactly. `q` dismisses.
- **Row = five columns:** number · title · status · tokens · cost, plus a subagent
  count. Width-parameterised single renderer; at panel 48 the title truncates via
  `split_at_width()` (already built for the subagent bar) and the `↓` glyph drops.
  The status column is sized to `⚑ needs you`, the field least safe to truncate.
- **Totals row is unconditional**, not a wide-terminal luxury — aggregate burn
  across sessions is the number multi-session actually creates a need for.

```
╭─ ⬢ Sessions  (↑/↓ · Enter · 1-9 jump · d close · q dismiss) ───╮
│ ▸ 1  auth-refactor     ⣾ working  ◇2   ↓  28.4k       $0.42    │
│   2  docs sweep        ◦ idle          ↓   6.1k       $0.08    │
│   3  perf spike        ⚑ needs you ◇1  ↓  91.7k       $1.20    │
│   4  test harness      ✓ done 2m       ↓  12.3k       $0.15    │
├────────────────────────────────────────────────────────────────┤
│   4 sessions           total      ◇3   ↓ 138.5k       $1.85    │
╰────────────────────────────────────────────────────────────────╯
```

- **Keymaps:** `<C-a>` opens the switcher (`a` for agents, matching the user's own
  vocabulary, pairing with `<C-b>` for background subagents). `<leader>cn` creates
  a session — `n` is the only free letter in the leader-c family. Inside the
  overlay: `↑/↓` move, `<CR>` switch, `1`–`9` jump, `d` close, `q` dismiss.
- **Glyphs: sessions `⬢`, subagents `◇` (unchanged).** Hexagon is a shape family
  used nowhere in the panel, so it collides with no existing glyph. This matters
  because `◇N` appears _inside_ a session row as the subagent count — the two roles
  must not read as the same symbol.
- **Sessions and subagents stay separate surfaces, cross-referenced.** The subagent
  bar is _ambient_ (auto-opens on task events, auto-dismisses when all terminal,
  `widgets.lua:818–823`); the sessions list is _on-demand_. Merging forces either a
  permanently-open sessions list or subagents that need a keypress to discover —
  both regressions. The `◇N` column closes the real gap (background sessions'
  subagents being invisible) without merging. `subagents`/`subagent_sel` are
  per-session, so switching tabs swaps the ambient bar's contents for free.

## Open questions → for /grill-me

- **What happens to a background session's permission gate?** This is a protocol
  question, not a display one. A background session hitting `can_use_tool` has a
  live `request_id` the CLI is _blocking_ on, and cards render from active state
  today. Options: queue the card until the user switches to that session (turn
  stalls, possibly for a long time); auto-deny after a timeout; force-switch the
  panel to the session demanding attention; or answer from the switcher row itself.
  Each has a different failure mode and the `⚑ needs you` indicator is only
  meaningful once this is settled.
- **Transient vs pinned switcher.** Recommendation above is transient (costs no
  rows when idle, brief bug-#7 exposure). Pinned-open would show status without a
  keypress but permanently costs 6+ transcript rows. Asked twice during brainstorm,
  never explicitly chosen — needs a decision.
- **Bottom-stack height cap.** With 6 sessions plus 4 subagents plus the chat bar
  plus a permission card, the bottom float stack can exceed panel height. Needs a
  max-visible-rows cap with scrolling, and a rule for which surface yields first.
- **Max concurrent sessions.** Cap and the behaviour on exceeding it (refuse,
  or close the least-recently-used). Bounds memory, subprocess count, and the
  switcher's row budget.
- **`<leader>cr` (reset) and `<leader>cq` (quit) semantics per-tab vs all-tabs.**
  Today both are global. Per-tab reset is the obvious reading, but quit is
  ambiguous and teardown ordering matters given the documented stray-pane bugs.
- **Session titles: derived or user-set?** The wireframes assume short meaningful
  titles. Options: first user prompt truncated, CLI-provided summary, explicit
  rename command, or ordinal-only. Affects whether a title column is worth its
  width at all.
- **`<C-a>` live-verify.** The sweep covered `lua/config/` and `lua/plugins/`; a
  plugin's own default binding could still collide. Confirm with
  `:verbose nmap <C-a>` in a live session before building.
- **`⬢` font coverage.** U+2B22 is outside the widely-supported U+25xx Geometric
  Shapes block. Confirm it renders in the user's terminal font; fall back to `⧉`
  (U+29C9, semantically apt — layered panes) or an ASCII marker if not.
