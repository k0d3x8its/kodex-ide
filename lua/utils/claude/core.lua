-- lua/utils/claude/core.lua
--
-- Shared foundation for the claude/* package: the single mutable `state` table
-- (identity is shared across every claude/* module and consumers that read
-- mod.state), the merged `opts`, and the low-level buffer/highlight primitives
-- (panel_width, sep_line, buf_append, hl_lines, hl_range, free_below) that ≥2
-- render modules need. Extracted from the former monolithic claude.lua (Goal 15).
--
-- `set_bottom_pad` lives in init.lua (couples to the chat-bar pad logic); buf_append
-- calls it through a wired hook (Core.wire_set_bottom_pad) to avoid a require cycle.

local Core = {}

-- ─── Shared state ─────────────────────────────────────────────────────────────
--
-- Exposed as Core.state; init re-exports it as mod.state so claude_diff.lua and the
-- other package modules read/mutate the SAME table (identity matters).

Core.state = {
  -- true while the panel window is visible; gates the FileChangedShell interceptor
  -- in claude_diff.lua so diff events are only captured during claude sessions.
  claude_active = false,

  -- Project root captured when the panel first opens. Compared on each re-open
  -- to detect cross-project root changes (FINDINGS.md Q11 pattern).
  stored_root   = nil,

  -- Queue of file paths pending vimdiff review. Owned here so reset() can clear
  -- it; consumed by claude_diff.lua via the queue() accessor there.
  diff_queue    = {},

  -- vim.fn.jobstart channel handle. nil when no subprocess is running.
  -- jobstop(job_id) sends SIGTERM; on_exit fires after the process dies.
  job_id        = nil,

  -- Panel-owned conversation session UUID. nil until the first send, which
  -- generates one and passes it via --session-id (creating a fresh session).
  -- Every later send resumes it with --resume. We DON'T use --continue: that
  -- resumes the most-recent session in cwd, which collides with (and hangs on)
  -- any other claude session running in the same project root. Owning our own
  -- id isolates the panel's conversation. (FINDINGS.md § D2)
  session_id    = nil,

  -- Cumulative USD cost of THIS panel's own subprocess session, captured from each
  -- `result` event's total_cost_usd (which is session-cumulative). nil before the
  -- first turn. Statusline reads it via mod.session_cost(). Distinct from the burn
  -- state file's cost, which belongs to whatever interactive CC session last wrote
  -- it — this tracks the fresh session the panel spawned. Cleared on reset().
  session_cost  = nil,

  -- Scratch buffer id for the rendered panel content (nomodifiable).
  panel_buf     = nil,

  -- Window id of the panel window. nil when closed.
  panel_win     = nil,

  -- Flipped to true when the system/init event is parsed. Used only to guard
  -- the hint update in dispatch (not to block sends — see send() comment).
  system_ready  = false,

  -- true between a user send and the corresponding result event. Used to block
  -- new input and show the "⣾ Working… <Esc> to interrupt" hint.
  working       = false,

  -- true while claude_diff.lua has an unreviewed diff open. Blocks new input:
  -- we must not send a follow-up message while the previous edit is unreviewed.
  diff_pending  = false,

  -- Held pre-write edit permission (Issue-B gate, prototype: Write/Edit), or nil.
  -- { request_id, input } for the can_use_tool request the pre-write diff is
  -- reviewing; on_prewrite_resolve releases it as allow/deny. The CLI blocks the
  -- turn until then — exactly like a permission card, but the "card" is a vimdiff.
  prewrite      = nil,

  -- Active permission card, or nil. Set while a non-edit can_use_tool request is
  -- awaiting the user's Allow once / Allow always / Reject choice; blocks input
  -- and owns the hint until resolved. Holds request_id, tool, input, suggestions,
  -- the rendered choice-row index, the option list, and the current selection.
  perm          = nil,

  -- Extmark namespace for the permission card's choice-row highlights, so a
  -- left/right re-select can clear + repaint just that row without leaking marks.
  perm_ns       = nil,

  -- Extmark namespace for the virtual-text "Reply to Claude…" hint at bottom of
  -- panel. Cleared and re-set on every state transition.
  hint_ns       = nil,

  -- Active braille-spinner timer handle while a turn is in flight; nil otherwise.
  spin_timer    = nil,

  -- true while an animated in-body "typing" placeholder line occupies the panel's
  -- LAST line (compute dead-band filler; see the typing-placeholder block). The
  -- styled block replaces it when content lands. Distinct from the bottom hint,
  -- which is virt_text — this is a real buffer line so the empty body reads active.
  typing_ph     = false,

  -- Model alias/id passed to --model on (re)spawn. nil = CLI default model.
  -- Set by the <leader>cm picker; changing it respawns the process (model is a
  -- spawn-time flag, so the running session can't switch mid-flight).
  model         = nil,

  -- Reasoning-effort level passed to --effort on (re)spawn (low/medium/high/xhigh/
  -- max). nil = leave --effort unset so the CLI/model default applies. Set by the
  -- /effort slider (claude/effort.lua); like --model it's a spawn-time flag, so
  -- changing it respawns the process. The statusline shows it right of the model.
  effort        = nil,

  -- Advisor model for the server-side advisor tool (the "advisor strategy": the
  -- executor model escalates hard calls to a stronger advisor, then resumes).
  -- Alias/id: "opus" (default) / "sonnet" / "fable", or nil = No advisor (unset).
  -- Passed as --advisor on spawn; changed mid-session via an apply_flag_settings
  -- control_request (NO respawn / context reset — unlike --model/--effort). Set by
  -- the /advisor picker (claude/advisor.lua). Drives the "Advising using <model>"
  -- header, since the stream event itself does NOT carry the advisor model.
  advisor_model = "opus",

  -- Permission mode passed to --permission-mode on (re)spawn. "default" pairs
  -- with the hidden --permission-prompt-tool stdio flag (build_args) so the CLI
  -- routes tool-permission decisions to us via can_use_tool control_requests
  -- instead of auto-applying (acceptEdits) or auto-denying. <leader>cp toggles
  -- to "plan" (and back to "default"), respawning the process.
  permission_mode = "default",

  -- Open-buffer awareness (FINDINGS § Q-CTX; v2 = re-attach-on-change + echo note).
  -- host_file = the real file the user had open when the panel opened (captured
  -- pre-focus-steal): { path=<abs>, disp=<~/.-relative> } or nil — kept as a
  -- fallback; each send now resolves the LIVE editor file (current_host_file()) so
  -- switching files mid-session re-attaches. host_ctx_last_path = the abs path last
  -- folded in: a full @<path> inline fires when the live file DIFFERS from it
  -- (first turn / file switch), while a same-file repeat gets a cheap plain-text
  -- path breadcrumb instead (the content is already in history — re-inlining every
  -- turn bloats the window; the breadcrumb keeps a bare "this file" resolvable).
  -- Cleared on teardown.
  --
  -- Injection is ambient (OpenCode-style): the fold-in is appended to the WIRE
  -- only, the transcript echo stays the user's own text — but v2 adds a dim
  -- "· with @<file>" note under the echo (render_user) on a full inline so an
  -- attach is visible (breadcrumb turns show no note).
  -- host_ctx_enabled is the master on/off, toggled by <leader>cb and PERSISTED
  -- across restarts (see host_ctx_pref_*).
  host_file        = nil,
  host_ctx_last_path = nil,
  host_ctx_enabled = true,   -- overwritten from disk at module load

  -- Messages the user typed while a turn was in flight, FIFO. Shown as shaded
  -- virtual lines at the panel bottom; drained one-by-one as each turn ends
  -- (each then echoes in the normal user colour when actually sent).
  queue         = {},

  -- Extmark namespace for the shaded queued-message virtual lines. Separate from
  -- hint_ns so the 110ms spinner refresh (which clears hint_ns) doesn't wipe it.
  queue_ns      = nil,

  -- Extmark namespace for the bottom-pad virtual lines that reserve space under
  -- the chat float so the latest output stays visible above the input bar.
  pad_ns        = nil,

  -- Height (rows) of the active bottom pad while the chat bar is open, 0 otherwise.
  -- The over-scroll clamp adds it to its limit so the pad's push-up scroll isn't
  -- yanked back (the clamp and the pad would otherwise fight).
  pad_rows      = 0,

  -- The user's real (visible) 'guicursor', captured before the panel hides it.
  -- The chat bar restores this on open so the cursor is visible while typing.
  real_guicursor = nil,

  -- Friendly display name of the panel's current model (e.g. "Opus 4.8"), shown
  -- in the modal statusline. Filled from system/init and the model picker.
  model_display = "",

  -- Unsent text from the "Reply to Claude" chat bar, kept alive across hide/show.
  -- The bar's prompt buffer is wiped on close, so without this any half-typed
  -- message vanishes when the bar loses focus. Saved on a non-submit close,
  -- restored on the next open, and cleared only when the message is actually sent.
  chat_draft    = "",

  -- Live handle + closer for the open "Reply to Claude" chat bar, or nil when no
  -- bar is open. Tracked so the permission card can dismiss the bar before it
  -- opens: both floats anchor SW at the same panel column, so a coexisting bar
  -- overlaps the card and fights it for focus/draw order (the bug where the card
  -- never became interactable and auto-rejected). chat_close is the bar's own
  -- close() (saves the draft); set on open, cleared on close.
  chat_win      = nil,
  chat_buf      = nil,
  chat_close    = nil,
  -- True while a permission card is up that dismissed an open chat bar, so
  -- resolve_permission knows to reopen the bar (draft restored) afterwards.
  perm_reopen_bar = false,

  -- Active AskUserQuestion card, or nil. Set while a can_use_tool request for the
  -- AskUserQuestion tool is awaiting the user's choices. Rides the SAME gate as
  -- permissions but is a VERTICAL selector that STEPS through the N questions
  -- (.work/FINDINGS.md § Q-ASK). Holds request_id, the echo-back input, the
  -- questions list, the current question index (qi), the highlighted option
  -- (choice), per-question multiSelect toggles (sel), and the accumulated answers
  -- map (question text → label, or array of labels for multiSelect).
  qask          = nil,

  -- Extmark namespace for the question card's option-row highlights.
  qask_ns       = nil,

  -- True while a question card is up that dismissed an open chat bar, so the card
  -- knows to reopen it (draft restored) after the questions are answered/cancelled.
  qask_reopen_bar = false,

  -- Active diff-review card, or nil (Goal 14.3). Set while claude_diff.lua has an
  -- unreviewed diff open and this panel card is showing its Accept/Reject choice.
  -- Independent of state.perm: diff review happens AFTER the CLI's turn already
  -- completed the write (can_use_tool already resolved for the edit), so the two
  -- never contend for the same request. The winbar + <leader>ca/cx keymaps in
  -- claude_diff.lua remain a fallback — this card is additive, not a replacement.
  diff_card = nil,

  -- Extmark namespace for the diff card's choice-row highlights (mirrors perm_ns).
  diff_card_ns = nil,

  -- True while a diff card is up that dismissed an open chat bar, so on_diff_close
  -- knows to reopen it (draft restored) once the diff is resolved.
  diff_card_reopen_bar = false,

  -- Slash-command names advertised by the CLI in the system/init event
  -- (`slash_commands[]`, ~200 plain-string names, no descriptions). Captured once
  -- and reused to drive the chat bar's "/" command menu (see claude/slash.lua).
  -- Names only — descriptions are resolved separately from skill/command files.
  slash_commands = nil,

  -- Turn-timer pause accounting. While a decision modal (permission / prewrite /
  -- question / diff-review card) is up, the CLI is blocked on the USER, so the
  -- turn timer freezes and the spinner reads "Waiting…" (matching the official
  -- TUI). turn_paused_ms accumulates completed pauses; pause_t0 is the start of
  -- the CURRENT pause (nil when not paused). turn_elapsed_ms() subtracts both so
  -- the climbing timer + the "✻ …for Ns" done line exclude the wait. Reset at
  -- dispatch alongside turn_t0.
  turn_paused_ms = 0,
  pause_t0       = nil,
}
local state = Core.state

-- Wall-clock ms the model has actually been working this turn, EXCLUDING time
-- spent paused on a user-decision modal. now - turn_t0 minus the accumulated
-- pause total minus the in-progress pause (if currently paused). Shared by the
-- live spinner label and the past-tense done line so both read the same number.
function Core.turn_elapsed_ms()
  if not state.turn_t0 then return 0 end
  local paused = state.turn_paused_ms or 0
  if state.pause_t0 then paused = paused + (vim.loop.now() - state.pause_t0) end
  return vim.loop.now() - state.turn_t0 - paused
end

-- Mark the turn clock paused (a decision modal just went up). Idempotent — a
-- second call while already paused keeps the original start, so re-entrant paths
-- (spinner tick + card open racing) don't lose the pause origin.
function Core.pause_turn()
  if not state.pause_t0 then state.pause_t0 = vim.loop.now() end
end

-- Resume the turn clock (the modal resolved): fold the just-ended pause into the
-- accumulated total so turn_elapsed_ms() keeps excluding it. No-op if not paused.
function Core.resume_turn()
  if state.pause_t0 then
    state.turn_paused_ms = (state.turn_paused_ms or 0) + (vim.loop.now() - state.pause_t0)
    state.pause_t0 = nil
  end
end

Core.opts = {
  width_pct = 0.40,
  -- Caveman intensity for the panel's claude subprocess. Default "off" so the
  -- panel speaks normally even when the user's interactive sessions default to
  -- caveman — passed as CAVEMAN_DEFAULT_MODE to the spawn (the caveman plugin's
  -- env override). Set to false/nil to inherit the user's global default.
  caveman_mode = "off",
}
local opts = Core.opts

-- set_bottom_pad is defined in init.lua (pad/chat-bar coupling) and wired in
-- via Core.wire_set_bottom_pad; buf_append calls it through this forward local.
local set_bottom_pad

-- Panel width in columns, recomputed on every open so the panel tracks
-- terminal resizes rather than freezing at the width set at creation.
local function panel_width()
  -- Prefer the panel window's ACTUAL inner width once it exists. The percentage
  -- (columns × width_pct) is only the open-time target; after place_vertical the
  -- real window can be wider, and every padded surface (code blocks, separators,
  -- cards) must fill to that real edge — not stop short at the stale percentage.
  -- number/foldcolumn/signcolumn are forced off in open_panel_window, so the
  -- window width equals the text width (no gutter to subtract).
  local win = state.panel_win
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  return math.floor(vim.o.columns * opts.width_pct)
end

-- Fraction of the panel width a separator spans. Less than full width so the
-- divider reads as a light turn-marker, not a hard rule across the whole panel.
local SEP_FRAC = 0.5

-- Separator line — a fraction (SEP_FRAC) of the panel width, recomputed each
-- call so it shrinks/extends with the window instead of wrapping. Falls back to
-- the configured width when the window isn't realised yet (e.g. cold render).
local function sep_line()
  local w = panel_width()
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    w = vim.api.nvim_win_get_width(state.panel_win)
  end
  return string.rep("─", math.max(math.floor(w * SEP_FRAC), 1))
end

-- Append lines to the panel buffer, bypassing its nomodifiable lock.
--
-- Why toggle modifiable rather than use a plain writeable buffer?
--   nomodifiable prevents accidental edits (the user pressing random keys while
--   the panel is focused). We toggle it only for programmatic writes from this
--   module and immediately restore it, so the invariant holds for all user input.
--
-- Why scroll the panel window after each append?
--   Without this, the cursor stays at line 1 (where it was when the buffer was
--   created) and new content scrolls off-screen. Streaming output should auto-
--   follow to the bottom so the user sees it arrive in real time.
local function buf_append(lines)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.bo[buf].modifiable = true
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, last, last, false, lines)
  vim.bo[buf].modifiable = false
  -- auto-follow: keep the newest line in view as output streams. We use
  -- nvim_win_call + `normal! G` rather than nvim_win_set_cursor because setting
  -- the cursor of a NON-focused window (the common case — focus is in the input
  -- float or editor while Claude streams) doesn't reliably scroll that window's
  -- view; `G` inside win_call moves to the last line AND scrolls it into view.
  -- Guarded on the displayed buffer so we don't disturb a diff-review retarget.
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)
      and vim.api.nvim_win_get_buf(state.panel_win) == buf then
    -- When the chat bar is open it reserves `pad_rows` at the panel bottom; a plain
    -- `G` would scroll the newest line flush to the window bottom — UNDER the float.
    -- Streaming appends lines BELOW the pad's old anchor line, so we must MOVE the
    -- pad to the new last line (set_bottom_pad re-places it AND re-anchors), not
    -- just re-anchor — otherwise the pad sits mid-buffer and the lift is lost.
    if (state.pad_rows or 0) > 0 then
      if set_bottom_pad then set_bottom_pad(state.chat_pad or 0) end   -- re-place; total recomputed w/ widget
    else
      pcall(vim.api.nvim_win_call, state.panel_win, function()
        vim.cmd("keepjumps normal! G")
      end)
    end
  end
end

-- ─── Highlight helpers ────────────────────────────────────────────────────────

-- Apply a highlight group to a contiguous range of lines (0-indexed) in the
-- panel buffer. Used after buf_append to colour newly appended content.
-- ns_id = -1 lets Neovim assign a default priority; if two highlights cover the
-- same bytes on the same line the LAST one applied wins (used in render_banner
-- to paint ClaudeHeader on the glyph and ClaudeProse on the sidebar text).
local function hl_lines(first_line, last_line, group)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  for ln = first_line, last_line do
    vim.api.nvim_buf_add_highlight(buf, -1, group, ln, 0, -1)
  end
end

-- Apply a highlight group to a byte sub-range of a single line (0-indexed).
-- Used to apply mixed-color highlighting within one line (logo glyph vs text).
local function hl_range(line_0idx, byte_start, byte_end, group)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_add_highlight(buf, -1, group, line_0idx, byte_start, byte_end)
end

-- Screen rows between the last buffer line's final cell and the window bottom,
-- under the CURRENT view. Returns nil when the last line is scrolled off-screen
-- (the user scrolled up to read history). Must run inside nvim_win_call(win).
-- screenpos() reports the TRUE display row regardless of wrap or collapsed folds —
-- the property a buffer-line-count formula lacks.
local function free_below(win, buf)
  local n        = vim.api.nvim_buf_line_count(buf)
  local lasttext = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
  local sp       = vim.fn.screenpos(win, n, math.max(#lasttext, 1))
  if sp.row == 0 then return nil end
  local info = vim.fn.getwininfo(win)[1]
  return (info.winrow + info.height - 1) - sp.row
end

-- ─── Exports ──────────────────────────────────────────────────────────────────

Core.panel_width = panel_width
Core.sep_line    = sep_line
Core.buf_append  = buf_append
Core.hl_lines    = hl_lines
Core.hl_range    = hl_range
Core.free_below  = free_below

--- Wire init.lua's set_bottom_pad into buf_append's auto-follow pad path.
function Core.wire_set_bottom_pad(bottom_pad_setter) set_bottom_pad = bottom_pad_setter end

return Core
