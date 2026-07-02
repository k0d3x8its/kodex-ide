-- lua/utils/claude.lua
--
-- Claude Code panel — bidirectional stream-json subprocess + custom renderer.
--
-- Architecture: NOT a toggleterm TUI panel (unlike opencode.lua). Instead,
-- `claude` is spawned as a long-lived subprocess via vim.fn.jobstart() with
-- stdin="pipe", and its stdout is parsed as newline-delimited JSON events that
-- are rendered into a custom nomodifiable scratch buffer ("claude"). This is a
-- direct port of kos-capture/screens/ingest.py into Lua.
--
-- Why jobstart, not vim.system?
--   vim.system is fire-and-forget (one-shot async). jobstart keeps the channel
--   open so we can write JSON user messages to stdin at any time — the only API
--   that works for an interactive bidirectional subprocess.
--
-- Why a custom render buffer, not :terminal?
--   :terminal would show Claude Code's raw TUI (ANSI escape sequences, blinking
--   cursors, status bars). We want IDE-native rendering: Neovim highlight groups,
--   manual folds for thinking blocks, and a virtual-text input hint. The custom
--   buffer gives us full control over what the panel looks like.
--
-- Design references:
--   FINDINGS.md § Claude Code Panel  — all architectural decisions
--   neo-claude.md §6                 — implementation outline
--   kos-capture/screens/ingest.py   — Python reference implementation (port source)

local mod = {}

-- Full path required — ~/.local/bin is only on PATH in interactive bash, never
-- in Neovim's environment. Matches the OPENCODE_BIN pattern in opencode.lua
-- (findings Q12). vim.fn.expand resolves "~" at call time.
mod.CLAUDE_BIN = vim.fn.expand("~/.local/bin/claude")

--- Guard: returns true iff the claude binary exists and is executable.
-- Does NOT attempt /login or any auth check — /login is interactive inside
-- the agent and cannot be tested programmatically at launch.
---@return boolean
function mod.is_available()
  return vim.fn.executable(mod.CLAUDE_BIN) == 1
end

-- Centralised guard called before toggle / ask_selection. Shows an error notify
-- once and returns false, so callers can exit early with a single line.
local function ensure_available()
  if mod.is_available() then return true end
  vim.notify(
    "claude not found at ~/.local/bin/claude — install Claude Code",
    vim.log.levels.ERROR
  )
  return false
end

-- Panel winhighlight: background + end-of-buffer highlight, scoped to this window.
-- NOTE: winhighlight cannot override Cursor/CursorNC (see :h winhighlight — those
-- groups are explicitly excluded). Cursor hiding is done via guicursor WinEnter/WinLeave.
-- Folded:ClaudeLabel paints the collapsed "▶ Thought" foldtext row in the same
-- bold purple as the expanded header, so the block reads consistently in either state.
local PANEL_HL_BASE = "Normal:ClaudeNormal,NormalNC:ClaudeNormal,EndOfBuffer:ClaudeNormal,Folded:ClaudeLabel"

-- ─── Shared state ─────────────────────────────────────────────────────────────
--
-- Exposed as mod.state so claude_diff.lua can read claude_active and share
-- diff_queue without coupling to the internal spawn/close logic.

mod.state = {
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

  -- Permission mode passed to --permission-mode on (re)spawn. "default" pairs
  -- with the hidden --permission-prompt-tool stdio flag (build_args) so the CLI
  -- routes tool-permission decisions to us via can_use_tool control_requests
  -- instead of auto-applying (acceptEdits) or auto-denying. <leader>cp toggles
  -- to "plan" (and back to "default"), respawning the process.
  permission_mode = "default",

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
}
local state = mod.state

local opts = {
  width_pct = 0.40,
  -- Caveman intensity for the panel's claude subprocess. Default "off" so the
  -- panel speaks normally even when the user's interactive sessions default to
  -- caveman — passed as CAVEMAN_DEFAULT_MODE to the spawn (the caveman plugin's
  -- env override). Set to false/nil to inherit the user's global default.
  caveman_mode = "off",
}

--- Merge user-provided options from the lazy plugin spec (FINDINGS.md Q9).
-- Idempotent — safe to call multiple times (last call wins for each key).
function mod.setup(user_opts)
  opts = vim.tbl_deep_extend("force", opts, user_opts or {})
end

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

-- ─── Model display names + session id (port of ingest.py _MODEL_NAMES) ───────

-- Model-id → friendly display name. Substring match (model ids carry date
-- suffixes), so "claude-opus-4-8" → "Opus 4.8". Mirrors ingest.py _MODEL_NAMES;
-- the most recent ids come first so a longer id never shadows a shorter prefix.
local MODEL_NAMES = {
  { "claude-opus-4-8",            "Opus 4.8" },
  { "claude-opus-4-7",           "Opus 4.7" },
  { "claude-sonnet-4-6",         "Sonnet 4.6" },
  { "claude-haiku-4-5",          "Haiku 4.5" },
  { "claude-opus-4-5",           "Opus 4.5" },
  { "claude-sonnet-4-5",         "Sonnet 4.5" },
  { "claude-3-5-sonnet",         "Sonnet 3.5" },
  { "claude-3-opus",             "Opus 3" },
  { "claude-3-haiku",            "Haiku 3" },
  -- Bare aliases (from the <leader>cm picker, before system/init confirms the
  -- exact id) → the friendly name of the latest model in each family. Listed
  -- LAST so a full date-suffixed id always matches its specific entry first.
  { "opus",                      "Opus 4.8" },
  { "sonnet",                    "Sonnet 4.6" },
  { "haiku",                     "Haiku 4.5" },
}

-- Map a raw model id to its friendly name, falling back to the id itself when
-- unknown (so a new model still shows something rather than a blank line).
local function friendly_model(model_id)
  if not model_id or model_id == "" then return "" end
  for _, pair in ipairs(MODEL_NAMES) do
    if model_id:find(pair[1], 1, true) then return pair[2] end
  end
  return model_id
end

-- Claude Code version derived from the binary's install path WITHOUT spawning a
-- session. The launcher (~/.local/bin/claude) symlinks into
-- ~/.local/share/claude/versions/<version>, so the realpath's basename is the
-- version string (e.g. "2.1.186"). Lets the banner show the version at panel
-- open, before system/init (which only arrives after the first message). Mirrors
-- KOS Capture's realpath fallback. Returns "" if the path can't be resolved.
local function binary_version()
  local rp = vim.loop.fs_realpath(mod.CLAUDE_BIN)
  if not rp then return "" end
  local base = vim.fn.fnamemodify(rp, ":t")
  -- Only accept a version-looking basename (digits + dots); otherwise blank.
  return base:match("^%d[%d%.]*$") and base or ""
end

-- Generate a RFC-4122 v4 UUID in pure Lua (no shell-out to uuidgen). Used once
-- per panel session for --session-id. math.random is seeded once at require.
math.randomseed(os.time() + (vim.loop.hrtime() % 1000000))
local function uuid4()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

-- ─── Tool verb table (port of ingest.py _TOOL_VERB) ──────────────────────────

-- Maps Claude tool names to human-readable action verbs shown in the panel.
-- Matches the verb table in kos-capture/screens/ingest.py so the panel UX
-- feels consistent with KOS Capture.
local TOOL_VERB = {
  Read         = "Reading",
  Write        = "Wrote",
  Edit         = "Editing",
  MultiEdit    = "Editing",
  Bash         = "Running",
  Glob         = "Listing",
  Grep         = "Searching",
  WebFetch     = "Fetching",
  WebSearch    = "Searching",
  NotebookRead = "Reading",
  NotebookEdit = "Editing",
}

-- Per-verb highlight overrides for the "⚙ <verb>" tool lines. Without these every
-- verb paints ClaudeTool (the same purple as the thinking blocks + fold headers),
-- so a Read and a Bash are indistinguishable at a glance. Reading (passive
-- inspect) → teal, Running (active execute) → amber; any verb not listed falls
-- back to ClaudeTool. Keyed by the resolved VERB, so Read + NotebookRead share it.
local TOOL_HL = {
  Reading = "ClaudeToolRead",
  Running = "ClaudeToolRun",
}

-- Extract the most meaningful target string from a tool_use input dict.
-- Priority: file_path > path > pattern > query > command (truncated to 70 chars).
-- Falls back to "" when none present, so callers can skip the target display.
local function tool_target(input)
  local t = input.file_path
    or input.path
    or input.pattern
    or input.query
    or (input.command and tostring(input.command):sub(1, 70))
    or ""
  -- This value renders as ONE line (the "⚙ Verb: target" entry). A multi-line
  -- command/query (e.g. a Bash heredoc, or a `find … \n …`) keeps its newline
  -- through the :sub() truncation, and nvim_buf_set_lines REJECTS any item with an
  -- embedded newline → render_tool crashes the whole dispatch (hit on a Bash tool
  -- whose command spanned lines). Collapse all vertical whitespace to spaces here.
  return (t:gsub("[\r\n\t]+", " "))
end

-- ─── Buffer append helper ─────────────────────────────────────────────────────

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
-- Forward-declared (defined below) so buf_append's auto-follow can, when the chat
-- bar is open, RE-PLACE the bottom pad at the new last line and lift it above the
-- bar — instead of scrolling it flush to the window bottom (under the float).
local anchor_last_line
local set_bottom_pad

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
      set_bottom_pad(state.pad_rows)
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

-- Decide the display text + highlight group for an inline `…` span. Priority:
--   1. Known file type → its nvim-web-devicons glyph + the language's DevIcon
--      highlight group (correct brand/theme colour), e.g. `init.lua` → " init.lua"
--      in DevIconLua blue. Falls back gracefully when devicons isn't loaded.
--   2. [bracket] tag       → ClaudeBracket (pink)
--   3. path (~ ./ or has /) → ClaudePath (green)
--   4. anything else        → ClaudeCode (cyan)
-- Returns: display_text, hl_group.
local function span_style(inner)
  local fname = inner:match("([^/%s]+)$")          -- basename of a path
  local ext   = fname and fname:match("%.([%w]+)$")
  if ext then
    local ok, dev = pcall(require, "nvim-web-devicons")
    if ok then
      local icon, hl = dev.get_icon(fname, ext, { default = false })
      if icon and hl then
        return icon .. " " .. inner, hl
      end
    end
  end
  if inner:match("^%[.*%]$") then return inner, "ClaudeBracket" end
  if inner:match("^~") or inner:match("^%.?%./") or inner:find("/", 1, true) then
    return inner, "ClaudePath"
  end
  return inner, "ClaudeCode"
end

-- Parse one line of inline markdown, STRIPPING the markers (so the panel reads
-- like rendered markdown, not raw text) and recording highlight ranges over the
-- cleaned line. Handles **bold** → ClaudeBold and `code` → ClaudeCode.
-- Returns: clean_line, { {byte_start0, byte_end, group}, ... }  (byte offsets are
-- 0-indexed start / end-exclusive, matching nvim_buf_add_highlight).
-- Defined above render_prose because Lua `local function` is only visible to
-- code that follows it.
local function parse_inline(line)
  local parts, hls, blen, i, n = {}, {}, 0, 1, #line
  while i <= n do
    if line:sub(i, i + 1) == "**" then
      local close = line:find("**", i + 2, true)
      if close then
        local inner = line:sub(i + 2, close - 1)
        parts[#parts + 1] = inner
        hls[#hls + 1] = { blen, blen + #inner, "ClaudeBold" }
        blen = blen + #inner
        i = close + 2
      else
        parts[#parts + 1] = "**"; blen = blen + 2; i = i + 2
      end
    elseif line:sub(i, i) == "`" then
      local close = line:find("`", i + 1, true)
      if close then
        local inner = line:sub(i + 1, close - 1)
        -- span_style picks the display text (with a file glyph when it's a known
        -- file type) and the colour (DevIcon / bracket / path / code).
        local disp, group = span_style(inner)
        parts[#parts + 1] = disp
        hls[#hls + 1] = { blen, blen + #disp, group }
        blen = blen + #disp
        i = close + 1
      else
        parts[#parts + 1] = "`"; blen = blen + 1; i = i + 1
      end
    elseif line:sub(i, i) == "[" then
      -- Bracketed spans (e.g. [VERIFY], [link text]) — kept verbatim (brackets
      -- are meaningful) but coloured distinctly from inline code so they don't
      -- read as teal. Requires a closing "]" on the same line.
      local close = line:find("]", i + 1, true)
      if close then
        local seg = line:sub(i, close)        -- includes the [ and ]
        parts[#parts + 1] = seg
        hls[#hls + 1] = { blen, blen + #seg, "ClaudeBracket" }
        blen = blen + #seg
        i = close + 1
      else
        parts[#parts + 1] = "["; blen = blen + 1; i = i + 1
      end
    else
      local c = line:sub(i, i)
      parts[#parts + 1] = c; blen = blen + #c; i = i + 1
    end
  end
  return table.concat(parts), hls
end

-- ─── Markdown table rendering ────────────────────────────────────────────────

-- A markdown table row: trimmed line that starts with "|".
local function is_table_row(s) return s:match("^%s*|") ~= nil end

-- A table separator row (|---|:--:|): only |, -, :, spaces.
local function is_table_sep(s)
  return is_table_row(s) and (s:gsub("[%s|:%-]", "") == "") and s:find("%-") ~= nil
end

-- Split "| a | b |" into trimmed cell strings (drops the outer pipes).
local function split_row(s)
  s = s:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for cell in (s .. "|"):gmatch("(.-)|") do
    cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
  end
  return cells
end

-- Box-drawing glyphs for the table frame (all U+250x, 3 bytes each in UTF-8).
local TBL = {
  H = "─", V = "│",
  TL = "┌", TM = "┬", TR = "┐",   -- top    rule corners/tee
  ML = "├", MM = "┼", MR = "┤",   -- header divider corners/tee
  BL = "└", BM = "┴", BR = "┘",   -- bottom rule corners/tee
}

-- One horizontal rule line (top / header divider / bottom). Each column gets
-- widths[c] + 2 horizontal glyphs (the +2 is the one-space pad on each side of
-- the cell text). Whole line is dimmed.
local function table_rule(left, mid, right, widths)
  local segs = { left }
  for c = 1, #widths do
    segs[#segs + 1] = string.rep(TBL.H, widths[c] + 2)
    segs[#segs + 1] = (c < #widths) and mid or right
  end
  local line = table.concat(segs)
  return line, { { 0, #line, "ClaudeDim" } }
end

-- One content line "│ a │ b │" with shifted cell highlights. is_header bolds the
-- Take a leading prefix of `s` whose DISPLAY width is ≤ w (always ≥ 1 char so a
-- hard-break can't stall). UTF-8 aware: steps whole codepoints, not bytes.
local function disp_take(s, w)
  local out, dw, i = "", 0, 1
  while i <= #s do
    local b   = s:byte(i)
    local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
    local ch  = s:sub(i, i + len - 1)
    local cw  = vim.fn.strdisplaywidth(ch)
    if dw + cw > w then break end
    out = out .. ch; dw = dw + cw; i = i + len
  end
  if out == "" then out = s:sub(1, 1) end             -- always consume ≥ 1 byte
  return out
end

-- Word-wrap `s` to display width `w`, hard-breaking any single token wider than
-- the column. Returns a list of sub-lines (at least one).
local function wrap_text(s, w)
  if w < 1 then w = 1 end
  if vim.fn.strdisplaywidth(s) <= w then return { s } end
  local lines, cur = {}, ""
  for word in s:gmatch("%S+") do
    local cand = (cur == "") and word or (cur .. " " .. word)
    if vim.fn.strdisplaywidth(cand) <= w then
      cur = cand
    else
      if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
      while vim.fn.strdisplaywidth(word) > w do      -- hard-break long tokens
        local part = disp_take(word, w)
        lines[#lines + 1] = part
        word = word:sub(#part + 1)
      end
      cur = word
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  if #lines == 0 then lines = { "" } end
  return lines
end

-- Render a run of markdown table rows into display lines + highlight ranges,
-- drawn as a real box-framed table: a top rule, the (bold) header row, a header
-- divider, the body rows, and a bottom rule. Frame glyphs are dimmed; cell text
-- is inline-parsed so paths/code/brackets keep their colours. The |---| markdown
-- separator row is dropped.
--
-- Width-fitting: a naive table can be far wider than the panel, which makes
-- Neovim hard-wrap each line and shatter the box. So column widths are capped to
-- fit panel_width() — the widest column is shaved repeatedly until the frame
-- fits — and over-long cells WRAP onto extra physical rows inside the box (the
-- row's height = its tallest wrapped cell). Returns out_lines, out_hls.
local function render_table(rows)
  -- Raw (unparsed) cell strings per row — parsing is deferred until after
  -- wrapping so highlight offsets line up with each wrapped sub-line.
  local raw_rows, ncols = {}, 0
  for _, r in ipairs(rows) do
    if not is_table_sep(r) then
      local cells = split_row(r)
      ncols = math.max(ncols, #cells)
      raw_rows[#raw_rows + 1] = cells
    end
  end
  if #raw_rows == 0 then return {}, {} end

  -- Natural (uncapped) column display widths.
  local widths = {}
  for c = 1, ncols do widths[c] = 0 end
  for _, cells in ipairs(raw_rows) do
    for c = 1, ncols do
      local w = vim.fn.strdisplaywidth(cells[c] or "")
      if w > widths[c] then widths[c] = w end
    end
  end

  -- Cap to the panel: frame overhead is each column's two pad spaces + its right
  -- border (3) plus the one leading border (1). Shave the widest column until the
  -- content fits the remaining budget.
  local avail   = math.max(panel_width() - 2, 20)
  local budget  = avail - (ncols * 3 + 1)
  if budget >= ncols then
    local total = 0
    for c = 1, ncols do total = total + widths[c] end
    while total > budget do
      local mi, mv = 1, widths[1]
      for c = 2, ncols do if widths[c] > mv then mi, mv = c, widths[c] end end
      widths[mi] = widths[mi] - 1
      total = total - 1
    end
  end
  for c = 1, ncols do if widths[c] < 1 then widths[c] = 1 end end

  local out_lines, out_hls = {}, {}
  local function push(line, hls) out_lines[#out_lines + 1] = line; out_hls[#out_hls + 1] = hls end

  push(table_rule(TBL.TL, TBL.TM, TBL.TR, widths))            -- top rule
  for ri, cells in ipairs(raw_rows) do
    -- Wrap each cell to its capped width; the row spans the tallest cell.
    local wrapped, height = {}, 1
    for c = 1, ncols do
      wrapped[c] = wrap_text(cells[c] or "", widths[c])
      if #wrapped[c] > height then height = #wrapped[c] end
    end
    for k = 1, height do                                      -- one physical line per wrap row
      local segs, hls, blen = {}, {}, 0
      segs[#segs + 1] = TBL.V; hls[#hls + 1] = { blen, blen + #TBL.V, "ClaudeDim" }; blen = blen + #TBL.V
      for c = 1, ncols do
        segs[#segs + 1] = " "; blen = blen + 1
        local clean, ih = parse_inline(wrapped[c][k] or "")
        for _, h in ipairs(ih) do hls[#hls + 1] = { blen + h[1], blen + h[2], h[3] } end
        if ri == 1 then hls[#hls + 1] = { blen, blen + #clean, "ClaudeBold" } end
        segs[#segs + 1] = clean; blen = blen + #clean
        local pad = widths[c] - vim.fn.strdisplaywidth(clean)
        if pad > 0 then segs[#segs + 1] = string.rep(" ", pad); blen = blen + pad end
        segs[#segs + 1] = " "; blen = blen + 1
        segs[#segs + 1] = TBL.V; hls[#hls + 1] = { blen, blen + #TBL.V, "ClaudeDim" }; blen = blen + #TBL.V
      end
      push(table.concat(segs), hls)
    end
    if ri == 1 then push(table_rule(TBL.ML, TBL.MM, TBL.MR, widths)) end  -- header divider
  end
  push(table_rule(TBL.BL, TBL.BM, TBL.BR, widths))            -- bottom rule
  return out_lines, out_hls
end

-- ─── Directory-tree rendering ────────────────────────────────────────────────

-- Folder glyph (nf-fa-folder) prefixed to directory entries in a tree.
local TREE_FOLDER_GLYPH = ""

-- True when a line is part of an ASCII/Unicode directory tree: it either has a
-- box-drawing connector (│ ├ └ ──) OR is a lone path token (a single dir ending
-- "/" or a file with an extension), optionally trailed by a "# comment".
local function is_tree_line(line)
  if line:find("│", 1, true) or line:find("├", 1, true)
      or line:find("└", 1, true) or line:find("──", 1, true) then
    return true
  end
  local body  = line:match("^%s*(.-)%s*$")
  local first = body:match("^(%S+)")
  if not first then return false end
  local after = body:sub(#first + 1):match("^%s*(.-)%s*$")
  local lone  = (after == "" or after:sub(1, 1) == "#")
  return lone and (first:sub(-1) == "/" or first:match("%.%w+$") ~= nil) or false
end

-- Byte index of the end of the box-drawing structure prefix (0 when none).
local function tree_prefix_end(line)
  local pos = 0
  for _, b in ipairs({ "│", "├", "└", "─" }) do
    local s = 1
    while true do
      local a, e = line:find(b, s, true)
      if not a then break end
      if e > pos then pos = e end
      s = e + 1
    end
  end
  return pos
end

-- Render one tree line: dim the box-drawing structure, then colour each entry
-- token — directories (trailing "/") get a folder glyph + ClaudeDir, files get
-- their devicons glyph + language colour (same as everywhere else), a leading
-- "#" comment is dimmed, and anything else stays prose. Returns display, hls.
local function render_tree_line(line)
  local out, hls, blen = {}, {}, 0
  local pend = tree_prefix_end(line)
  if pend > 0 then
    local pref = line:sub(1, pend)
    out[#out + 1] = pref
    hls[#hls + 1] = { 0, #pref, "ClaudeDim" }
    blen = #pref
  end

  local rest = line:sub(pend + 1)
  local idx  = 1
  while idx <= #rest do
    local ws = rest:match("^(%s+)", idx)
    if ws then out[#out + 1] = ws; blen = blen + #ws; idx = idx + #ws end
    if idx > #rest then break end
    local tok = rest:match("^(%S+)", idx)
    if not tok then break end
    idx = idx + #tok

    if tok:sub(1, 1) == "#" then
      -- comment: dim to end of line
      local comment = tok .. rest:sub(idx)
      out[#out + 1] = comment
      hls[#hls + 1] = { blen, blen + #comment, "ClaudeDim" }
      blen = blen + #comment
      idx  = #rest + 1
    elseif #tok > 1 and tok:sub(-1) == "/" then
      local seg = TREE_FOLDER_GLYPH .. " " .. tok
      out[#out + 1] = seg
      hls[#hls + 1] = { blen, blen + #seg, "ClaudeDir" }
      blen = blen + #seg
    else
      local fname = tok:match("([^/]+)$")
      local ext   = fname and fname:match("%.([%w]+)$")
      local icon, hl
      if ext then
        local ok, dev = pcall(require, "nvim-web-devicons")
        if ok then icon, hl = dev.get_icon(fname, ext, { default = false }) end
      end
      if icon and hl then
        local seg = icon .. " " .. tok
        out[#out + 1] = seg
        hls[#hls + 1] = { blen, blen + #seg, hl }
        blen = blen + #seg
      else
        out[#out + 1] = tok
        blen = blen + #tok
      end
    end
  end
  return table.concat(out), hls
end

-- ─── Rich markdown block elements (headings / lists / quotes / rules / code) ──
-- Each predicate classifies one raw line; each renderer returns either a single
-- (display, hls) pair (heading/hrule/quote/list) or, for fenced code, a run of
-- lines built by render_code_block. All highlight byte offsets are 0-indexed
-- start / end-exclusive, matching nvim_buf_add_highlight (same contract as
-- parse_inline / render_table). Colours come from the Claude palette so the
-- rendered markdown stays cohesive with the rest of the panel.

-- Right-pad a string with spaces to a target DISPLAY width (multibyte-safe), so a
-- background highlight paints as a solid rectangle to the panel edge (used for
-- heading bars and code-block panels). Defined up here so render_heading can use
-- it too.
local function pad_display(s, w)
  local pad = w - vim.fn.strdisplaywidth(s)
  return pad > 0 and (s .. string.rep(" ", pad)) or s
end

-- ATX heading: 1–6 leading '#', then a space. (Fenced code is handled before
-- this in build_md_lines, so a '#' inside a code block never reaches here.)
local function is_heading(s) return s:match("^#+%s") ~= nil and #s:match("^(#+)") <= 6 end

-- Horizontal rule: a line of only ---, ***, or ___ (3+), ignoring surrounding
-- space. Table separators (which contain '|') are matched earlier, so this only
-- sees true rules.
local function is_hrule(s)
  local t = s:gsub("%s", "")
  return t:match("^%-%-%-+$") ~= nil or t:match("^%*%*%*+$") ~= nil or t:match("^___+$") ~= nil
end

local function is_quote(s)      return s:match("^%s*>") ~= nil end
local function is_list_item(s)  return s:match("^%s*[%-%*%+]%s") ~= nil or s:match("^%s*%d+[%.%)]%s") ~= nil end
local function is_fence(s)      return s:match("^%s*```") ~= nil end

-- Heading → blue, bold, on a full-width background bar so it reads as a section
-- banner. The literal #/##/### markers are KEPT (per user pref) as the level cue
-- and share the heading colour; only a trailing run of #'s is dropped. The line
-- is padded to panel width so the bg fills the whole row. Heading text is
-- inline-parsed so `code`/**bold** inside a heading still style.
local function render_heading(line)
  local hashes = line:match("^(#+)")
  local prefix = line:match("^(#+%s*)")              -- "# " incl. the space(s)
  local body   = line:gsub("%s*#+%s*$", "")          -- drop optional closing ###
  local rest   = body:sub(#prefix + 1)
  local group  = (#hashes == 1 and "ClaudeH1") or (#hashes == 2 and "ClaudeH2") or "ClaudeH3"
  local clean_rest, ihls = parse_inline(rest)
  local text   = prefix .. clean_rest
  local padded = pad_display(text, math.max(panel_width() - 2, vim.fn.strdisplaywidth(text)))
  local hls    = { { 0, #padded, group } }           -- bg bar + fg over the whole row
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
  return padded, hls
end

-- Horizontal rule → a dim full-width line, sitting just inside the panel edges.
local function render_hrule()
  local w    = math.max(panel_width() - 4, 10)
  local line = string.rep("─", w)
  return line, { { 0, #line, "ClaudeDim" } }
end

-- Blockquote → a clay left bar ("▌") + muted italic body. One '>' level is
-- stripped; deeper nesting just keeps the extra '>' in the (still-quoted) text.
local QUOTE_BAR = "▌ "
local function render_quote(line)
  local body = line:gsub("^%s*>%s?", "")
  local clean, ihls = parse_inline(body)
  local out  = QUOTE_BAR .. clean
  local bar  = #"▌"                                  -- byte length of the bar glyph
  local hls  = { { 0, bar, "ClaudeQuoteBar" }, { #QUOTE_BAR, #out, "ClaudeQuote" } }
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #QUOTE_BAR + h[1], #QUOTE_BAR + h[2], h[3] } end
  return out, hls
end

-- List item → marker replaced by a clay bullet glyph (•/◦ by nesting depth) or,
-- for ordered lists, the original "N." kept but coloured; item text inline-parsed.
local function render_list_item(line)
  local indent, marker, rest = line:match("^(%s*)([%-%*%+])%s+(.*)$")
  if marker then
    local glyph  = (math.floor(#indent / 2) % 2 == 0) and "•" or "◦"
    local clean, ihls = parse_inline(rest)
    local prefix = indent .. glyph .. " "
    local hls    = { { #indent, #indent + #glyph, "ClaudeBullet" } }
    for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
    return prefix .. clean, hls
  end
  local oindent, num, sep, orest = line:match("^(%s*)(%d+)([%.%)])%s+(.*)$")
  local clean, ihls = parse_inline(orest)
  local prefix = oindent .. num .. sep .. " "
  local hls    = { { #oindent, #oindent + #num + #sep, "ClaudeBullet" } }
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
  return prefix .. clean, hls
end

-- Left gutter for fenced code rows: the clay ▎ bar plus a 3-space inset so code
-- text floats off the bar instead of jamming against it (pad_display is up top).
-- The block bg is painted from the bar's end (not from here), so this whole pad
-- sits inside the recessed panel — see render_code_block.
local CODE_GUTTER = "▎   "

-- Common fenced-language hints → treesitter parser names.
local TS_LANG = {
  js = "javascript", jsx = "javascript", ts = "typescript", tsx = "tsx",
  py = "python", rb = "ruby", sh = "bash", shell = "bash", zsh = "bash",
  yml = "yaml", md = "markdown", rs = "rust", cpp = "cpp", ["c++"] = "cpp",
  golang = "go", h = "c", hpp = "cpp",
}

-- Compute treesitter syntax highlights for a fenced code body. Parses the body
-- AS A STRING (no buffer needed), runs the language's `highlights` query, and
-- Map a treesitter capture name → one of our themed ClaudeCode* groups (which
-- bake in the block bg). Keyed by the TOP-LEVEL capture (so keyword.function,
-- string.escape, comment.todo, punctuation.bracket … collapse onto their
-- family). This covers EVERY colour-bearing family in the standard treesitter
-- highlight set, so real code tokens never fall back to neutral.
--
-- Deliberately NOT mapped: the control captures @spell / @nospell / @conceal /
-- @none. They carry no colour and their ranges OVERLAP @comment/@string — mapping
-- them would repaint comments and strings neutral and destroy those colours. They
-- must stay unmapped so the real colour underneath shows.
local CODE_CAP = {
  -- keywords & control flow
  keyword = "ClaudeCodeKeyword", conditional = "ClaudeCodeKeyword",
  ["repeat"] = "ClaudeCodeKeyword", label = "ClaudeCodeKeyword",
  exception = "ClaudeCodeKeyword", include = "ClaudeCodeKeyword",
  -- operators / punctuation
  operator = "ClaudeCodeOper", punctuation = "ClaudeCodePunc",
  -- literals
  string = "ClaudeCodeString", character = "ClaudeCodeString",
  number = "ClaudeCodeNumber", float = "ClaudeCodeNumber", boolean = "ClaudeCodeNumber",
  -- comments
  comment = "ClaudeCodeComment",
  -- callables
  ["function"] = "ClaudeCodeFunc", method = "ClaudeCodeFunc", constructor = "ClaudeCodeFunc",
  -- types / modules / tags
  type = "ClaudeCodeType", module = "ClaudeCodeType", namespace = "ClaudeCodeType",
  tag = "ClaudeCodeType",
  -- constants / attributes
  constant = "ClaudeCodeConst", attribute = "ClaudeCodeConst",
  -- identifiers
  variable = "ClaudeCodeVar", property = "ClaudeCodeVar",
  field = "ClaudeCodeVar", parameter = "ClaudeCodeVar",
  -- markup / prose / diff (markdown-in-code, legacy @text.*, diff fences)
  markup = "ClaudeCodeVar", text = "ClaudeCodeVar", diff = "ClaudeCodeVar",
  title = "ClaudeCodeKeyword", uri = "ClaudeCodeString", math = "ClaudeCodeNumber",
  environment = "ClaudeCodeType", note = "ClaudeCodeComment", warning = "ClaudeCodeComment",
  danger = "ClaudeCodeComment", todo = "ClaudeCodeComment", error = "ClaudeCodeComment",
}
local function code_group(name)
  return CODE_CAP[name:gsub("%..*$", "")]            -- top-level family only
end

-- Compute treesitter syntax highlights for a fenced code body. Parses the body
-- AS A STRING (no buffer needed), runs the language's `highlights` query, and
-- returns a table keyed by 1-based body-line index → list of {col0, col1, group}
-- (byte columns; group is a themed ClaudeCode* name). Returns nil when no
-- parser/query is available so the caller falls back to the flat neutral block.
-- Fully guarded — a missing parser must never break rendering.
local function code_ts_hls(lang, body)
  if lang == "" then return nil end
  -- nvim-treesitter is lazy-loaded on BufReadPre/BufNewFile (see plugins/treesitter.lua).
  -- When the Claude panel renders a code block before any file buffer has been opened
  -- (dashboard → panel), the plugin hasn't loaded, so its parser/ dir is not on
  -- runtimepath and get_string_parser throws "No parser for language X" → flat code.
  -- Force the plugin to load once so the language parsers are registered. require is
  -- memoised, so this is a no-op after the first call.
  pcall(require, "nvim-treesitter")
  local plang = TS_LANG[lang:lower()] or lang:lower()
  local src   = table.concat(body, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, plang)
  if not ok or not parser then return nil end
  local got_q, query = pcall(vim.treesitter.query.get, plang, "highlights")
  if not got_q or not query then return nil end
  local ok_tree, trees = pcall(function() return parser:parse() end)
  if not ok_tree or not trees or not trees[1] then return nil end
  local root = trees[1]:root()

  local by_line = {}
  local function add(row0, c0, c1, group)
    if c1 <= c0 then return end
    local li = row0 + 1
    by_line[li] = by_line[li] or {}
    by_line[li][#by_line[li] + 1] = { c0, c1, group }
  end
  local ok_iter = pcall(function()
    for id, node in query:iter_captures(root, src, 0, -1) do
      local name  = query.captures[id]
      local group = name and code_group(name)
      if group then
        local srow, scol, erow, ecol = node:range()
        if srow == erow then
          add(srow, scol, ecol, group)
        else                                        -- multi-line: first→EOL, mids, last→head
          add(srow, scol, #(body[srow + 1] or ""), group)
          for r = srow + 1, erow - 1 do add(r, 0, #(body[r + 1] or ""), group) end
          add(erow, 0, ecol, group)
        end
      end
    end
  end)
  if not ok_iter then return nil end
  return by_line
end

-- Fenced code block → a recessed panel: a dim italic language label on the top
-- fence row, then each body line behind a clay left gutter, every row padded to
-- panel width so the dark background reads as one block. Body text is NOT
-- inline-parsed (code is literal) but IS syntax-highlighted via treesitter when a
-- parser exists — the @capture spans carry fg only, so the block bg shows through.
-- Returns out_lines, out_hls.
local function render_code_block(lang, body)
  local w = math.max(panel_width() - 2, 20)
  local out_lines, out_hls = {}, {}
  local gutter_b = #"▎"                               -- bar glyph byte length
  local syn = code_ts_hls(lang, body)

  -- Top fence row: gutter + language label (or just the gutter when bare).
  local head = pad_display(CODE_GUTTER .. (lang ~= "" and lang or ""), w)
  out_lines[1] = head
  out_hls[1]   = {
    { 0, gutter_b, "ClaudeCodeGutter" },
    { gutter_b, #head, "ClaudeCodeLang" },             -- bg covers the inset pad too
  }

  -- Content width = panel minus the gutter+inset; code lines wider than this are
  -- HARD-WRAPPED into chunks here (rather than relying on Vim's soft wrap) so EACH
  -- screen row carries its own gutter bar + block bg. A soft-wrapped continuation
  -- row would otherwise show bare (no gutter, no bg) past the block edge.
  local gutter_dw = vim.fn.strdisplaywidth(CODE_GUTTER)
  local cw        = math.max(w - gutter_dw, 1)

  for i, bl in ipairs(body) do
    local spans = syn and syn[i] or nil
    local rest, boff = bl, 0                           -- remaining text, byte offset into bl
    repeat
      local chunk = (rest == "") and "" or disp_take(rest, cw)
      local clen  = #chunk
      local row   = pad_display(CODE_GUTTER .. chunk, w)
      local hls   = {
        { 0, gutter_b, "ClaudeCodeGutter" },
        { gutter_b, #row, "ClaudeCodeBlock" },         -- bg + neutral fg base, covers inset pad
      }
      if spans then                                    -- overlay syntax fg spans, clipped to chunk
        for _, s in ipairs(spans) do
          local sb = s[1]
          local se = math.min(s[2], #bl)
          local cs = math.max(sb, boff)                -- intersect [sb,se) with this chunk's byte span
          local ce = math.min(se, boff + clen)
          if ce > cs then
            hls[#hls + 1] = { #CODE_GUTTER + (cs - boff), #CODE_GUTTER + (ce - boff), s[3] }
          end
        end
      end
      out_lines[#out_lines + 1] = row
      out_hls[#out_hls + 1] = hls
      rest = rest:sub(clen + 1)
      boff = boff + clen
    until rest == ""
  end
  return out_lines, out_hls
end

-- True when a fenced block's body is actually a directory tree (≥2 lines carry
-- box-drawing glyphs). Claude almost always wraps trees in a ``` fence, which
-- would otherwise render as flat code; this reroutes them to the tree renderer.
local function body_is_tree(body)
  local n = 0
  for _, l in ipairs(body) do
    if l:find("├", 1, true) or l:find("└", 1, true)
        or l:find("│", 1, true) or l:find("──", 1, true) then
      n = n + 1
      if n >= 2 then return true end
    end
  end
  return false
end

-- Transform raw markdown lines into rendered display lines + per-line highlight
-- ranges. Dispatch order matters: fenced code first (so its contents are never
-- re-parsed), then tables, then the block elements, then trees, then inline
-- prose. Pure (no buffer writes) so it can be unit-tested directly.
-- Returns clean (display lines), per_line_hls (per-line list of {s0,e,group}).
local function build_md_lines(raw)
  local clean, per_line_hls = {}, {}
  local function push(line, hls) clean[#clean + 1] = line; per_line_hls[#clean] = hls end
  local function push_run(lines, hls_list)
    for k, l in ipairs(lines) do push(l, hls_list[k]) end
  end

  local idx = 1
  while idx <= #raw do
    local line = raw[idx]
    if is_fence(line) then
      -- Collect body up to the closing fence (or end of block). The fence rows
      -- themselves are dropped.
      local lang = line:match("^%s*```%s*(%S*)") or ""
      local body, j = {}, idx + 1
      while j <= #raw and not is_fence(raw[j]) do
        body[#body + 1] = raw[j]; j = j + 1
      end
      if body_is_tree(body) then
        -- Fenced directory tree → render each line with glyphs, not as flat code.
        for _, bl in ipairs(body) do push(render_tree_line(bl)) end
      else
        push_run(render_code_block(lang, body))
      end
      idx = (j <= #raw) and j + 1 or j          -- skip the closing fence if present
    elseif is_table_row(line) then
      local j, rows = idx, {}
      while j <= #raw and is_table_row(raw[j]) do rows[#rows + 1] = raw[j]; j = j + 1 end
      push_run(render_table(rows))
      idx = j
    elseif is_heading(line) then
      push(render_heading(line)); idx = idx + 1
    elseif is_hrule(line) then
      push(render_hrule()); idx = idx + 1
    elseif is_quote(line) then
      push(render_quote(line)); idx = idx + 1
    elseif is_list_item(line) then
      push(render_list_item(line)); idx = idx + 1
    elseif is_tree_line(line) then
      push(render_tree_line(line)); idx = idx + 1
    else
      push(parse_inline(line)); idx = idx + 1
    end
  end
  return clean, per_line_hls
end

-- ─── Virtual text hint (bottom of panel) ─────────────────────────────────────

-- Replace the hint at the end of the buffer with new text. The hint is a
-- virtual-text extmark — it appears after the last real line but is not buffer
-- content (cannot be yanked, deleted, or accidentally submitted as input).
--
-- Why extmark virtual text instead of a real line?
--   If we wrote "Reply to Claude…" as a real buffer line and the user pressed
--   <CR>, the input remaps (see set_panel_keymaps) would fire — but the text
--   would also be visible in :Telescope buffers, grep results, etc. Virtual text
--   is display-only.
local function set_hint(text, hl)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, state.hint_ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if last < 0 then last = 0 end
  hl = hl or "ClaudeInput"
  -- eol virtual text does NOT soft-wrap — a long hint just runs off the right
  -- edge. So hard-wrap to the live panel width and spill the overflow into
  -- virt_lines stacked below. Explicit "\n" in `text` forces a break too (the
  -- spinner's "<Esc> to interrupt" footer rides on its own line). When the panel
  -- is the only window it's wide, so the hint stretches across that real estate.
  local w = math.max(panel_width() - 1, 20)
  local segments = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    for _, wl in ipairs(wrap_text(para, w)) do
      segments[#segments + 1] = wl
    end
  end
  if #segments == 0 then return end
  -- First segment sits at the end of the last buffer line; the rest become
  -- virtual lines so the whole hint stacks vertically inside the window.
  local virt_lines
  if #segments > 1 then
    virt_lines = {}
    for i = 2, #segments do
      virt_lines[i - 1] = { { segments[i], hl } }
    end
  end
  vim.api.nvim_buf_set_extmark(buf, state.hint_ns, last, 0, {
    virt_text     = { { segments[1], hl } },
    virt_text_pos = "eol",
    virt_lines    = virt_lines,
  })
end

local function clear_hint()
  local buf = state.panel_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, state.hint_ns, 0, -1)
  end
end

-- ─── Bottom pad (keep output above the chat float) ────────────────────────────
--
-- The reply float overlays the panel's bottom rows. We anchor `rows` blank virtual
-- lines to the buffer's last line; `normal! G` then scrolls them into view at the
-- very bottom (under the float, invisible), lifting the last REAL content line to
-- just above the bar. Re-applied as the float grows; cleared when the bar closes.
-- The over-scroll clamp only limits USER scroll, so this programmatic follow isn't
-- fought.
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

-- Pin the panel's view so the last REAL content line sits exactly `reserve` screen
-- rows above the window bottom — the space the chat bar's pad reserves. With no pad
-- (reserve 0, bar closed) the last line sits flush at the bottom (reflow).
--
-- Method: `G`+`zb` gets close, then a screen-row measurement (free_below) drives a
-- single `<C-e>` correction to hit `reserve` precisely. We do NOT compute a topline:
--   - The old topline walk summed nvim_win_text_height PER LINE, which returns 0 for
--     lines inside a CLOSED FOLD (a collapsed "thinking" dropdown) — so the walk ran
--     far past the intended top and the view jumped 10-20 lines.
--   - `zb` alone is wrap/fold-correct but does not reliably account for the trailing
--     virtual PAD lines (how many land on-screen depends on the last line's wrap
--     height), so it under-lifts by a row or two.
-- Measuring the real rendered gap and nudging with `<C-e>` sidesteps both. It needs
-- 'smoothscroll' (panel-window-local) so `<C-e>` moves ONE screen row, not a whole
-- (possibly multi-row) buffer line; scrolloff is forced to 0 so nothing holds the
-- last line off the bottom. Only ever scrolls UP toward the bar (never <C-y>): a
-- short conversation that can't fill the window just floats above the bar, which is
-- correct — forcing it down would hide the top of the chat.
function anchor_last_line(win, reserve)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  pcall(vim.api.nvim_win_call, win, function()
    if vim.api.nvim_buf_line_count(buf) < 1 then return end
    local so = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    vim.cmd("keepjumps normal! Gzb")
    local fb = free_below(win, buf)
    if fb and fb < reserve then
      vim.cmd("keepjumps normal! " .. (reserve - fb) .. "\005")  -- <C-e> ×(reserve-fb)
    end
    vim.wo[win].scrolloff = so
  end)
end

function set_bottom_pad(rows)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state.pad_ns) then return end
  vim.api.nvim_buf_clear_namespace(buf, state.pad_ns, 0, -1)
  -- Record the pad height BEFORE anchoring so the WinScrolled clamp (which the
  -- topline change triggers) already knows to allow the extra rows.
  state.pad_rows = (rows and rows >= 1) and rows or 0
  if not rows or rows < 1 then return end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if last < 0 then last = 0 end
  -- `rows` blank pad lines below the last real line fill the area the float covers
  -- (plus one visible separator row). They also give the view real content below
  -- the last line so topline can lift it clear of the bar.
  local vlines = {}
  for _ = 1, rows do vlines[#vlines + 1] = { { "", "ClaudeNormal" } } end
  vim.api.nvim_buf_set_extmark(buf, state.pad_ns, last, 0, { virt_lines = vlines })
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)
      and vim.api.nvim_win_get_buf(state.panel_win) == buf then
    anchor_last_line(state.panel_win, rows)
  end
end

local function clear_bottom_pad()
  state.pad_rows = 0
  local buf = state.panel_buf
  if buf and vim.api.nvim_buf_is_valid(buf) and state.pad_ns then
    vim.api.nvim_buf_clear_namespace(buf, state.pad_ns, 0, -1)
    -- Reflow the newest output flush to the window bottom now the bar's gone, so a
    -- close doesn't leave the conversation stranded mid-window with blank space
    -- below (and so the next open recomputes from a clean bottom-anchored view).
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)
        and vim.api.nvim_win_get_buf(state.panel_win) == buf then
      anchor_last_line(state.panel_win, 0)
    end
  end
end

-- Re-pin the last content line to its resting position when a pad is reserved.
-- Toggling a thinking fold inserts/removes display rows ABOVE the last line while
-- the topline holds, so the line slides relative to the window bottom — on EXPAND
-- it drops below its anchor and hides UNDER the question card / chat bar. Re-running
-- set_bottom_pad re-anchors it to `pad_rows` above the bottom. No-op with no pad.
local function reanchor_pad()
  if (state.pad_rows or 0) > 0 then set_bottom_pad(state.pad_rows) end
end

-- Test seams: expose the pad/anchor internals so the headless spec can drive the
-- exact push-up math (winh/line-count/topline) without an interactive float.
mod._anchor_last_line = anchor_last_line
mod._set_bottom_pad   = set_bottom_pad
mod._clear_bottom_pad = clear_bottom_pad
mod._reanchor_pad     = reanchor_pad

-- ─── Queued-message display (type-ahead while Claude works) ───────────────────

-- Render the pending message queue as shaded virtual lines anchored to the
-- buffer's current last line, so they sit at the very bottom under the spinner.
-- Re-anchored on each spinner tick (the last line moves as output streams) and
-- whenever the queue changes. Cleared when the queue empties.
local function render_queue()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state.queue_ns) then return end
  vim.api.nvim_buf_clear_namespace(buf, state.queue_ns, 0, -1)
  if #state.queue == 0 then return end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if last < 0 then last = 0 end
  local vlines = {}
  for _, t in ipairs(state.queue) do
    -- compact single-line preview (queued multi-line messages collapse to line 1)
    local preview = vim.split(t, "\n", { plain = true })[1]
    vlines[#vlines + 1] = { { "❯ " .. preview .. "   (queued)", "ClaudeQueued" } }
  end
  vim.api.nvim_buf_set_extmark(buf, state.queue_ns, last, 0, {
    virt_lines = vlines,
  })
end

-- ─── Working spinner ──────────────────────────────────────────────────────────

-- Braille frames cycled while a turn is in flight. The hint is anchored to the
-- buffer's last line; in send() we append a blank line after the user echo so
-- the spinner first appears on its OWN line beneath the entry, then trails the
-- streaming output as it arrives.
local SPINNER = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local spin_i  = 1

-- Human-readable duration: sub-minute reads "3.2s", longer "1m 04s". Used by the
-- live spinner (turn elapsed), the thinking fold ("Thought · 3.2s"), and the
-- "✻ Churned for …" done line. Defined here (above spinner_label) so the spinner
-- timer can reach it — a later definition resolves to a nil global and errors.
local function fmt_think_dur(ms)
  local s = ms / 1000
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60))
end

-- Flavour words for the generic model-generation phase (the boring "Working…"),
-- mirroring the official TUI's rotating verb. Gerund form for the live spinner;
-- FLAVOR_DONE is the past-tense set for the "✻ Churned for 4m 31s" final line.
-- Index-aligned: the turn picks one index (state.flavor_idx); the live spinner
-- shows FLAVOR[idx] and the done line shows FLAVOR_DONE[idx], so the close is the
-- past tense of the open ("Proofing…" → "✻ Proofed for 4m"). Keep both in sync.
local FLAVOR = {
  "Accomplishing", "Actioning", "Actualizing", "Baking", "Befuddling", "Boggling",
  "Boondoggling", "Booping", "Brewing", "Calculating", "Cerebrating", "Channelling",
  "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Computing",
  "Concocting", "Conjuring", "Considering", "Cooking", "Crafting", "Creating",
  "Crunching", "Deliberating", "Determining", "Discombobulating", "Doing", "Doodling",
  "Effecting", "Elucidating", "Enchanting", "Envisioning", "Finagling", "Forging",
  "Forming", "Frolicking", "Galloping", "Generating", "Germinating", "Hatching",
  "Herding", "Honking", "Hustling", "Hyperspacing", "Ideating", "Imagining",
  "Incubating", "Inferring", "Jazzing", "Jiving", "Levitating", "Manifesting",
  "Marinating", "Meandering", "Moseying", "Mulling", "Musing", "Mustering",
  "Noodling", "Percolating", "Perusing", "Philosophising", "Pondering", "Pontificating",
  "Processing", "Proofing", "Puttering", "Puzzling", "Reticulating", "Riffing",
  "Ruminating", "Scheming", "Schlepping", "Shucking", "Simmering", "Smooshing",
  "Spelunking", "Stewing", "Sussing", "Synthesizing", "Tinkering", "Transmuting",
  "Twiddling", "Vibing", "Whirring", "Wibbling", "Wizarding", "Working", "Wrangling",
}
local FLAVOR_DONE = {
  "Accomplished", "Actioned", "Actualized", "Baked", "Befuddled", "Boggled",
  "Boondoggled", "Booped", "Brewed", "Calculated", "Cerebrated", "Channelled",
  "Churned", "Clauded", "Coalesced", "Cogitated", "Combobulated", "Computed",
  "Concocted", "Conjured", "Considered", "Cooked", "Crafted", "Created",
  "Crunched", "Deliberated", "Determined", "Discombobulated", "Done", "Doodled",
  "Effected", "Elucidated", "Enchanted", "Envisioned", "Finagled", "Forged",
  "Formed", "Frolicked", "Galloped", "Generated", "Germinated", "Hatched",
  "Herded", "Honked", "Hustled", "Hyperspaced", "Ideated", "Imagined",
  "Incubated", "Inferred", "Jazzed", "Jived", "Levitated", "Manifested",
  "Marinated", "Meandered", "Moseyed", "Mulled", "Mused", "Mustered",
  "Noodled", "Percolated", "Perused", "Philosophised", "Pondered", "Pontificated",
  "Processed", "Proofed", "Puttered", "Puzzled", "Reticulated", "Riffed",
  "Ruminated", "Schemed", "Schlepped", "Shucked", "Simmered", "Smooshed",
  "Spelunked", "Stewed", "Sussed", "Synthesized", "Tinkered", "Transmuted",
  "Twiddled", "Vibed", "Whirred", "Wibbled", "Wizarded", "Worked", "Wrangled",
}

-- ─── In-body "typing" placeholder (compute dead-band filler) ──────────────────
--
-- The felt post-request gap is the model's COMPUTE dead bands — message_start →
-- first content block (~4s TTFT) and the gap after a tool_result while it
-- formulates the next message — where NOTHING streams. The bottom spinner hint
-- alone (virt_text) leaves the transcript BODY blank there, which reads as frozen.
-- This paints a single ANIMATED real buffer line IN the transcript flow so the
-- body reads active. It is NOT a client trick to shorten the gap — it just fills
-- the dead air. The styled block REPLACES it: every content-appending dispatch
-- branch calls remove_typing_ph() before rendering, so the placeholder (always the
-- LAST line while present) can never sit above real content. The tick re-adds it
-- during the next dead band (e.g. after a tool result), so post-tool gaps fill too.
local PH_FRAMES = { "●∙∙", "∙●∙", "∙∙●", "∙●∙" }

-- The activity WORD is the current phase: "Thinking" while the model streams a
-- thinking block, otherwise "Typing" (composing/emitting the reply). A tool run
-- shows its own cornered block instead (see in_typing_phase), so the word only
-- ever covers the two block-less compute phases.
local function activity_word()
  if state.think_start then return "Thinking" end
  return "Typing"
end

-- The animated line text: pulsing dot + phase word (no seconds — the eol
-- randomizer below carries the climbing timer, so a second one here is redundant).
-- The dot frame advances on wall-clock time (~350ms) so the pulse is calm and
-- independent of the 110ms braille tick.
local function typing_ph_line()
  local frame = PH_FRAMES[(math.floor(vim.loop.now() / 350) % #PH_FRAMES) + 1]
  return string.format("%s %s", frame, activity_word())
end

-- The activity line shows during the two block-less compute phases (Typing +
-- Thinking) — NOT while a tool runs (its cornered ●/└ block IS the activity),
-- and not while a permission card or a pending diff owns the panel.
local function in_typing_phase()
  return state.working
    and not state.tool_run
    and not state.perm and not state.diff_pending
end

-- Delete the activity block. Safe to call anytime: no-op unless active. It is
-- always added as the LAST TWO lines (word + a trailing blank the eol randomizer
-- anchors to) and nothing appends while active (every appender removes it first),
-- so the last two lines ARE the block.
local function remove_typing_ph()
  if not state.typing_ph then return end
  state.typing_ph = false
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, n - 2, n, false, {})
  vim.bo[buf].modifiable = false
end
mod._remove_typing_ph = remove_typing_ph
mod._activity_word    = activity_word

-- Append the activity block: the word line + a trailing BLANK line. The blank is
-- what set_hint anchors the eol randomizer to, so the randomizer renders on its
-- OWN row directly BELOW the activity word (stacked, no same-row jam). buf_append
-- auto-follows into view; the flag is set AFTER so a later append removes it.
local function add_typing_ph()
  if state.typing_ph then return end
  buf_append({ typing_ph_line(), "" })
  local n = vim.api.nvim_buf_line_count(state.panel_buf)
  hl_lines(n - 2, n - 2, "ClaudeDim")   -- the word line; the blank stays unpainted
  state.typing_ph = true
end

-- Rewrite the word line in place (advance the pulse), leaving the trailing blank.
local function update_typing_ph()
  if not state.typing_ph then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, n - 2, n - 1, false, { typing_ph_line() })
  vim.bo[buf].modifiable = false
  hl_lines(n - 2, n - 2, "ClaudeDim")
end

-- Driven by start_spinner + the 110ms tick: show/animate the placeholder in the
-- typing phase, drop it otherwise. Idempotent — safe to call every tick.
local function tick_typing_ph()
  if in_typing_phase() then
    if state.typing_ph then update_typing_ph() else add_typing_ph() end
  else
    remove_typing_ph()
  end
end

-- The eol randomizer hint: the per-turn flavour word + a climbing turn timer +
-- token count. It rides at EOL on the row BELOW the in-body activity line (the
-- trailing blank add_typing_ph anchors it to), so the two stack:
--   ●∙∙ Typing
--   ⣾ Catapulting… [42s · ↓ 632 tokens]
-- The phase (Typing / Thinking / a tool) shows ONCE — on the activity line or the
-- cornered ●/└ tool block — never duplicated here. The 110ms tick re-renders so
-- the timer climbs in place.
local function spinner_label()
  local frame = SPINNER[spin_i]
  -- turn_t0 is set once at dispatch and never re-baselined, so the timer climbs
  -- continuously across every phase (like the official TUI's "42s") and no gap —
  -- including the post-tool model round-trip — ever looks frozen. The flavour word
  -- stays the PRIMARY verb the whole turn (set once at dispatch).
  local word    = state.flavor_word or "Working"
  local elapsed = state.turn_t0 and fmt_think_dur(vim.loop.now() - state.turn_t0) or "0s"
  local parts   = { elapsed }
  -- The PHASE word (thinking / typing / a tool label) is NO LONGER in the bracket:
  -- the phase now shows exactly once, either as the in-body activity line
  -- (●∙∙ Typing / Thinking) or as the cornered ●/└ tool block. Duplicating it in
  -- the bracket was the redundancy the user asked to cut. The bracket keeps only
  -- the climbing turn timer + the token count when one exists (thinking).
  if type(state.think_tokens) == "number" and state.think_tokens > 0 then
    parts[#parts + 1] = string.format("↓ %d tokens", state.think_tokens)
  end
  -- "\n" puts the interrupt hint on its OWN line (set_hint splits on newlines):
  -- the status word can be long and eol virtual text never soft-wraps, so keeping
  -- "<Esc> to interrupt" inline pushed it off the right edge of a narrow panel.
  return string.format("%s %s… [%s]\n<Esc> to interrupt", frame, word, table.concat(parts, " · "))
end
mod._spinner_label = spinner_label

local function stop_spinner()
  if state.spin_timer then
    vim.fn.timer_stop(state.spin_timer)
    state.spin_timer = nil
  end
  -- Turn end / interrupt / reset all route through here — the compose gap is over,
  -- so drop the in-body placeholder too (it must not outlive the turn).
  remove_typing_ph()
  -- Drop the live phase indicators so a "Thinking…"/"Running…" label can't outlive
  -- the spinner (turn end / interrupt / reset all route through here). Safe because
  -- start_spinner's own stop_spinner call only fires between turns, never mid-phase.
  state.think_start = nil
  state.think_idx   = nil
  state.tool_run    = nil
end

local function start_spinner()
  stop_spinner()
  spin_i = 1
  -- Paint the placeholder BEFORE the hint so set_hint anchors its virt_text to the
  -- placeholder (the new last line), not the line above it.
  tick_typing_ph()
  set_hint(spinner_label(), "ClaudeInput")
  render_queue()
  state.spin_timer = vim.fn.timer_start(110, function()
    if not state.working then stop_spinner(); return end
    if state.perm then remove_typing_ph(); return end  -- a permission card owns the panel; don't clobber
    spin_i = spin_i % #SPINNER + 1
    tick_typing_ph()
    set_hint(spinner_label(), "ClaudeInput")
    -- Re-anchor the queue to the (now lower) last line as output streams in.
    render_queue()
  end, { ["repeat"] = -1 })
end

-- ─── Render functions (Goal 6.3) ──────────────────────────────────────────────

-- Render assistant prose text. Strips trailing blank lines so consecutive
-- text blocks don't double-space; empty blocks (e.g. lone "\n") are silently
-- dropped rather than leaving a gap in the panel.
local function render_prose(text)
  if not text or text == "" then return end
  local raw = vim.split(text, "\n", { plain = true })
  while #raw > 0 and raw[#raw] == "" do
    table.remove(raw)
  end
  if #raw == 0 then return end

  -- Build the cleaned display lines + per-line highlight ranges via the shared
  -- markdown transformer (fenced code, tables, headings, lists, quotes, rules,
  -- trees, inline). Output line count differs from input (block elements expand
  -- or drop rows).
  local clean, per_line_hls = build_md_lines(raw)

  local first = vim.api.nvim_buf_line_count(state.panel_buf)
  buf_append(clean)
  hl_lines(first, first + #clean - 1, "ClaudeProse")

  for li, cl in ipairs(clean) do
    local ln = first + li - 1
    -- Whole-line darker burnt-orange for a line Claude poses as a question, so
    -- prompts to the user pop out of the standard prose orange. Applied before
    -- the inline ranges so bold/code spans inside still override on their bytes.
    if cl:match("%?%s*$") then
      hl_lines(ln, ln, "ClaudeQuestion")
    end
    for _, h in ipairs(per_line_hls[li]) do
      hl_range(ln, h[1], h[2], h[3])
    end
  end

  -- Trailing blank line so the auto-follow cursor (buf_append's `normal! G`)
  -- parks here, not on the final content row. The panel is a non-current window
  -- while Claude streams, and the cursor's line doesn't repaint its decorations
  -- — a code block's last line would show a flat (unpainted) clay gutter bar
  -- until an unrelated redraw. Parking the cursor on a blank keeps styled rows
  -- fully painted.
  buf_append({ "" })
end

-- Echo the user's submitted message into the transcript so the conversation
-- reads as a dialogue (their entry, then Claude's reply). The first line gets
-- the special "❯" prompt arrow (highlighted clay); continuation lines align
-- under it. Mirrors the input bar's arrow so input and echo feel connected.
local USER_ARROW = "❯ "   -- U+276F, deliberately not a keyboard char

-- True when the buffer's last non-blank line is already an all-dash separator.
-- Used to avoid stacking a turn separator directly under the banner's own
-- separator on the first turn (the banner divider already serves as the top).
local function last_line_is_sep()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l ~= "" then
      -- all-dashes test: stripping every "─" leaves nothing (byte-safe).
      return (l:gsub("─", "")) == ""
    end
  end
  return false
end

local function render_user(text)
  if not text or text == "" then return end
  -- Draw the turn separator at the TOP of this turn (above the echo), unless a
  -- separator already sits there (banner divider on the first turn). Responses
  -- no longer end with a trailing divider — the next turn's top one divides them.
  if not last_line_is_sep() then
    local sep_at = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ sep_line() })
    hl_lines(sep_at, sep_at, "ClaudeHeader")
  end
  local raw = vim.split(text, "\n", { plain = true })
  local lines = {}
  for i, l in ipairs(raw) do
    lines[i] = (i == 1 and USER_ARROW or "  ") .. l
  end
  local first = vim.api.nvim_buf_line_count(state.panel_buf)
  buf_append(lines)
  hl_lines(first, first + #lines - 1, "ClaudeUser")
  -- Paint just the arrow glyph terminal-green so it reads like a shell prompt
  -- and matches the input bar's arrow.
  hl_range(first, 0, #USER_ARROW, "ClaudeArrow")
end

-- Foldtext for a collapsed thinking block. The buffer's first fold line is the
-- literal "▼ Thought" header (only shown when expanded); when collapsed Neovim
-- shows THIS instead — a "▶ Thought · <time>" row, so the
-- arrow flips ▼→▶ to signal the closed state. Used for every panel fold, but only
-- thinking blocks create folds. Exposed on mod so the window's foldtext expr
-- (`v:lua.require('utils.claude')._foldtext()`) can reach it.
function mod._foldtext()
  -- A finished thinking block reads "▶ Thought · <time>"; the duration is keyed
  -- by the fold's 1-indexed start line (== vim.v.foldstart). Fall back to the
  -- body line count if no duration was recorded (e.g. a fold from older state).
  local dur = state.folds and state.folds[vim.v.foldstart]
  if dur then
    return "▶ Thought  ·  " .. dur
  end
  local n = vim.v.foldend - vim.v.foldstart           -- body lines (header excluded)
  return "▶ Thought  ·  " .. n .. (n == 1 and " line" or " lines")
end

-- Render a thinking block as a collapsible manual fold (FINDINGS.md Q3),
-- AUTO-COLLAPSED so extended-thinking doesn't bury the reply. Click the header
-- (mouse) or `za` to expand; `zR`/`zM` open/close all.
--
-- Why manual folds, not marker/indent folds?
--   foldmethod=marker would pollute the buffer content with fold markers.
--   foldmethod=indent is fragile (the indented body lines would auto-fold
--   to depth 1, but prose lines wouldn't fold at all). Manual folds let us
--   set exact start/end lines programmatically after each block is appended.
--
-- Why no zR after `:fold`?
--   `:{range}fold` creates the fold ALREADY CLOSED. We deliberately leave it
--   closed (was previously force-opened with zR) so thinking starts collapsed.
local function render_thinking(text)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  -- fold header line. The block only ever arrives COMPLETE (no streaming deltas),
  -- so it's already "Thought", not in-progress "Thinking" — past tense from the
  -- start. Shown only when the fold is expanded; collapsed shows mod._foldtext.
  local header_idx = vim.api.nvim_buf_line_count(buf)  -- 0-indexed insertion point
  buf_append({ "▼ Thought" })
  hl_lines(header_idx, header_idx, "ClaudeLabel")

  -- body: indent two spaces so it reads as a sub-block under the header
  local body_lines = vim.split(text or "", "\n", { plain = true })
  while #body_lines > 0 and body_lines[#body_lines] == "" do
    table.remove(body_lines)
  end
  for i, l in ipairs(body_lines) do
    body_lines[i] = "  " .. l
  end
  local body_start = vim.api.nvim_buf_line_count(buf)
  buf_append(body_lines)
  hl_lines(body_start, body_start + #body_lines - 1, "ClaudeThink")

  -- set the manual fold over header + body; Vim fold ranges are 1-indexed
  local fold_start = header_idx + 1
  local fold_end   = vim.api.nvim_buf_line_count(buf)
  -- Guard on panel_win ALSO showing panel_buf (matches sites at 396/1234/1248):
  -- if a diff transiently swapped the panel window's buffer, folding line
  -- fold_start..fold_end there runs against a shorter buffer → E16: Invalid range.
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)
      and vim.api.nvim_win_get_buf(state.panel_win) == buf then
    vim.api.nvim_win_call(state.panel_win, function()
      vim.cmd(fold_start .. "," .. fold_end .. "fold")  -- creates it CLOSED → auto-collapsed
    end)
  end

  -- Stamp the fold with how long the model thought, so the collapsed foldtext
  -- reads "Thought · 3.2s". Prefer the TRUE streamed duration (content_block
  -- start→stop, captured in state.think_dur); fall back to the activity-gap
  -- heuristic if partial messages didn't fire for this block.
  local dur = state.think_dur
  state.think_dur = nil
  if not dur and state.activity_t0 then
    dur = vim.loop.now() - state.activity_t0
  end
  if dur then
    state.folds[fold_start] = fmt_think_dur(dur)
  end
end

-- ─── Cornered tool block (TUI-faithful ●/└ two-line render) ──────────────────

-- The edit-family tools (their input carries the change to summarise + diff).
local EDIT_NAMES = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

-- Devicon glyph for a path, as "<glyph> " (trailing space) so callers concat it
-- straight before the name. "" when nvim-web-devicons is absent (no nerd font) so
-- the panel still renders without it — and so headless tests see plain text.
local function file_glyph(path)
  if not path or path == "" then return "" end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return "" end
  local icon = devicons.get_icon(
    vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
  return icon and (icon .. " ") or ""
end

-- Added / removed line counts between two blobs by unordered multiset diff (lines
-- in `new` not covered by `old` = added; the reverse = removed). Cheap and good
-- enough for the "Added N, removed M" corner summary; the ordered hunk (context +
-- red/green) is what the vimdiff and the post-approval block render (Goal 14.4).
local function count_added_removed(old, new)
  local pool, oldn, newn, common = {}, 0, 0, 0
  for _, l in ipairs(vim.split(old or "", "\n", { plain = true })) do
    pool[l] = (pool[l] or 0) + 1; oldn = oldn + 1
  end
  for _, l in ipairs(vim.split(new or "", "\n", { plain = true })) do
    newn = newn + 1
    if (pool[l] or 0) > 0 then pool[l] = pool[l] - 1; common = common + 1 end
  end
  return newn - common, oldn - common
end

-- Change counts for an edit-family tool from its input dict. Write/NotebookEdit
-- are whole-content creates/replaces (diff against empty = all added).
local function edit_counts(name, input)
  if name == "Write" then
    return count_added_removed("", input.content or "")
  elseif name == "NotebookEdit" then
    return count_added_removed("", input.new_source or "")
  elseif name == "MultiEdit" then
    local a, r = 0, 0
    for _, e in ipairs(input.edits or {}) do
      local ea, er = count_added_removed(e.old_string or "", e.new_string or "")
      a, r = a + ea, r + er
    end
    return a, r
  end
  return count_added_removed(input.old_string or "", input.new_string or "")  -- Edit
end

-- "Added 5 lines, removed 1 line" — pluralised; both / one-side / none.
local function change_summary(added, removed)
  local function u(n) return n == 1 and "line" or "lines" end
  if added > 0 and removed > 0 then
    return string.format("Added %d %s, removed %d %s", added, u(added), removed, u(removed))
  elseif added > 0 then
    return string.format("Added %d %s", added, u(added))
  elseif removed > 0 then
    return string.format("Removed %d %s", removed, u(removed))
  end
  return "No line changes"
end

-- Collapse to one corner line (kill vertical whitespace, ellipsize wide values).
local function corner_one_line(s)
  s = tostring(s or ""):gsub("[\r\n\t]+", " ")
  if vim.fn.strdisplaywidth(s) > 68 then s = vim.fn.strcharpart(s, 0, 67) .. "…" end
  return s
end

-- Path relative to cwd (~ for home), one line.
local function rel_path(p)
  if not p or p == "" then return "" end
  return corner_one_line(vim.fn.fnamemodify(p, ":~:."))
end

-- Header + corner detail for a tool_use, TUI-faithful gerund style:
--   ● Editing  claude.lua          ● Reading 1 file          ● Running bash
--     └ Added 5 lines, removed 1      └ lua/utils/claude.lua     └ tree -L 1
-- Returns (header, detail); detail nil/"" renders header alone.
local function tool_lines(name, input)
  local path = input.file_path or input.path
  if EDIT_NAMES[name] then
    local a, r = edit_counts(name, input)
    return "● Editing " .. file_glyph(path) .. vim.fn.fnamemodify(path or "", ":t"),
           change_summary(a, r)
  elseif name == "Read" or name == "NotebookRead" then
    return "● Reading 1 file", file_glyph(path) .. rel_path(path)
  elseif name == "Bash" then
    -- .sh devicon after "bash" for the shell glyph the user asked for.
    return "● Running bash " .. file_glyph("run.sh"), corner_one_line(input.command)
  elseif name == "Grep" then
    return "● Searching", corner_one_line(input.pattern)
      .. (input.path and ("  ·  " .. rel_path(input.path)) or "")
  elseif name == "Glob" then
    return "● Listing", corner_one_line(input.pattern)
  end
  local tgt = tool_target(input)
  return "● " .. (TOOL_VERB[name] or name), (tgt ~= "" and tgt or nil)
end

-- Render a tool_use as the cornered two-line ●/└ block. The header verb colour
-- (teal Read / amber Run / purple default) survives from TOOL_HL keyed by the
-- resolved gerund; the corner is dim. A trailing blank follows so the eol
-- randomizer anchors to its OWN row directly below the block (no shared row).
local function render_tool(name, input)
  local header, detail = tool_lines(name, input)
  local first  = vim.api.nvim_buf_line_count(state.panel_buf)
  local lines  = { header }
  if detail and detail ~= "" then lines[#lines + 1] = "  └ " .. detail end
  buf_append(lines)
  hl_lines(first, first, TOOL_HL[TOOL_VERB[name] or name] or "ClaudeTool")
  if #lines > 1 then hl_lines(first + 1, first + 1, "ClaudeDim") end
  buf_append({ "" })   -- randomizer's own row, below the block

  -- Mark a tool RUNNING so the in-body activity line is suppressed during the
  -- tool gap (the cornered block above IS the activity for this phase). The
  -- `user` (tool_result) event clears it.
  state.tool_run = { t0 = vim.loop.now() }
end

-- Render the result event that closes a turn. The result text itself duplicates
-- the assistant prose already rendered (and may carry embedded newlines that
-- nvim_buf_set_lines forbids), so it's NOT rendered. Instead we drop the official
-- TUI's done line: "✻ Churned for 4m 31s" — a past-tense flavour word + total
-- turn time, ClaudeDim so it reads as a footnote. The turn separator is drawn at
-- the TOP of the NEXT turn (by render_user), so the response never ends on a rule.
local function render_result(_text)
  local buf = state.panel_buf
  if not (state.turn_t0 and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  -- Past-tense form of the SAME word the spinner showed this turn (index-aligned
  -- with FLAVOR), so the close echoes the open. Falls back to a random done word
  -- if the turn somehow had no flavour index.
  local word = (state.flavor_idx and FLAVOR_DONE[state.flavor_idx])
    or FLAVOR_DONE[math.random(#FLAVOR_DONE)]
  local line = "  ✻ " .. word .. " for " .. fmt_think_dur(vim.loop.now() - state.turn_t0)
  local l    = vim.api.nvim_buf_line_count(buf)
  buf_append({ line })
  hl_lines(l, l, "ClaudeDim")
end

-- Logo glyphs — must match ingest.py _show_banner (lines 580–582) exactly.
-- Each block element is a 3-byte UTF-8 char; the byte lengths are hardcoded
-- below for the highlight ranges (they never change).
--   G1 " ▐▛███▜▌"  — top of the head   (display width 8, 22 bytes)
--   G2 "▝▜█████▛▘" — belly             (display width 9, 27 bytes)
--   G3 "  ▘▘ ▝▝"   — feet              (display width 7, 15 bytes)
local BANNER_G1 = " ▐▛███▜▌"
local BANNER_G2 = "▝▜█████▛▘"
local BANNER_G3 = "  ▘▘ ▝▝"
-- Per-line right padding so the sidebar text starts at the SAME column on all
-- three lines despite the glyphs having different display widths (8/9/7 → all
-- align to column 11, matching ingest.py's "   "/"  "/"    " spacing).
local BANNER_P1 = "   "   -- 8 + 3 = 11
local BANNER_P2 = "  "    -- 9 + 2 = 11
local BANNER_P3 = "    "  -- 7 + 4 = 11

-- Blank padding line(s) above the glyph so the icon isn't flush against the top
-- window edge. All banner line indices below are expressed relative to this pad.
local BANNER_PAD = 1
local BANNER_L0  = BANNER_PAD        -- "Claude Code v…" / glyph row 1
local BANNER_L1  = BANNER_PAD + 1    -- model           / glyph row 2
local BANNER_L2  = BANNER_PAD + 2    -- cwd             / glyph row 3
local BANNER_SEP = BANNER_PAD + 3    -- separator underline

-- Render the three-line Claude logo banner on cold start.
--
-- Each line has mixed coloring: logo glyph in ClaudeHeader (clay #D97757) and
-- sidebar text in ClaudeProse (orange #F4A261). We apply ClaudeHeader first to
-- the whole line, then override the text byte-range with ClaudeProse (last
-- highlight wins for overlapping ranges at the same priority).
--
-- Sidebar text (matches ingest.py exactly):
--   line 0  "Claude Code v<version>"
--   line 1  "<friendly model>"        — filled by system/init when model known
--   line 2  "<cwd>"                    — the project root the session runs in
local function render_banner(model, version, cwd)
  local ver = (version and version ~= "") and (" v" .. version) or ""

  -- Top pad blank line(s) keep the icon off the window's top edge.
  local lines = {}
  for _ = 1, BANNER_PAD do lines[#lines + 1] = "" end
  lines[#lines + 1] = BANNER_G1 .. BANNER_P1 .. "Claude Code" .. ver
  lines[#lines + 1] = BANNER_G2 .. BANNER_P2 .. friendly_model(model)
  lines[#lines + 1] = BANNER_G3 .. BANNER_P3 .. (cwd or "")
  lines[#lines + 1] = sep_line()
  lines[#lines + 1] = ""   -- breathing room: the cursor rests here, not on the
                           -- separator, so it never blanks the orange divider.

  -- Replace the entire buffer so the banner always starts at line 0.
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Glyph in ClaudeHeader (clay) across the three glyph rows + the separator.
  hl_lines(BANNER_L0, BANNER_SEP, "ClaudeHeader")

  -- Override sidebar text on the three glyph lines, each a distinct colour
  -- (KOS-style): "Claude Code" prose + dim version, model line, path line.
  local t0 = #BANNER_G1 + #BANNER_P1                                -- 25
  hl_range(BANNER_L0, t0,      -1, "ClaudeProse")
  hl_range(BANNER_L0, t0 + 11, -1, "ClaudeDim")                     -- version
  hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1, "ClaudeModel")   -- 29
  hl_range(BANNER_L2, #BANNER_G3 + #BANNER_P3, -1, "ClaudePath")    -- 19
end

-- Rewrite just the banner's cwd line in place. Called on DirChanged so the path
-- always reflects the directory the user is in, without redrawing the whole
-- banner (which would wipe the rendered conversation).
local function update_banner_cwd(cwd)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_buf_line_count(buf) <= BANNER_L2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, BANNER_L2, BANNER_L2 + 1, false,
    { BANNER_G3 .. BANNER_P3 .. (cwd or "") })
  vim.bo[buf].modifiable = false
  hl_range(BANNER_L2, 0,                       #BANNER_G3, "ClaudeHeader")
  hl_range(BANNER_L2, #BANNER_G3 + #BANNER_P3, -1,         "ClaudePath")
end

-- Rewrite just the banner's model line in place (line 1). Called by the model
-- picker so the chosen model shows immediately, without redrawing the banner.
-- `friendly` is the already-friendly display name (or "" to blank the line).
local function update_banner_model(friendly)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_buf_line_count(buf) <= BANNER_L1 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, BANNER_L1, BANNER_L1 + 1, false,
    { BANNER_G2 .. BANNER_P2 .. (friendly or "") })
  vim.bo[buf].modifiable = false
  hl_range(BANNER_L1, 0,                       #BANNER_G2, "ClaudeHeader")
  hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1,         "ClaudeModel")
end

-- Rewrite every separator line (a line made entirely of "─") to the current
-- panel width so the orange dividers shrink/extend with the window instead of
-- wrapping to the next line. Called on resize.
local function refit_separators()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local new   = sep_line()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.bo[buf].modifiable = true
  for i, l in ipairs(lines) do
    -- all-dashes test: stripping every "─" leaves nothing (byte-safe, unlike a
    -- multibyte Lua pattern with "+").
    if l ~= "" and (l:gsub("─", "")) == "" and l ~= new then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new })
      vim.api.nvim_buf_add_highlight(buf, -1, "ClaudeHeader", i - 1, 0, -1)
    end
  end
  vim.bo[buf].modifiable = false
end

-- ─── Stream-json event dispatcher (Goal 6.3) ──────────────────────────────────

-- stdout arrives as arbitrary-sized chunks from Neovim's libuv layer — a single
-- chunk may contain multiple JSON lines, or a line may be split across chunks.
-- We accumulate incomplete data across calls in this module-level string, flush
-- complete lines when a newline arrives, and leave the tail in the buffer.
-- (Mirrors ingest.py's line-by-line iteration over proc.stdout.)
local stdout_buf = ""

-- Reply to a can_use_tool control_request over stdin (the permission gate).
-- `decision` is "allow" or "deny". The SDK contract requires us to echo the
-- request's `input` back as `updatedInput` on allow (the CLI re-validates against
-- it); on an "allow always" we additionally pass `updatedPermissions` (the
-- request's permission_suggestions) so the rule persists to localSettings and the
-- tool won't prompt again. Mirrors mod.interrupt's control_response wire shape.
-- `o.input` is the decoded request.input table; an empty table must encode as a
-- JSON object ({}), not an array ([]) — hence the empty_dict guard.
-- Full wire shapes: .work/FINDINGS.md § Q-PERM. Reused by the step-4 card UI.
local function send_permission_response(request_id, decision, o)
  if not state.job_id then return end
  o = o or {}
  local response
  if decision == "deny" then
    -- The deny reason rides in `message` for BOTH the permission-card "Reject" and
    -- AskUserQuestion's "Chat about this". The TUI bundle's question component sets an
    -- internal `feedback` prop, but the wire serializer maps it straight to `message`
    -- (`{behavior:"deny",message:$.feedback??"User denied permission"}`) — there is NO
    -- `feedback` field on the wire; sending one is silently dropped. § Q-ASK addendum.
    response = { behavior = "deny", message = o.message or "User rejected" }
  else
    local input = o.input
    if type(input) ~= "table" or next(input) == nil then input = vim.empty_dict() end
    response = { behavior = "allow", updatedInput = input }
    if o.permissions then response.updatedPermissions = o.permissions end
  end
  local msg = vim.json.encode({
    type     = "control_response",
    response = { subtype = "success", request_id = request_id, response = response },
  })
  pcall(vim.fn.chansend, state.job_id, msg .. "\n")
end
mod._send_permission_response = send_permission_response

-- Edit-family tools at the can_use_tool gate. GATED ones (Issue-B prototype:
-- Write/Edit) hold the request open and show a PRE-write diff reconstructed from
-- the tool input — accept releases "allow" (the CLI then writes + narrates,
-- post-approval), reject releases "deny" (nothing touches disk). The rest
-- (MultiEdit/NotebookEdit) keep the old contract: auto-allow, then the post-write
-- FileChangedShell+vimdiff flow owns the review.
local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }
local GATED_EDIT_TOOLS = { Edit = true, Write = true }

-- Reconstruct the post-edit file content for an Edit tool input WITHOUT the CLI
-- having written anything: read the (still pristine) file from disk and mirror the
-- CLI's plain-text old_string→new_string replacement, honouring replace_all.
-- Returns a lines list, or nil when reconstruction isn't possible (file missing,
-- old_string absent/empty) — the caller falls back to auto-allow + post-write.
-- Disk, not buffer: the CLI edits the on-disk content, so unsaved buffer edits
-- must not leak into the "proposed" side.
local function reconstruct_edit(path, input)
  local old_s, new_s = input.old_string, input.new_string
  if type(old_s) ~= "string" or old_s == "" or type(new_s) ~= "string" then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local text = table.concat(lines, "\n")
  local out
  if input.replace_all then
    -- split(plain)+concat replaces every occurrence with no pattern-escaping
    -- pitfalls (old_s/new_s are literal strings, not Lua patterns).
    local pieces = vim.split(text, old_s, { plain = true })
    if #pieces < 2 then return nil end -- old_string not found
    out = table.concat(pieces, new_s)
  else
    local s, e = string.find(text, old_s, 1, true)
    if not s then return nil end
    out = text:sub(1, s - 1) .. new_s .. text:sub(e + 1)
  end
  return vim.split(out, "\n", { plain = true })
end
mod._reconstruct_edit = reconstruct_edit

-- Try to hold a gated edit's can_use_tool request behind a pre-write diff.
-- Returns true when the diff is up (request stays open until the user decides);
-- false → caller must auto-allow (old post-write flow) so the CLI never hangs.
local function try_prewrite_gate(request_id, tool, input)
  local path = input.file_path
  if type(path) ~= "string" or path == "" then return false end
  local proposed
  if tool == "Write" then
    proposed = vim.split(input.content or "", "\n", { plain = true })
  else -- Edit
    proposed = reconstruct_edit(path, input)
  end
  if not proposed then return false end
  -- Arm the held request BEFORE opening the diff: the review card can resolve
  -- synchronously in headless tests, and on_prewrite_resolve needs it set.
  state.prewrite = { request_id = request_id, input = input }
  local ok, opened = pcall(require("utils.claude_diff").open_prewrite, path, proposed)
  if not (ok and opened) then
    state.prewrite = nil
    return false
  end
  return true
end

-- Release the held pre-write request: allow (CLI writes the file, then narrates —
-- now post-approval) or deny (CLI never writes; the deny message tells it why).
-- Called by claude_diff.accept_all/reject_all in prewrite mode, which also close
-- the diff windows; the spinner restart mirrors resolve_permission (the turn is
-- still in flight — the CLI was blocked on us).
function mod.on_prewrite_resolve(accepted)
  local p = state.prewrite
  if not p then return end
  state.prewrite = nil
  if accepted then
    send_permission_response(p.request_id, "allow", { input = p.input })
  else
    send_permission_response(p.request_id, "deny",
      { message = "User rejected the proposed change in review" })
  end
  if state.working then
    state.activity_t0 = vim.loop.now()
    start_spinner()
  end
end

-- ─── Permission card (step 4) ─────────────────────────────────────────────────
-- Interactive bordered FLOAT for a non-edit can_use_tool request (Bash, WebFetch,
-- out-of-cwd file access, …) the CLI can't auto-resolve. Opens a rounded box in
-- the panel column titled "⚠ Permission required" (inline on the top border, like
-- the chat bar) but styled distinctly (ClaudePermBorder amber), FOCUSED so the
-- keyboard drives it immediately: ←/→ or h/l move, <CR>/number confirm, <Esc>/q
-- reject. On resolve it replies (send_permission_response), closes the float, and
-- drops a one-line receipt into the transcript so the scrollback records the
-- decision. One card at a time (the CLI blocks the turn awaiting our
-- control_response). Edits never reach here (auto-allowed → vimdiff). Mirrors
-- OpenCode's card; full protocol in .work/FINDINGS.md § Q-PERM.

-- Repaint the float's button row (p.row, 0-indexed last content line) in place:
-- the active option pops (ClaudeQuestion), the rest dim (ClaudeDim). Called on
-- open and on every left/right move.
local function render_perm_choice_row()
  local p = state.perm
  if not (p and p.buf and vim.api.nvim_buf_is_valid(p.buf)) then return end
  state.perm_ns = state.perm_ns or vim.api.nvim_create_namespace("ClaudePermRow")
  local segs, line = {}, "  "
  for i, opt in ipairs(p.options) do
    if i > 1 then line = line .. "    " end
    local label = ((i == p.choice) and "❯ " or "  ") .. opt.label
    local b0 = #line
    line = line .. label
    segs[#segs + 1] = { b0 = b0, b1 = #line, active = (i == p.choice) }
  end
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, p.row, p.row + 1, false, { line })
  vim.bo[p.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(p.buf, state.perm_ns, p.row, p.row + 1)
  for _, s in ipairs(segs) do
    vim.api.nvim_buf_add_highlight(p.buf, state.perm_ns,
      s.active and "ClaudeQuestion" or "ClaudeDim", p.row, s.b0, s.b1)
  end
end

-- Move the selection left/right (wraps).
local function move_perm_choice(delta)
  local p = state.perm
  if not p then return end
  p.choice = (p.choice - 1 + delta) % #p.options + 1
  render_perm_choice_row()
end
mod._move_perm_choice = move_perm_choice

-- Send the chosen decision, close the float, append a transcript receipt, and
-- resume the spinner if the turn is still in flight (an allow lets Claude
-- continue; a deny only denies this tool — the turn may proceed; the eventual
-- `result` event flips working off + clears the hint).
local function resolve_permission(kind)
  local p = state.perm
  if not p then return end
  if kind == "deny" then
    send_permission_response(p.request_id, "deny", { message = "User rejected" })
  elseif kind == "always" then
    send_permission_response(p.request_id, "allow",
      { input = p.input, permissions = p.suggestions })
  else
    send_permission_response(p.request_id, "allow", { input = p.input })
  end

  -- Clear state BEFORE closing so the float's WinClosed guard no-ops (it only
  -- fires a fallback deny when the window vanishes with state.perm still set).
  state.perm = nil
  if p.resize_close then pcall(p.resize_close) end   -- drop the resize-track augroup
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end

  -- One-line receipt in the transcript so the scrollback shows what was decided.
  local mark = (kind == "deny") and "✗" or "✓"
  local verb = ({ once = "Allowed once", always = "Allowed always",
                  deny = "Rejected" })[kind] or "Allowed"
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    local recl = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ mark .. " " .. p.display .. " — " .. verb })
    hl_lines(recl, recl, kind == "deny" and "ClaudeDim" or "ClaudeQuestion")
  end

  -- A blank line below the receipt so the resumed spinner anchors to its OWN line
  -- (set_hint pins EOL virt_text to the last buffer line) instead of trailing the
  -- "✓ Allowed …" receipt text on the same row. Re-baseline the thinking timer so
  -- the user's decision time doesn't count toward the next block's "Thought · …".
  if state.working then
    state.activity_t0 = vim.loop.now()
    buf_append({ "" }); start_spinner()
  else clear_hint() end

  -- Reopen the chat bar we dismissed to show the card, so the user lands back in
  -- the input (draft restored) and can keep the conversation going. Scheduled so
  -- the card's window is fully torn down first. state.perm is already nil here, so
  -- prompt_input() won't bail on the permission guard.
  if state.perm_reopen_bar then
    state.perm_reopen_bar = false
    vim.schedule(function() mod.prompt_input() end)
  end
end
mod._resolve_permission = resolve_permission

-- Find path-like tokens in a PLAIN card line (the desc / Patterns rows are not
-- markdown, so parse_inline never touches them). Any run containing a "/" is a
-- path: trailing-slash → directory (ClaudeDir blue + folder feel), else a file
-- path (ClaudePath green) — matching how the transcript colours paths everywhere
-- else. Returns { {byte0, byte_end, group}, … }.
local function perm_path_ranges(line)
  local out = {}
  for s, tok in line:gmatch("()([~%w%._%-/]*/[~%w%._%-/]*)") do
    local b0 = s - 1
    out[#out + 1] = { b0, b0 + #tok, (tok:sub(-1) == "/") and "ClaudeDir" or "ClaudePath" }
  end
  return out
end

-- The concrete command / parameters the tool will run, so the user can verify
-- EXACTLY what executes before allowing (the display + description summarise intent
-- but hide the real command, e.g. "Display directory tree" never showed the
-- `tree -L 3 …` that runs). Unlike tool_target (truncated to one transcript line),
-- the card wraps + spans rows, so show the full value split on newlines
-- (nvim_buf_set_lines rejects embedded \n). Picks the most meaningful input field.
local function perm_input_lines(input)
  if type(input) ~= "table" then return {} end
  local val = input.command or input.url or input.query or input.pattern
    or input.file_path or input.path
  if not val or val == "" then return {} end
  local out = {}
  for ln in (tostring(val) .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = ln
  end
  return out
end

-- ─── Shared SW-anchored panel-float helpers ──────────────────────────────────
-- The permission card, question card, and chat bar are all bordered floats anchored
-- bottom-left to the Claude panel's column. They must behave IDENTICALLY on three
-- axes, so each routes through these helpers instead of re-deriving the math:
--   (a) glue to the panel's REAL screen column regardless of window layout,
--   (b) never over-scroll their content into empty space, and
--   (c) track the panel's width/column when the terminal or windows resize.

-- Col + inner width for an SW float spanning the panel column. Anchors to the panel
-- window's actual screen position; (columns - panel_w) only lands right when the
-- panel is the RIGHTMOST window — with a split beside it (or the panel on the left)
-- that math drifts the float into the neighbour. Falls back to the subtraction only
-- when the panel window isn't available.
local function panel_float_geom()
  local panel_w   = panel_width()
  local float_col = vim.o.columns - panel_w
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    panel_w   = vim.api.nvim_win_get_width(state.panel_win)
    float_col = vim.api.nvim_win_get_position(state.panel_win)[2]
  end
  return float_col, math.max(panel_w - 2, 1)
end

-- Stop a float from scrolling its content off into blank space. A non-zero global
-- 'scrolloff' leaks into floats: at the last line vim keeps `scrolloff` rows below
-- the cursor, but there are none, so it over-scrolls the tail upward past EOF (the
-- permission card's command-tail over-shoot). Zero it (plus sidescrolloff) per-window
-- so j/k stop with the last line resting at the bottom.
local function harden_float_scroll(win)
  vim.wo[win].scrolloff     = 0
  vim.wo[win].sidescrolloff = 0
end

-- Track the panel column/width on resize for an SW float. The fixed-width panel's
-- left edge shifts as the editor grows, so a float fixed at open-time col/width
-- drifts out of the column and clips. Recomputes col/row/width every resize; the
-- optional on_resize(win, col, width) lets the caller re-fit height / re-render to
-- the new width AFTER the reposition. The augroup self-removes when the window dies
-- (autocmd returns true); also returns a teardown fn for explicit close.
local function attach_panel_float_resize(win, group_name, on_resize)
  vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group_name,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return true end  -- gone → self-remove
      local col, w = panel_float_geom()
      local c = vim.api.nvim_win_get_config(win)
      c.col, c.row, c.width = col, vim.o.lines - 2, w
      pcall(vim.api.nvim_win_set_config, win, c)
      if on_resize then on_resize(win, col, w) end
    end,
  })
  return function() pcall(vim.api.nvim_del_augroup_by_name, group_name) end
end

-- Build + open the focused, bordered permission float and bind its keymaps. The
-- buffer is dedicated and wiped on close, so the keymaps need no teardown.
local function open_permission_float(p)
  -- Body lines (display / desc / command / patterns), a spacer, the button-row
  -- placeholder, and a dim nav-hint line that wraps inside the box.
  local lines, body_hl = {}, {}
  lines[#lines + 1] = "  " .. p.display
  body_hl[#body_hl + 1] = { #lines - 1, "ClaudeProse" }
  if p.desc ~= "" and p.desc ~= p.display then
    lines[#lines + 1] = "  " .. p.desc
    body_hl[#body_hl + 1] = { #lines - 1, "ClaudeProse" }
  end
  -- Button row + nav hint go ABOVE the command, not below it. The float height is
  -- capped (see geometry) so a long command can't fill the screen; keeping the
  -- choices at the top means they stay visible while the command scrolls in the
  -- region beneath them, instead of being pushed off the bottom edge.
  lines[#lines + 1] = ""                                  -- spacer
  lines[#lines + 1] = ""                                  -- button-row placeholder
  p.row = #lines - 1                                      -- 0-indexed button row
  lines[#lines + 1] = "  ←/→ select · ⏎ confirm · esc reject · j/k scroll"
  body_hl[#body_hl + 1] = { #lines - 1, "ClaudeDim" }
  lines[#lines + 1] = ""                                  -- spacer
  -- The actual command/parameters, rendered as a code block (▎ gutter + cyan) so
  -- the user sees what will run, not just a paraphrase of it. Rendered LAST so it
  -- is the scrollable tail of the float.
  for _, cl in ipairs(perm_input_lines(p.input)) do
    lines[#lines + 1] = "  ▎ " .. cl
    body_hl[#body_hl + 1] = { #lines - 1, "ClaudeCode" }
  end
  if p.rules and #p.rules > 0 then
    lines[#lines + 1] = "  Patterns: " .. table.concat(p.rules, ", ")
    body_hl[#body_hl + 1] = { #lines - 1, "ClaudeDim" }
  end

  -- Geometry: full panel-column width minus borders, anchored to the panel's real
  -- screen column (shared helper — same anchoring the question/chat floats use).
  local float_col, float_w = panel_float_geom()

  -- Height must count WRAPPED display rows, not logical lines: with wrap on, a long
  -- description (e.g. a Skill blurb) spans several screen rows. Sum ceil(width/float_w)
  -- per line, then cap at HALF the editor height: a giant command must not swallow
  -- the screen — the chat above stays visible and the command scrolls (j/k) inside
  -- the float. Buttons sit at the top (see line order) so they stay visible while
  -- scrolling, killing the old "I can't see what I'm choosing" bug. Factored into a
  -- closure so the resize handler can re-fit when the panel width changes.
  local function perm_height(w)
    local disp_rows = 0
    for _, l in ipairs(lines) do
      disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / w))
    end
    return math.min(disp_rows, math.max(math.floor(vim.o.lines / 2), 3))
  end
  local float_h = perm_height(float_w)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  p.buf = buf

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = vim.o.lines - 2,
    col       = float_col,
    width     = float_w,
    height    = float_h,
    border    = "rounded",
    style     = "minimal",
    title     = " ⚠ Permission required ",
    title_pos = "left",
    zindex    = 60,
  })
  p.win = win
  -- Amber outline so the card is clearly NOT the clay chat bar; interior shares
  -- ClaudeBarBg so the box reads flush, only the outline pops.
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap        = true
  vim.wo[win].linebreak   = true   -- wrap at word boundaries, not mid-word
  vim.wo[win].breakindent = true   -- align wrapped continuation under the line's indent
  vim.wo[win].cursorline  = false
  harden_float_scroll(win)         -- BUG A: no over-scroll past the command tail
  -- BUG B: track the panel column/width on resize, re-fitting the wrapped height.
  p.resize_close = attach_panel_float_resize(win, "ClaudePermFloat", function(_, _, w)
    pcall(vim.api.nvim_win_set_height, win, perm_height(w))
  end)

  for _, h in ipairs(body_hl) do
    -- Base group over the whole line, then layer path/dir colours on top so the
    -- directories + file paths in the desc/Patterns rows pop (later add_highlight
    -- wins on the overlapping cells).
    vim.api.nvim_buf_add_highlight(buf, -1, h[2], h[1], 0, -1)
    for _, r in ipairs(perm_path_ranges(lines[h[1] + 1] or "")) do
      vim.api.nvim_buf_add_highlight(buf, -1, r[3], h[1], r[1], r[2])
    end
  end
  vim.bo[buf].modifiable = false

  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<Left>",  function() move_perm_choice(-1) end)
  map("h",       function() move_perm_choice(-1) end)
  map("<Right>", function() move_perm_choice(1) end)
  map("l",       function() move_perm_choice(1) end)
  map("<CR>", function()
    local q = state.perm
    if q then resolve_permission(q.options[q.choice].kind) end
  end)
  map("<Esc>", function() resolve_permission("deny") end)
  map("q",     function() resolve_permission("deny") end)
  for i = 1, 3 do
    map(tostring(i), function()
      local q = state.perm
      if q and q.options[i] then q.choice = i; resolve_permission(q.options[i].kind) end
    end)
  end

  -- If the float vanishes by any path OTHER than resolve_permission (which nils
  -- state.perm first), fall back to a reject so the CLI isn't left waiting.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once    = true,
    callback = function()
      if state.perm and state.perm.win == win then resolve_permission("deny") end
    end,
  })
end

-- Render a permission card from an inbound can_use_tool control_request and arm
-- the lock. Pauses the spinner (Claude is genuinely blocked on us, so a spinner
-- would lie); resolve_permission restarts it.
local function show_permission_card(event)
  local req = event.request or {}
  local p = {
    request_id  = event.request_id,
    tool        = req.tool_name or "",
    display     = req.display_name or req.tool_name or "tool",
    desc        = req.description or "",
    input       = req.input,
    suggestions = req.permission_suggestions,
    choice      = 1,
  }
  -- Collect rule strings (suggestions[].rules[].ruleContent) for the Patterns
  -- line and to decide whether "Allow always" is offered — only when the CLI gave
  -- us rules to persist.
  local rules = {}
  for _, sug in ipairs(p.suggestions or {}) do
    for _, r in ipairs(sug.rules or {}) do
      if r.ruleContent then rules[#rules + 1] = r.ruleContent end
    end
  end
  p.rules   = rules
  p.options = { { label = "Allow once", kind = "once" } }
  if #rules > 0 then p.options[#p.options + 1] = { label = "Allow always", kind = "always" } end
  p.options[#p.options + 1] = { label = "Reject", kind = "deny" }

  stop_spinner()
  clear_hint()   -- drop any stale "Working…" hint so nothing peeks behind the float

  -- Dismiss any open chat bar BEFORE opening the card. The bar anchors SW at the
  -- same panel column as the card, so leaving it open overlaps the card and steals
  -- focus/draw order — the card then can't be driven and falls through to a reject.
  -- Closing via the bar's own close() saves the draft; we reopen it on resolve.
  state.perm_reopen_bar = false
  if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
    state.perm_reopen_bar = true
    if state.chat_close then pcall(state.chat_close) end
  end

  state.perm = p
  open_permission_float(p)
  render_perm_choice_row()
end

-- ─── Diff-review card (Goal 14.3) ─────────────────────────────────────────────
-- Reuses the permission card's floating-panel mechanism (SW geometry, scroll
-- hardening, resize tracking, choice-row highlight paint) for the Accept/Reject
-- decision on a proposed file diff, so resolving an edit feels like every other
-- panel decision instead of requiring a jump to the diff window's winbar. The
-- winbar + <leader>ca/cx keymaps (claude_diff.lua) stay wired as a fallback —
-- this card is additive, not a replacement path for either.

local function render_diff_card_choice_row()
  local d = state.diff_card
  if not (d and d.buf and vim.api.nvim_buf_is_valid(d.buf)) then return end
  state.diff_card_ns = state.diff_card_ns or vim.api.nvim_create_namespace("ClaudeDiffCardRow")
  local segs, line = {}, "  "
  for i, opt in ipairs(d.options) do
    if i > 1 then line = line .. "    " end
    local label = ((i == d.choice) and "❯ " or "  ") .. opt.label
    local b0 = #line
    line = line .. label
    segs[#segs + 1] = { b0 = b0, b1 = #line, active = (i == d.choice) }
  end
  vim.bo[d.buf].modifiable = true
  vim.api.nvim_buf_set_lines(d.buf, d.row, d.row + 1, false, { line })
  vim.bo[d.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(d.buf, state.diff_card_ns, d.row, d.row + 1)
  for _, s in ipairs(segs) do
    vim.api.nvim_buf_add_highlight(d.buf, state.diff_card_ns,
      s.active and "ClaudeQuestion" or "ClaudeDim", d.row, s.b0, s.b1)
  end
end

local function move_diff_card_choice(delta)
  local d = state.diff_card
  if not d then return end
  d.choice = (d.choice - 1 + delta) % #d.options + 1
  render_diff_card_choice_row()
end

-- Close the card float WITHOUT touching the diff itself. Used both when a
-- choice resolves it and when the diff resolves some other way (the winbar
-- <leader>ca/cx fallback, or the diff window simply being closed) and the
-- now-stale card needs to go away.
local function close_diff_card()
  local d = state.diff_card
  if not d then return end
  state.diff_card = nil
  if d.resize_close then pcall(d.resize_close) end
  if d.win and vim.api.nvim_win_is_valid(d.win) then
    pcall(vim.api.nvim_win_close, d.win, true)
  end
end
mod._close_diff_card = close_diff_card

-- kind is "accept" | "reject" — routes straight into claude_diff's existing
-- accept_all/reject_all (same functions the winbar keymaps call), so a new-file
-- reject still deletes the file and a write failure still warns + keeps the
-- diff open exactly as it does via the fallback path.
local function resolve_diff_card(kind)
  local d = state.diff_card
  if not d then return end
  close_diff_card()
  local diff = require("utils.claude_diff")
  if kind == "accept" then diff.accept_all() else diff.reject_all() end
end
mod._resolve_diff_card = resolve_diff_card

local function open_diff_card_float(d)
  local lines, body_hl = {}, {}
  lines[#lines + 1] = "  " .. d.display
  body_hl[#body_hl + 1] = { #lines - 1, "ClaudeProse" }
  lines[#lines + 1] = ""                                  -- spacer
  lines[#lines + 1] = ""                                  -- button-row placeholder
  d.row = #lines - 1                                       -- 0-indexed button row
  lines[#lines + 1] = "  ←/→ select · ⏎ confirm · a accept · x reject"
  body_hl[#body_hl + 1] = { #lines - 1, "ClaudeDim" }

  -- Shared geometry/scroll/resize helpers (panel_float_geom, harden_float_scroll,
  -- attach_panel_float_resize) — same ones the permission/question/chat floats use.
  local float_col, float_w = panel_float_geom()
  local function card_height(w)
    local disp_rows = 0
    for _, l in ipairs(lines) do
      disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / w))
    end
    return math.min(disp_rows, math.max(math.floor(vim.o.lines / 2), 3))
  end
  local float_h = card_height(float_w)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  d.buf = buf

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = vim.o.lines - 2,
    col       = float_col,
    width     = float_w,
    height    = float_h,
    border    = "rounded",
    style     = "minimal",
    title     = " ⚠ Review changes ",
    title_pos = "left",
    zindex    = 60,
  })
  d.win = win
  -- Same amber outline as the permission card — both are "your decision needed"
  -- cards; a distinct colour per card type would read as two different systems.
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap        = true
  vim.wo[win].linebreak   = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline  = false
  harden_float_scroll(win)
  d.resize_close = attach_panel_float_resize(win, "ClaudeDiffCardFloat", function(_, _, w)
    pcall(vim.api.nvim_win_set_height, win, card_height(w))
  end)

  for _, h in ipairs(body_hl) do
    vim.api.nvim_buf_add_highlight(buf, -1, h[2], h[1], 0, -1)
  end
  vim.bo[buf].modifiable = false

  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<Left>",  function() move_diff_card_choice(-1) end)
  map("h",       function() move_diff_card_choice(-1) end)
  map("<Right>", function() move_diff_card_choice(1) end)
  map("l",       function() move_diff_card_choice(1) end)
  map("<CR>", function()
    local q = state.diff_card
    if q then resolve_diff_card(q.options[q.choice].kind) end
  end)
  map("a", function() resolve_diff_card("accept") end)
  map("x", function() resolve_diff_card("reject") end)
  -- Unlike the permission card, Esc/q only DISMISS the card — the diff itself is
  -- not blocking a waiting CLI, so there's no reason to force a decision. The
  -- winbar keymaps remain live on the diff window as the fallback.
  map("<Esc>", close_diff_card)
  map("q",     close_diff_card)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once    = true,
    callback = function()
      if state.diff_card and state.diff_card.win == win then
        state.diff_card = nil -- dismissed some other way; not a decision
      end
    end,
  })
end

local function show_diff_card(path, kind)
  local d = {
    display = (kind == "new")
      and ("New file: " .. vim.fn.fnamemodify(path, ":t"))
      or  ("Modified: " .. vim.fn.fnamemodify(path, ":t")),
    choice  = 1,
    options = { { label = "Accept", kind = "accept" }, { label = "Reject", kind = "reject" } },
  }

  -- Dismiss any open chat bar BEFORE opening the card — same SW-column overlap
  -- the permission card guards against (both anchor to the same panel column).
  state.diff_card_reopen_bar = false
  if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
    state.diff_card_reopen_bar = true
    if state.chat_close then pcall(state.chat_close) end
  end

  state.diff_card = d
  open_diff_card_float(d)
  render_diff_card_choice_row()
end
mod._show_diff_card = show_diff_card

-- ─── Question card (AskUserQuestion) ──────────────────────────────────────────
-- Claude's AskUserQuestion tool arrives on the SAME can_use_tool gate as a
-- permission (no new flag — see .work/FINDINGS.md § Q-ASK), but is NOT an
-- allow/reject decision: it carries up to 4 questions, each with its own option
-- list, and the answer rides back in updatedInput.answers (a map keyed by each
-- question's TEXT, value = chosen label, or an array of labels for multiSelect).
--
-- The card is a VERTICAL selector over the N questions in one float. Unlike a
-- step-through wizard it lets you move FREELY between questions (Tab/⇥ + ←/→) WITHOUT
-- answering first — each question keeps its own highlight + recorded pick, and the
-- card only submits (one control_response with the full answers map) once EVERY
-- question has a pick. Per question the option list is the model's options PLUS two
-- synthetic affordances mirroring the Claude Code TUI: "Type something" (free-text
-- answer) and "Chat about this" (bail → dismiss → reopen the chat bar). Keys:
--   ↑/↓ j/k  move highlight within the question
--   ⇥ / →    next question · ⇤ / ← prev question (no answer required)
--   <Space>  toggle a multiSelect option
--   <CR>     select the highlighted option (records pick; advances to the next
--            UNanswered question, or submits when all are answered). On the
--            "Type something" row it opens an input; "Chat about this" denies with
--            feedback so the model opens a clarification dialogue.
--   <Esc>/q  cancel (allow with NO answers → the CLI emits "Question dismissed").
-- Reuses the permission card's geometry + chat-bar dismiss/reopen plumbing.

local Q_CUSTOM = "Type something"
local Q_CHAT   = "Chat about this"

-- The display option list for a question: model options first, then the two
-- synthetic affordances. Each entry: { kind = "model"|"custom"|"chat",
-- index (model options only), label, desc }.
local function question_display_options(question)
  local d = {}
  for i, opt in ipairs(question.options or {}) do
    d[#d + 1] = { kind = "model", index = i, label = opt.label or "", desc = opt.description or "" }
  end
  d[#d + 1] = { kind = "custom", label = Q_CUSTOM, desc = "Write a custom answer" }
  d[#d + 1] = { kind = "chat",   label = Q_CHAT,   desc = "Skip these and discuss in chat" }
  return d
end

-- Highlighted display-option index for the current question (persisted per
-- question so navigating away + back keeps the cursor where you left it).
local function q_choice(q) return q.choice[q.qi] or 1 end

-- Rebuild the card buffer for the current question (q.qi) in place: question text,
-- the vertical option list (❯ marks the highlighted option; single-select shows a
-- ● on the recorded pick, multiSelect a [x]/[ ] checkbox; the recorded custom text
-- shows inline), a dimmed description under each option, and a nav hint. Recomputes
-- the float height (wrapped rows) and repaints highlights. Called on every state
-- change (move/toggle/nav/pick).
local function render_question_card()
  local q = state.qask
  if not (q and q.buf and vim.api.nvim_buf_is_valid(q.buf)
          and q.win and vim.api.nvim_win_is_valid(q.win)) then return end
  local question = q.questions[q.qi] or {}
  local dopts    = question_display_options(question)
  local ci       = q_choice(q)
  local sel      = q.sel[q.qi] or {}
  local pick     = q.picks[q.qi]
  state.qask_ns  = state.qask_ns or vim.api.nvim_create_namespace("ClaudeQaskRow")

  local lines, hl = {}, {}
  lines[#lines + 1] = "  " .. (question.question or "")
  hl[#hl + 1] = { #lines - 1, "ClaudeProse" }
  lines[#lines + 1] = ""                                   -- spacer

  for i, d in ipairs(dopts) do
    local marker = (i == ci) and "❯ " or "  "
    local mark   = "  "
    if d.kind == "model" and question.multiSelect then
      mark = sel[d.index] and "[x] " or "[ ] "
    elseif d.kind == "model" then
      mark = (pick and pick.kind == "option" and pick.index == d.index) and "● " or "  "
    end
    local label = d.label
    if d.kind == "custom" and pick and pick.kind == "custom" then
      label = label .. ": " .. pick.text
    end
    lines[#lines + 1] = "  " .. marker .. mark .. label
    -- Highlighted row pops burnt-orange; model options read prose-orange; the two
    -- synthetic affordances (Type something / Chat about this) get ClaudeLabel
    -- purple so they're visibly distinct from the gray (ClaudeDim) descriptions
    -- they used to share a colour with.
    local grp = (i == ci) and "ClaudeQuestion"
      or ((d.kind == "model") and "ClaudeProse" or "ClaudeLabel")
    hl[#hl + 1] = { #lines - 1, grp }
    if d.desc ~= "" then
      lines[#lines + 1] = "        " .. d.desc
      hl[#hl + 1] = { #lines - 1, "ClaudeDim" }
    end
  end

  lines[#lines + 1] = ""                                   -- spacer
  local nav = (#q.questions > 1) and " · ⇥ question" or ""
  lines[#lines + 1] = question.multiSelect
    and ("  ↑/↓ move · space toggle" .. nav .. " · ⏎ select · esc cancel")
    or  ("  ↑/↓ move" .. nav .. " · ⏎ select · esc cancel")
  hl[#hl + 1] = { #lines - 1, "ClaudeDim" }

  -- Geometry: full panel-column width (shared helper — same anchoring the
  -- permission/chat floats use). Height tracks wrapped rows so a question that
  -- grows/shrinks the option list never clips the hint. col/width are repositioned
  -- by the resize handler; here we only need the width for the wrap math.
  local _, float_w = panel_float_geom()
  local disp_rows = 0
  for _, l in ipairs(lines) do
    disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / float_w))
  end
  local float_h = math.min(disp_rows, math.max(vim.o.lines - 4, 1))

  vim.bo[q.buf].modifiable = true
  vim.api.nvim_buf_set_lines(q.buf, 0, -1, false, lines)
  vim.bo[q.buf].modifiable = false

  -- SW anchor keeps the bottom edge pinned; only the top moves as height changes.
  pcall(vim.api.nvim_win_set_height, q.win, float_h)
  -- Reserve the card's footprint as bottom padding so existing Claude output is
  -- pushed ABOVE the card instead of being covered by it (same contract the chat
  -- float uses). float_h interior + 2 rounded-border rows + 1 blank separator.
  -- Re-set on every render so the pad tracks the card growing/shrinking as the
  -- user steps between questions with different option counts.
  set_bottom_pad(float_h + 3)
  local title = (#q.questions > 1)
    and (" ❓ Question " .. q.qi .. " of " .. #q.questions .. " ")
    or  " ❓ Question "
  pcall(vim.api.nvim_win_set_config, q.win, { title = title, title_pos = "left" })

  vim.api.nvim_buf_clear_namespace(q.buf, state.qask_ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_add_highlight(q.buf, state.qask_ns, h[2], h[1], 0, -1)
  end
end

-- Move the highlighted display option for the current question (wraps).
local function move_question_choice(delta)
  local q = state.qask
  if not q then return end
  local n = #question_display_options(q.questions[q.qi])
  if n == 0 then return end
  q.choice[q.qi] = (q_choice(q) - 1 + delta) % n + 1
  render_question_card()
end
mod._move_question_choice = move_question_choice

-- Jump to the next/prev question WITHOUT requiring an answer (clamped at the ends).
local function goto_question(delta)
  local q = state.qask
  if not q then return end
  local n = #q.questions
  q.qi = math.min(math.max(q.qi + delta, 1), n)
  render_question_card()
end
local function next_question() goto_question(1) end
local function prev_question() goto_question(-1) end
mod._next_question = next_question
mod._prev_question = prev_question

-- Toggle the highlighted MODEL option in a multiSelect question's selection set.
-- (No-op on the synthetic Type/Chat rows, or on single-select questions.)
local function toggle_question_choice()
  local q = state.qask
  if not (q and q.questions[q.qi].multiSelect) then return end
  local d = question_display_options(q.questions[q.qi])[q_choice(q)]
  if not (d and d.kind == "model") then return end
  q.sel[q.qi] = q.sel[q.qi] or {}
  q.sel[q.qi][d.index] = not q.sel[q.qi][d.index] or nil
  render_question_card()
end
mod._toggle_question_choice = toggle_question_choice

-- Tear the card down (the answer/cancel response is sent by the caller first),
-- drop a one-line transcript receipt, resume the spinner if the turn is still in
-- flight, and reopen any chat bar we dismissed to show the card.
local function close_question_card(receipt, receipt_hl)
  local q = state.qask
  if not q then return end
  state.qask = nil                                   -- before close → WinClosed no-ops
  if q.resize_close then pcall(q.resize_close) end   -- drop the resize-track augroup
  if q.win and vim.api.nvim_win_is_valid(q.win) then
    pcall(vim.api.nvim_win_close, q.win, true)
  end
  -- Drop the footprint pad the card reserved. If a dismissed chat bar is about to
  -- reopen (qask_reopen_bar) it re-sets its own pad on open, so this clear is safe.
  clear_bottom_pad()
  if receipt and state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    local recl = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ receipt })
    hl_lines(recl, recl, receipt_hl or "ClaudeQuestion")
  end
  -- Blank line so the resumed spinner gets its own row, not the receipt's EOL
  -- (same reason as resolve_permission — set_hint anchors to the last line).
  -- Re-baseline the thinking timer past the user's answer time.
  if state.working then
    state.activity_t0 = vim.loop.now()
    buf_append({ "" }); start_spinner()
  else clear_hint() end
  if state.qask_reopen_bar then
    state.qask_reopen_bar = false
    vim.schedule(function() mod.prompt_input() end)
  end
end

-- A question counts as answered once it has a recorded pick (single-select option
-- or custom text), or — for multiSelect — once the user has confirmed it with <CR>
-- (picks[i] = { kind = "multi" }; the actual labels live in sel[i]).
local function question_answered(q, i)
  return q.picks[i] ~= nil
end

-- Build the answers map from every question's recorded pick and submit ONE
-- control_response: allow with updatedInput.answers (the § Q-ASK wire shape; reuses
-- send_permission_response's allow path, which sends updatedInput verbatim).
local function submit_question_answers()
  local q = state.qask
  if not q then return end
  local answers = {}
  for i, question in ipairs(q.questions) do
    local key = question.question
    if question.multiSelect then
      local labels, sel = {}, q.sel[i] or {}
      for oi, opt in ipairs(question.options or {}) do
        if sel[oi] then labels[#labels + 1] = opt.label end
      end
      answers[key] = labels
    else
      local p = q.picks[i]
      if p and p.kind == "custom" then
        answers[key] = p.text
      elseif p and p.kind == "option" then
        answers[key] = p.label
      end
    end
  end
  local merged = vim.deepcopy(q.input or {})
  merged.answers = answers
  send_permission_response(q.request_id, "allow", { input = merged })
  local n = #q.questions
  close_question_card(
    "✓ Answered " .. n .. (n == 1 and " question" or " questions"), "ClaudeQuestion")
end

-- After recording a pick: submit if EVERY question is now answered, else advance to
-- the next still-unanswered question (wrapping from the current one) so the user is
-- always moved toward completion.
local function advance_or_submit()
  local q = state.qask
  if not q then return end
  local n = #q.questions
  for i = 1, n do
    if not question_answered(q, i) then
      -- Walk forward from the current question to the next unanswered one.
      for step = 1, n do
        local cand = (q.qi - 1 + step) % n + 1
        if not question_answered(q, cand) then
          q.qi = cand
          render_question_card()
          return
        end
      end
    end
  end
  submit_question_answers()
end

-- Cancel the whole card: allow WITH NO answers (the clean dismiss — the CLI emits
-- a "Question dismissed, no answer" tool_result and the model continues/re-asks).
local function cancel_question()
  local q = state.qask
  if not q then return end
  send_permission_response(q.request_id, "allow", { input = q.input })
  close_question_card("✗ Questions dismissed", "ClaudeDim")
end
mod._cancel_question = cancel_question

-- Per-question "Questions asked:" summary that rides in the "Chat about this"
-- feedback (the bundle's t_m): each question text on its own line, followed by the
-- recorded answer (joined labels for multiSelect, the picked/custom value otherwise)
-- or "(No answer provided)" when the user hit Chat before answering it.
local function question_summary(q)
  local parts = {}
  for i, question in ipairs(q.questions) do
    parts[#parts + 1] = '- "' .. (question.question or "") .. '"'
    local ans
    if question.multiSelect then
      local labels, sel = {}, q.sel[i] or {}
      for oi, opt in ipairs(question.options or {}) do
        if sel[oi] then labels[#labels + 1] = opt.label end
      end
      if #labels > 0 then ans = table.concat(labels, ", ") end
    else
      local p = q.picks[i]
      if p and p.kind == "custom" then ans = p.text
      elseif p and p.kind == "option" then ans = p.label end
    end
    parts[#parts + 1] = ans and ("  Answer: " .. ans) or "  (No answer provided)"
  end
  return table.concat(parts, "\n")
end

-- "Chat about this": NOT a dismiss. The TUI sends a `behavior:"deny"` whose `message`
-- carries the canned clarify text (verbatim from the bundle's e_m `feedback`, which
-- serializes to `message` on the wire) + the question summary, so the model opens a
-- clarification dialogue instead of silently moving on. Reusing cancel_question's
-- allow-no-answers (the first bug) was a dismiss; sending it as `feedback` (the second
-- bug) was dropped → bare deny → model saw "permission denied". § Q-ASK addendum.
local function respond_to_claude_question()
  local q = state.qask
  if not q then return end
  local message = "The user wants to clarify these questions. This means they may "
    .. "have additional information, context or questions for you. Take their "
    .. "response into account and then reformulate the questions if appropriate. "
    .. "Start by asking them what they would like to clarify. Questions asked: "
    .. question_summary(q)
  send_permission_response(q.request_id, "deny", { message = message })
  -- close_question_card reopens the dismissed chat bar (draft restored) so the user
  -- can immediately type their clarification once the model asks.
  close_question_card("💬 Chat about this", "ClaudeQuestion")
end
mod._respond_to_claude_question = respond_to_claude_question

-- Record a free-text custom answer for the current question, then advance/submit.
-- nil text = the input was cancelled → leave the card untouched.
local function set_question_custom(text)
  local q = state.qask
  if not q or text == nil then return end
  q.picks[q.qi] = { kind = "custom", text = text }
  advance_or_submit()
end
mod._set_question_custom = set_question_custom

-- Open a small input for the "Type something" affordance. A dedicated, FOCUSED
-- float in the panel column (NOT vim.ui.input): dressing routes vim.ui.input to a
-- cursor-relative float that opened behind the question card (the card holds focus
-- + a higher draw position), so the user's typing landed in an invisible window.
-- This float anchors SW at the panel column with a zindex ABOVE the card (70 > 60),
-- focused + in insert mode, so what's typed is always visible. <CR> commits the
-- answer, <Esc> cancels back to the card. Empty/cancelled input just repaints.
local function prompt_question_custom()
  if not state.qask then return end
  local panel_w = panel_width()
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    panel_w = vim.api.nvim_win_get_width(state.panel_win)
  end
  local float_w   = math.max(panel_w - 2, 1)
  local float_col = vim.o.columns - panel_w

  -- A prompt buffer (not a plain scratch) so it carries the same green "❯" arrow as
  -- the chat bar: prompt_setprompt draws the arrow, matchadd colours it terminal-
  -- green (ClaudeArrow), and <CR> fires prompt_setcallback with the typed text.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].buftype   = "prompt"

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = vim.o.lines - 2,
    col       = float_col,
    width     = float_w,
    height    = 1,
    border    = "rounded",
    style     = "minimal",
    title     = " ✎ Type your answer ",
    title_pos = "left",
    zindex    = 70,
  })
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudeBarBorder,FloatTitle:ClaudeBarBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap = false

  -- Green "❯ " prompt arrow, matching the chat bar (window-local match, set while
  -- this float is the current window).
  vim.fn.prompt_setprompt(buf, "❯ ")
  vim.fn.matchadd("ClaudeArrow", "^❯")
  -- Show the cursor while typing (the panel hides it globally via guicursor).
  vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

  -- Close the input, then either record the typed text (commit + advance/submit)
  -- or fall back to the card untouched. Refocus the card so navigation continues.
  -- Guarded so the prompt callback + an <Esc>/WinLeave can't both fire it.
  local done = false
  local function finish(text)
    if done then return end
    done = true
    vim.o.guicursor = "a:ver1-ClaudeCursorHidden"    -- re-hide; focus returns to panel
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if not state.qask then return end                -- card gone while typing
    if state.qask.win and vim.api.nvim_win_is_valid(state.qask.win) then
      pcall(vim.api.nvim_set_current_win, state.qask.win)
    end
    -- Closing the prompt float leaves the editor in insert mode; the card's
    -- keymaps are normal-mode, so without this the arrows are dead until the user
    -- drops out of insert manually.
    vim.cmd("stopinsert")
    if text and text ~= "" then set_question_custom(text)
    else render_question_card() end
  end

  vim.fn.prompt_setcallback(buf, function(text) finish(text) end)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("i", "<Esc>", function() finish(nil) end, opts)
  vim.keymap.set("n", "<Esc>", function() finish(nil) end, opts)
  vim.cmd("startinsert!")
end

-- Act on the highlighted option: "Chat about this" denies with feedback (clarify
-- dialogue), "Type something" opens the input, a model option records the pick
-- (single-select) or confirms the multiSelect set, then advances / submits.
local function select_question_choice()
  local q = state.qask
  if not q then return end
  local question = q.questions[q.qi]
  local d = question_display_options(question)[q_choice(q)]
  if not d then return end
  if d.kind == "chat" then
    respond_to_claude_question()
    return
  elseif d.kind == "custom" then
    prompt_question_custom()
    return
  end
  -- model option
  if question.multiSelect then
    q.picks[q.qi] = { kind = "multi" }               -- confirmed; labels live in sel
  else
    q.picks[q.qi] = { kind = "option", index = d.index, label = d.label }
  end
  advance_or_submit()
end
mod._select_question_choice = select_question_choice

-- Build + open the focused, bordered question float (clay border, like the chat
-- bar, since this is a normal interaction, not a warning) and bind its keymaps.
-- render_question_card fills the body + sizes the height for the first question.
local function open_question_float(q)
  -- Shared geometry: anchors to the panel's real screen column (fixes the drift the
  -- permission float already fixed — this path was still using columns-panel_w).
  local float_col, float_w = panel_float_geom()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  q.buf = buf

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = vim.o.lines - 2,
    col       = float_col,
    width     = float_w,
    height    = 1,                                   -- render_question_card resizes
    border    = "rounded",
    style     = "minimal",
    title     = " ❓ Question ",
    title_pos = "left",
    zindex    = 60,
  })
  q.win = win
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudeBarBorder,FloatTitle:ClaudeBarBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap        = true
  vim.wo[win].linebreak   = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline  = false
  harden_float_scroll(win)         -- BUG A: no over-scroll past the option list
  -- BUG B: track the panel column/width on resize; re-render to re-fit height+pad.
  q.resize_close = attach_panel_float_resize(win, "ClaudeQaskFloat", function()
    render_question_card()
  end)

  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<Up>",      function() move_question_choice(-1) end)
  map("k",         function() move_question_choice(-1) end)
  map("<Down>",    function() move_question_choice(1) end)
  map("j",         function() move_question_choice(1) end)
  map("<Tab>",     next_question)
  map("<Right>",   next_question)
  map("<S-Tab>",   prev_question)
  map("<Left>",    prev_question)
  map("<Space>",   toggle_question_choice)
  map("<CR>",      select_question_choice)
  map("<Esc>",     cancel_question)
  map("q",         cancel_question)

  -- Float vanished by some path OTHER than our teardown (which nils state.qask
  -- first) → cancel so the CLI isn't left blocked on the turn.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once    = true,
    callback = function()
      if state.qask and state.qask.win == win then cancel_question() end
    end,
  })
end

-- Arm a question card from an inbound AskUserQuestion can_use_tool control_request.
-- Pauses the spinner (Claude is blocked on us) and dismisses any open chat bar
-- (same SW-column collision as the permission card), reopened on close.
local function show_question_card(event)
  local req = event.request or {}
  local input = req.input or {}
  local q = {
    request_id = event.request_id,
    input      = input,
    questions  = input.questions or {},
    qi         = 1,
    choice     = {},     -- choice[i] = highlighted display-option index per question
    sel        = {},     -- sel[i]    = { [modelOptIndex] = true } per multiSelect question
    picks      = {},     -- picks[i]  = recorded answer per question (see question_answered)
  }
  if #q.questions == 0 then
    -- Nothing to ask — allow with no answers so the turn isn't left blocked.
    send_permission_response(event.request_id, "allow", { input = input })
    return
  end

  stop_spinner()
  clear_hint()

  state.qask_reopen_bar = false
  if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
    state.qask_reopen_bar = true
    if state.chat_close then pcall(state.chat_close) end
  end

  state.qask = q
  open_question_float(q)
  render_question_card()
end
mod._show_question_card = show_question_card

-- Dispatch one fully parsed stream-json event object.
local function dispatch(event)
  local ev_type = event.type or ""

  if ev_type == "system" and event.subtype == "init" then
    -- Fill the banner's version (line 0) and model (line 1) now that they're
    -- known. The banner was pre-rendered at panel open with the cwd but no model
    -- or version (those only arrive in system/init). The process is persistent
    -- (one long-lived `claude` per session), so system/init fires once at spawn;
    -- we patch the lines in-place so a second banner is never appended.
    -- The init event carries the CLI version under `claude_code_version`
    -- (NOT `version`); fall back to `version` only for forward-compatibility.
    local model    = friendly_model(event.model or "")
    if model ~= "" then state.model_display = model end  -- modal statusline model
    local raw_ver  = event.claude_code_version or event.version or ""
    local ver      = (raw_ver ~= "") and (" v" .. raw_ver) or ""
    local buf   = state.panel_buf
    if buf and vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_line_count(buf) > BANNER_L1 then
      vim.bo[buf].modifiable = true
      if ver ~= "" then
        vim.api.nvim_buf_set_lines(buf, BANNER_L0, BANNER_L0 + 1, false,
          { BANNER_G1 .. BANNER_P1 .. "Claude Code" .. ver })
      end
      if model ~= "" then
        vim.api.nvim_buf_set_lines(buf, BANNER_L1, BANNER_L1 + 1, false,
          { BANNER_G2 .. BANNER_P2 .. model })
      end
      vim.bo[buf].modifiable = false
      if ver ~= "" then
        local t0 = #BANNER_G1 + #BANNER_P1
        hl_range(BANNER_L0, 0,       #BANNER_G1, "ClaudeHeader")
        hl_range(BANNER_L0, t0,      -1,         "ClaudeProse")
        hl_range(BANNER_L0, t0 + 11, -1,         "ClaudeDim")
      end
      if model ~= "" then
        hl_range(BANNER_L1, 0,                       #BANNER_G2, "ClaudeHeader")
        hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1,         "ClaudeModel")
      end
    end
    state.system_ready = true
    -- working hint already set by send(); don't clobber it

  elseif ev_type == "system" and event.subtype == "thinking_tokens" then
    -- Live estimated-token count while the model thinks; the spinner appends it to
    -- the "Thinking… Xs" label (e.g. "· 111 tok"). Type-guarded like session_cost.
    if type(event.estimated_tokens) == "number" then
      state.think_tokens = event.estimated_tokens
    end

  elseif ev_type == "stream_event" then
    -- Incremental SSE (from --include-partial-messages). We drive only the
    -- thinking block's lifecycle (live "Thinking… Xs" counter + true start→stop
    -- duration). Text/tool deltas are NOT rendered here — painting raw text
    -- token-by-token felt "off", so the styled prose still lands once from the
    -- aggregated `assistant` event below. The compose-gap feel is handled by the
    -- spinner's default "typing" phase (see spinner_label), not by these deltas.
    local se = event.event or {}
    local st = se.type or ""
    if st == "content_block_start" and (se.content_block or {}).type == "thinking" then
      state.think_start  = vim.loop.now()
      state.think_idx    = se.index          -- which block index is the thinking one
      state.think_tokens = 0                 -- reset the per-block live token count
    elseif st == "content_block_stop" and state.think_start
        and se.index == state.think_idx then
      -- Thinking finished: freeze the duration for render_thinking to stamp on the
      -- fold, and drop think_start so the spinner reverts to "Working…".
      state.think_dur   = vim.loop.now() - state.think_start
      state.think_start = nil
      state.think_idx   = nil
    end

  elseif ev_type == "user" then
    -- A user event arriving FROM the CLI carries tool_result content: the most
    -- recent tool finished (execution + Pre/PostToolUse hooks done). Clear the
    -- "Running…" indicator so the spinner reverts to "Working…" for the model
    -- round-trip that follows. (Our own outgoing turns are written to stdin, never
    -- echoed back through dispatch, so a user event here is always a tool_result.)
    state.tool_run = nil
    -- MG 14.2 RC1: a tool_result means the CLI finished executing — including any
    -- Edit/Write that just hit disk. The FileChangedShell interceptor only detects
    -- that write when something polls checktime, but its poll autocmds
    -- (TermLeave/WinEnter/CursorHold) never fire while the user sits in the Claude
    -- terminal panel. Poll here, right after execution, so an edit to an
    -- unopened/already-open file raises its diff without a manual window switch.
    -- Scheduled: checktime + its FileChangedShell must run outside this stdout
    -- dispatch (window ops forbidden inside FileChangedShell; see claude_diff.lua).
    -- poll() = checktime_all (writes to loaded buffers) + sweep_new (files Claude
    -- just CREATED, which have no buffer for checktime to see).
    vim.schedule(function()
      require("utils.claude_diff").poll()
    end)

  elseif ev_type == "assistant" then
    -- assistant events carry a message with a content array. Each block is one
    -- of: text (prose), thinking (extended thinking), or tool_use.
    -- The styled block REPLACES the in-body typing placeholder: drop it before any
    -- render so content never lands below the placeholder line.
    remove_typing_ph()
    local content = (event.message or {}).content or {}
    for _, block in ipairs(content) do
      local btype = block.type or ""
      if btype == "text" then
        render_prose(block.text or "")
      elseif btype == "thinking" then
        render_thinking(block.thinking or "")
      elseif btype == "tool_use" then
        local name  = block.name or ""
        local input = block.input or {}
        render_tool(name, input)
        -- MG 14.2: pre-load the edit target so the FileChangedShell interceptor
        -- catches the CLI's write (covers new + unloaded files). tool_use always
        -- precedes execution in the stream, so the buffer loads with pre-edit
        -- content. NotebookEdit carries notebook_path, the rest file_path.
        -- GATED tools are reviewed pre-write at can_use_tool instead — watching
        -- them here would queue a post-write diff of the already-approved edit
        -- (and put a new file in pending_new for sweep_new to double-gate).
        if EDIT_NAMES[name] and not GATED_EDIT_TOOLS[name] then
          require("utils.claude_diff").watch(input.file_path or input.notebook_path)
        end
      end
      -- tool_result body rendering is deferred to v2 (TODOS.md backlog)

      -- Re-baseline after every block so a thinking block that follows other
      -- content times only the gap since the prior block, not the whole turn.
      state.activity_t0 = vim.loop.now()
    end

  elseif ev_type == "result" then
    -- result closes the current turn. After this, claude is waiting for more
    -- input — unlock the input bar (unless a diff review is still pending).
    -- Drop the placeholder before render_result appends the churn line (it runs
    -- before stop_spinner below, so the placeholder would otherwise sit above it).
    remove_typing_ph()
    local result_text = event.result or ""
    render_result(result_text)
    -- total_cost_usd is the session's cumulative cost so far; store it for the
    -- statusline. type-guard for the same reason the burn reader does (a missing
    -- field would be nil; never compare/format a non-number).
    if type(event.total_cost_usd) == "number" then
      state.session_cost = event.total_cost_usd
    end
    state.working = false
    stop_spinner()
    if state.diff_pending then
      -- Hold queued messages until the edit is reviewed (on_diff_close drains).
      set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
    else
      clear_hint()
      -- Turn finished: send the next type-ahead message if one is queued.
      mod._maybe_send_next()
    end

  elseif ev_type == "control_request" and (event.request or {}).subtype == "can_use_tool" then
    -- The CLI is asking permission for a tool that isn't allowlisted (enabled by
    -- the --permission-prompt-tool stdio flag). tool_name/input/permission_
    -- suggestions live under `request`; the request_id we must echo is top-level.
    -- The card / question selector renders in-body; drop the placeholder first so
    -- it doesn't land above the card (the tick's perm-guard keeps it gone after).
    remove_typing_ph()
    local req  = event.request or {}
    local tool = req.tool_name or ""
    if EDIT_TOOLS[tool] then
      local input = req.input or {}
      local gated = GATED_EDIT_TOOLS[tool]
        and try_prewrite_gate(event.request_id, tool, input)
      if not gated then
        -- Post-write flow (MultiEdit/NotebookEdit, or a gated edit the pre-write
        -- diff couldn't reconstruct/show): pre-load the target so the
        -- FileChangedShell interceptor catches the write, then auto-allow — the
        -- vimdiff review happens AFTER the CLI writes. (Gated tools skip watch()
        -- at tool_use time, so the fallback must watch here; for the others this
        -- is a harmless re-watch of the same path.)
        require("utils.claude_diff").watch(input.file_path or input.notebook_path)
        send_permission_response(event.request_id, "allow", { input = req.input })
      end
    elseif tool == "AskUserQuestion" then
      -- Structured multiple-choice questions ride the same gate but are NOT an
      -- allow/reject decision — render the vertical question selector instead of
      -- the permission card (.work/FINDINGS.md § Q-ASK). MUST come before the
      -- generic non-edit branch, which would mis-route it to show_permission_card.
      show_question_card(event)
    else
      -- Non-edit tool: render the interactive permission card and wait for the
      -- user's Allow once / Allow always / Reject choice (resolve_permission
      -- sends the control_response). The CLI blocks the turn until we answer.
      show_permission_card(event)
    end
  end
end

-- Neovim's on_stdout callback. CRITICAL: jobstart splits stdout on "\n" and
-- STRIPS the newlines before calling us — `data` is a list of line fragments,
-- NOT raw bytes. The convention (see :h channel-lines):
--   * data[1] continues the partial line left over from the previous call,
--   * data[#data] is this call's new partial line (often "" when the stream
--     ended exactly on a newline).
-- So we prepend the saved tail to data[1], pop the last element as the new
-- tail, and every remaining element is a complete line. (Concatenating the
-- fragments and re-splitting on "\n" would be wrong: there are no "\n" left,
-- so all events collapse into one invalid-JSON blob and nothing renders.)
local function on_stdout(_, data, _)
  if not data then return end
  data[1]    = stdout_buf .. data[1]
  stdout_buf = table.remove(data)  -- new partial tail for the next call

  for _, line in ipairs(data) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      -- pcall: ANSI noise lines that slip through (e.g. cursor movement codes)
      -- are not valid JSON; silently skip rather than surfacing an error.
      local ok, event = pcall(vim.json.decode, trimmed)
      if ok and type(event) == "table" then
        -- vim.schedule: dispatch modifies the buffer (appends lines, sets
        -- highlights, creates folds). These operations are forbidden inside an
        -- on_stdout callback because libuv callbacks run on the event loop,
        -- not inside the Neovim API safe zone. vim.schedule defers to the next
        -- safe iteration of the event loop.
        vim.schedule(function()
          dispatch(event)
        end)
      end
    end
  end
end

-- on_exit fires when the persistent process ends — process crash, model/plan
-- respawn (jobstop), reset(), or panel close. Unlike the old per-message arch,
-- a clean exit here is NOT a turn boundary (turns end on the `result` event);
-- it means the whole session is gone. We clear job_id so the next send respawns
-- a fresh process (conversation context is lost — note the warning on crashes).
--   code 0 / 143 (SIGTERM) / -1 = intentional stop or graceful end → quiet
--   anything else               = crash → notify (panel stays; next send respawns)
local function on_exit(_, code, _)
  state.job_id       = nil
  state.working      = false
  state.system_ready = false
  stdout_buf         = ""
  stop_spinner()

  vim.schedule(function()
    local clean = (code == 0 or code == 143 or code == -1)
    if not clean then
      vim.notify(
        "Claude session exited (code " .. code .. ") — next message starts a fresh session",
        vim.log.levels.WARN
      )
    end
    -- Either way the panel stays open. Restore the reply hint unless a diff is
    -- still pending review.
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      if state.diff_pending then
        set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
      else
        clear_hint()
      end
    end
  end)
end

-- ─── Panel buffer setup ───────────────────────────────────────────────────────

-- Create (or reuse) the panel scratch buffer. Called by toggle() before opening
-- the panel window. Idempotent: if the buffer already exists and is valid,
-- returns it immediately so the scrollback survives panel close/reopen within
-- the same session. reset() deletes the buffer explicitly to start blank.
local function ensure_panel_buf()
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    return state.panel_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)   -- unlisted, scratch
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "hide"   -- don't wipe on window close; keep scrollback
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false    -- prevent accidental edits; toggled by buf_append
  -- filetype "claude" is the hook the modal statusline keys off (lua/plugins/ui.lua
  -- in_claude): when this buffer is focused, lualine shows CLAUDE / CODE instead of
  -- the plain Neovim mode. The reply float buffer gets the same filetype so the
  -- modal indicator persists while typing.
  vim.bo[buf].filetype   = "claude"
  -- foldmethod is window-local, not buffer-local; set it in open_panel_window.
  -- Name the buffer "claude" so bufferline and lualine show something readable
  -- instead of "[No Name]". pcall guards the rare E95 name-collision.
  pcall(vim.api.nvim_buf_set_name, buf, "claude")

  state.panel_buf = buf
  state.hint_ns   = vim.api.nvim_create_namespace("claude_hint")
  state.queue_ns  = vim.api.nvim_create_namespace("claude_queue")
  state.pad_ns    = vim.api.nvim_create_namespace("claude_pad")
  state.folds     = {}
  stdout_buf      = ""
  return buf
end

-- ─── Panel buffer keymaps ─────────────────────────────────────────────────────

-- Remap insert-mode triggers to open the reply float instead of editing.
--
-- Why remap rather than ignore?
--   The buffer is nomodifiable, so i/a/o/CR would normally throw E21 ("cannot
--   make changes"). An E21 in the middle of a conversation is jarring. The
--   remaps intercept all natural "I want to type something" gestures and route
--   them to prompt_input(), which is exactly what the user intends.
--
-- Why not remap in the plugin spec keys table?
--   keys-table keymaps are global. These must be buffer-local (active only
--   when cursor is in the claude panel) to avoid clobbering i/a/o globally.
local function set_panel_keymaps(buf)
  local function open_input()
    mod.prompt_input()
  end
  for _, key in ipairs({ "i", "a", "o" }) do
    vim.keymap.set("n", key, open_input, {
      buffer  = buf,
      noremap = true,
      silent  = true,
      desc    = "Claude: open reply float",
    })
  end
  -- <CR> confirms the active permission choice when a card is up; otherwise it
  -- opens the reply float (same as i/a/o).
  vim.keymap.set("n", "<CR>", function()
    if state.perm then
      resolve_permission(state.perm.options[state.perm.choice].kind)
    else
      open_input()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: reply / confirm permission",
  })
  -- <Esc> rejects the pending permission when a card is up; otherwise it
  -- interrupts the current turn (control_request) while keeping the session
  -- alive. Matches the Claude Code TUI's Esc behaviour.
  vim.keymap.set("n", "<Esc>", function()
    if state.perm then
      resolve_permission("deny")
    else
      mod.interrupt()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: interrupt current turn",
  })

  -- Mouse: clicking a "Thought" fold toggles it open/closed. <LeftRelease> fires
  -- AFTER the default <LeftMouse> has positioned the cursor, so the line under the
  -- cursor is the clicked row — and for a closed fold that row is its start line
  -- (the literal "▼ Thought" header), so the same match works in both states.
  -- Clicks elsewhere (prose, code, thinking body when expanded) fall through.
  vim.keymap.set("n", "<LeftRelease>", function()
    local lnum = vim.fn.line(".")
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    if line:match("^▼ Thought") then
      pcall(vim.cmd, "normal! za")
      -- A pad (question card / chat bar) may be reserved; expanding the fold pushes
      -- the last line down under it. Re-anchor so existing output stays above.
      reanchor_pad()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: toggle thinking fold on click",
  })

  -- Keyboard fold toggle: same re-anchor as the mouse path. `normal! za` uses the
  -- non-remapped default toggle (no recursion); reanchor_pad lifts the last line
  -- back above any reserved pad when the fold's height change moved it.
  vim.keymap.set("n", "za", function()
    pcall(vim.cmd, "normal! za")
    reanchor_pad()
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: toggle fold + re-anchor pad",
  })
end

-- ─── Persistent bidirectional subprocess (spawn + send) ──────────────────────

-- Architecture: ONE long-lived `claude` process per panel session, driven over
-- stdin/stdout as newline-delimited stream-json — the same mode KOS Capture uses
-- (kos-capture/screens/ingest.py). Spawn args:
--   --print --input-format stream-json --output-format stream-json --verbose
-- Each user turn is a stream-json `user` message written to stdin; the process
-- streams events back and STAYS ALIVE for the next turn, holding conversation
-- context natively (no --resume/--session-id juggling).
--
-- Why this and not per-message --print?
--   The old per-message design existed only to dodge a stdout-buffering bug: with
--   plain `--print` + an OPEN stdin pipe, Claude's Node runtime buffers all
--   stdout until stdin EOF, so on_stdout never fires. That bug is specific to
--   --print WITHOUT --input-format stream-json. In stream-json INPUT mode Claude
--   runs a read-eval-stream loop and flushes per message with stdin held open —
--   verified against the real binary (two sequential messages on one process,
--   system/init emitted up front). Keeping the process alive is what lets the
--   panel run slash commands, skills, and plan mode like the terminal does:
--   those are just message text (e.g. "/kos-ingest") the same way KOS sends them.

-- Build the argv for the persistent process from current session settings
-- (model + permission mode). Separated out so respawns (model/plan changes)
-- reuse the exact same construction.
local function build_args()
  local args = {
    mod.CLAUDE_BIN,
    "--print",
    "--input-format",    "stream-json",
    "--output-format",   "stream-json",
    "--verbose",
    -- Emit incremental stream_event records (Anthropic SSE: content_block_start/
    -- delta/stop) ON TOP OF the aggregated assistant message. We use only the
    -- thinking block's start/stop to drive a live "Thinking… 2.3s" counter; the
    -- final assistant event still does the actual rendering, so this is additive.
    "--include-partial-messages",
    "--permission-mode", state.permission_mode or "default",
    -- Hidden flag (not in --help, but accepted): the literal string "stdio". The
    -- SDK sets this internally when a canUseTool callback is registered. It makes
    -- the CLI emit can_use_tool control_requests over stdout for any tool not
    -- already allowlisted, which we answer over stdin (dispatch + can_use_tool
    -- branch). Without it the CLI silently auto-denies un-allowlisted tools.
    -- Must persist across model/plan respawns (plan-mode only varies
    -- --permission-mode, never drops this flag) — full protocol in
    -- .work/FINDINGS.md § Q-PERM.
    "--permission-prompt-tool", "stdio",
  }
  -- --model accepts an alias (opus/sonnet/haiku) or a full id. nil = CLI default.
  if state.model and state.model ~= "" then
    table.insert(args, "--model")
    table.insert(args, state.model)
  end
  return args
end

-- Spawn the persistent process if it isn't already running. Returns the job id,
-- or nil on failure (after notifying). stdin is deliberately LEFT OPEN — every
-- turn writes a new stream-json message to it; closing it would EOF the session.
local function ensure_process()
  if state.job_id then return state.job_id end
  stdout_buf = ""
  local job = vim.fn.jobstart(build_args(), {
    cwd = state.stored_root or vim.fn.getcwd(),
    -- Disable caveman for the panel's claude by default (opts.caveman_mode):
    -- CAVEMAN_DEFAULT_MODE is the caveman plugin's env override, so the panel
    -- speaks normally even when interactive sessions default to caveman. env
    -- extends (not replaces) the inherited environment.
    env       = opts.caveman_mode and { CAVEMAN_DEFAULT_MODE = opts.caveman_mode } or nil,
    on_stdout = on_stdout,
    on_stderr = function() end,
    on_exit   = on_exit,
  })
  if job <= 0 then
    vim.notify("Claude: failed to start subprocess", vim.log.levels.ERROR)
    return nil
  end
  state.job_id = job
  return job
end

-- Stop the persistent process (panel close / reset / model+plan respawn).
-- jobstop sends SIGTERM; on_exit fires asynchronously and clears job_id, so we
-- null it here too to make an immediate respawn safe.
local function stop_process()
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
  end
  stop_spinner()
  state.working = false
end
mod._stop_process = stop_process

-- Write a stream-json user message to the live process and arm the working
-- state + spinner. Spawns the process on first use. Does NOT echo — callers that
-- want the transcript echo call render_user first (see send).
local function dispatch_send(text)
  if not ensure_process() then
    clear_hint()
    return false
  end
  state.system_ready = false
  state.working      = true
  state.turn_t0      = vim.loop.now()   -- cumulative turn timer (every spinner phase + churn line)
  state.activity_t0  = vim.loop.now()   -- baseline for the first thinking block's timer
  state.think_dur    = nil              -- no stale duration from a prior turn
  state.think_tokens = 0
  state.tool_run     = nil
  -- One flavour word per REQUEST, fixed for the whole turn (like the official
  -- TUI) — picked here, NOT rotated mid-turn while thinking/working. Store the
  -- INDEX (not just the word) so render_result's done line can reuse it and the
  -- past-tense "✻ Proofed for 4m" rhymes with the live "Proofing…" the user saw.
  state.flavor_idx   = math.random(#FLAVOR)
  state.flavor_word  = FLAVOR[state.flavor_idx]
  start_spinner()
  -- One stream-json `user` message per turn, newline-terminated. The process
  -- reads it from stdin, streams events back, and waits for the next message.
  local msg = vim.json.encode({
    type    = "user",
    message = { role = "user", content = { { type = "text", text = text } } },
  })
  pcall(vim.fn.chansend, state.job_id, msg .. "\n")
  return true
end

-- Send a brand-new turn: echo the message into the transcript (normal colour),
-- a blank line so the spinner gets its own line, then dispatch it.
local function send(text)
  -- Clear any lingering placeholder BEFORE the user echo. render_user runs before
  -- dispatch_send's start_spinner, so a placeholder still on the last line (a turn
  -- that ended without a result event, or a rapid re-send) would otherwise get the
  -- echo appended below it — and then stop_spinner's "delete last line" would eat
  -- the echo instead of the placeholder.
  remove_typing_ph()
  render_user(text)
  buf_append({ "" })
  dispatch_send(text)
end
mod._send = send

-- Queue a message typed while a turn is in flight. It shows as a shaded virtual
-- line at the panel bottom (render_queue) and is drained when the turn ends.
local function enqueue(text)
  state.queue[#state.queue + 1] = text
  render_queue()
end

-- After a turn ends, send the next queued message (if any). The queued item then
-- echoes in the normal user colour via send() — i.e. it "registers" with Claude.
local function maybe_send_next()
  if state.working or #state.queue == 0 then return end
  local text = table.remove(state.queue, 1)
  render_queue()
  send(text)
end
mod._maybe_send_next = maybe_send_next

-- Public submit used by the input float: send immediately when idle, otherwise
-- queue (type-ahead while Claude is working, like the Claude Code TUI).
local function submit(text)
  if state.working then
    enqueue(text)
  else
    send(text)
  end
end

-- ─── Chat input float (Goal 6.5) ─────────────────────────────────────────────

-- Open the reply input as a rounded floating bar anchored to the bottom of the
-- panel — the stylish chat bar.
--
-- Why a float, not a split?
--   A split adds a second per-window statusline between the panel and the input
--   (the stray "claude [-]" bar) and looks plain. The float keeps the rounded,
--   bordered look the user wants. The float carries filetype "claude" too, so its
--   own (active) lualine bar shows the modal CLAUDE … INSERT … CODE while typing;
--   the panel behind it falls back to the inactive_sections variant
--   (lua/plugins/ui.lua) — per-window bars, no shared global statusline.
--
-- The burn meters (5h / weekly / context) render INSIDE the box, on their own row
-- below the input (a virtual line), so the single rounded outline wraps both the
-- input and the meters. The bar's interior is the CursorLine gray (ClaudeBarBg) so
-- it reads flush. The newest output is kept visible above the bar by reserving its
-- footprint as bottom padding (set_bottom_pad); the over-scroll clamp adds that pad
-- so it doesn't fight the push-up.
local function open_chat_float(title, callback, opts)
  opts = opts or {}
  -- When persist_draft is set, the bar's unsent text survives a hide/show via
  -- state.chat_draft (see close()/submit below). Only the main "Reply" bar opts in.
  local persist_draft = opts.persist_draft == true
  -- Flipped true the instant a real submit fires, so close() knows NOT to re-save
  -- the (already-sent) text as a draft.
  local submitted = false
  -- Span the full panel width: left edge flush with the panel, width = panel minus
  -- the two border chars. Shared geometry helper (anchors to the panel's real
  -- screen column — same as the permission/question floats).
  local float_col, float_w = panel_float_geom()

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype   = "prompt"   -- <CR> fires prompt_setcallback; no manual map needed
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].swapfile  = false
  -- Same filetype as the panel buffer so the modal statusline keys off it.
  vim.bo[ibuf].filetype  = "claude"

  -- Surface the active permission mode in the bar's title: "Plan Mode" when
  -- planning (read-only gate), "Build Mode" for the default (edits apply). Mirrors
  -- the border color (ClaudeBarBorderPlan vs ClaudeBarBorder) below.
  local mode_label = (state.permission_mode == "plan") and " - Plan Mode" or " - Build Mode"
  local label      = title .. mode_label
  local meter_ns = vim.api.nvim_create_namespace("claude_bar_meters")

  -- Render the meters as a virtual line attached below the LAST input line.
  -- Returns 1 if a meter row was drawn, 0 if there's no data. Re-called on resize
  -- and on every text change so the meters re-fit the width AND stay below the
  -- input. Anchoring to the last line (not line 0) is critical: a multi-line paste
  -- adds lines 1,2,3…, and a line-0 anchor would render the meters in the MIDDLE
  -- of the text — and scroll them off the top once the input grew past the view.
  local function render_meters()
    vim.api.nvim_buf_clear_namespace(ibuf, meter_ns, 0, -1)
    local m = require("utils.claude_burn").chunks(float_w)
    if not m then return 0 end
    local last = math.max(vim.api.nvim_buf_line_count(ibuf) - 1, 0)
    vim.api.nvim_buf_set_extmark(ibuf, meter_ns, last, 0, {
      virt_lines = { m }, virt_lines_above = false,
    })
    return 1
  end

  local win = vim.api.nvim_open_win(ibuf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = vim.o.lines - 2,
    col       = float_col,
    width     = float_w,
    height    = 1,                 -- grown to input rows + meter row below
    border    = "rounded",
    style     = "minimal",
    title     = " " .. label .. " ",
    title_pos = "left",
  })

  -- Flush surface: interior + border share the CursorLine gray (ClaudeBarBg /
  -- ClaudeBarBorder) so the rounded box reads as one solid bar against the panel,
  -- with only the clay (or plan-blue) outline standing out.
  local border_hl = (state.permission_mode == "plan") and "ClaudeBarBorderPlan" or "ClaudeBarBorder"
  vim.wo[win].winhighlight = "FloatBorder:" .. border_hl
    .. ",FloatTitle:" .. border_hl
    .. ",NormalFloat:ClaudeBarBg"

  -- Soft-wrap long input onto new lines (a growing paragraph) instead of scrolling
  -- horizontally off-screen. linebreak wraps at word boundaries.
  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true
  harden_float_scroll(win)   -- uniform with the permission/question floats (no over-scroll)

  -- Size the box to enclose the input rows PLUS the meter row, and reserve that
  -- footprint as panel bottom padding so the newest output rides just above the
  -- bar. Called on open, on input grow, and on resize.
  local MAX_INPUT_ROWS = 12
  local cur_rows       = 1
  local function apply_layout()
    if not vim.api.nvim_win_is_valid(win) then return end
    local mrows = render_meters()
    local h     = cur_rows + mrows
    local c     = vim.api.nvim_win_get_config(win)
    if c.height ~= h then
      c.height = h
      vim.api.nvim_win_set_config(win, c)
    end
    set_bottom_pad(h + 3)   -- h interior + 2 border + 1 blank separator row
  end

  local function fit_height_now()
    if not vim.api.nvim_win_is_valid(win) then return end
    local lines = vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)
    local rows  = 0
    for _, l in ipairs(lines) do
      rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / float_w))
    end
    rows = math.min(math.max(rows, 1), MAX_INPUT_ROWS)
    if rows ~= cur_rows then
      cur_rows = rows
      apply_layout()           -- re-fits height AND re-anchors meters
    else
      render_meters()          -- height unchanged but the last line may have moved
    end
  end

  -- Fit the height SYNCHRONOUSLY on the text change, NOT on a debounce timer. The
  -- old 16ms vim.defer_fn left a one-frame window where the buffer had already
  -- wrapped to a new screen row but the float hadn't grown yet: too short, the
  -- window scrolled the "❯" prompt line off the top and the wrapped text flashed
  -- up where the arrow had been. Fitting in the same tick as the keystroke folds
  -- the resize into that redraw, so there's no intermediate too-short frame.
  -- Nothing to coalesce: fit_height_now only triggers apply_layout on an actual
  -- row-count change (a wrap boundary crossing), not on every keystroke.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    buffer   = ibuf,
    callback = fit_height_now,
  })

  -- Keep the bar pinned to the Claude column + bottom when the terminal/window is
  -- resized (the fixed-width panel's left edge shifts as the editor grows, so a
  -- float fixed at open-time col drifts out of the column). Shared resize helper
  -- repositions col/row/width; the callback re-fits the meters + height to the new
  -- width. close() tears the augroup down by name ("ClaudeChatFloat").
  attach_panel_float_resize(win, "ClaudeChatFloat", function(_, _, w)
    float_w = w        -- render_meters / fit_height_now wrap to this width
    apply_layout()     -- re-fit meters to the new width + resize height
  end)

  -- "❯ " prompt arrow (U+276F — not a keyboard char), highlighted terminal-green
  -- via a window-local match so it reads like a shell prompt. The arrow is
  -- display-only; the text passed to the callback excludes it.
  vim.fn.prompt_setprompt(ibuf, "❯ ")
  vim.fn.matchadd("ClaudeArrow", "^❯")

  -- Show the cursor while the chat bar is open (the panel hides it globally via
  -- guicursor). Done explicitly here rather than relying on the panel's
  -- WinLeave→restore, which was unreliable and left the cursor invisible while
  -- typing. close() re-hides it; focus returns to the read-only panel.
  vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

  local function close()
    -- Save unsent text BEFORE the buffer is wiped. Skip on a submit close — that
    -- text is already on its way to Claude, so the draft must clear, not persist.
    if persist_draft and not submitted and vim.api.nvim_buf_is_valid(ibuf) then
      local last = vim.api.nvim_buf_get_lines(ibuf, -2, -1, false)[1] or ""
      state.chat_draft = last
    end
    vim.o.guicursor = "a:ver1-ClaudeCursorHidden"   -- re-hide; focus returns to panel
    clear_bottom_pad()   -- drop the reserved space so output reflows to the bottom
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeChatFloat")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Drop the live-bar handles so the permission card won't try to close a dead
    -- window. Guard against a stale closure clobbering a newer bar's handle.
    if state.chat_win == win then
      state.chat_win, state.chat_buf, state.chat_close = nil, nil, nil
    end
  end
  -- Publish the live handles so show_permission_card can dismiss this bar before
  -- opening the card (see state.chat_win docs).
  state.chat_win, state.chat_buf, state.chat_close = win, ibuf, close

  vim.fn.prompt_setcallback(ibuf, function(text)
    submitted = true
    if persist_draft then state.chat_draft = "" end   -- sent → drop the saved draft
    close()
    callback(text ~= "" and text or nil)
  end)

  vim.keymap.set("i", "<Esc>", function() close(); callback(nil) end,
    { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "q",     close, { buffer = ibuf, nowait = true, silent = true })

  -- Auto-dismiss the bar whenever focus leaves it (clicking the panel/editor, or
  -- after a submit closes the window). once=true so it self-removes; close()
  -- guards an already-closed window.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer   = ibuf,
    once     = true,
    callback = function() close() end,
  })

  -- Restore any unsent text from a previous hide. Set the input line before
  -- startinsert! so the cursor lands at its end, and refit the box height in case
  -- the restored text wraps to multiple rows.
  if persist_draft and state.chat_draft ~= "" then
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { state.chat_draft })
    fit_height_now()
  end

  -- Draw the meters + size the box + reserve the push-up space, all up front.
  apply_layout()

  vim.cmd("startinsert!")   -- ! = start after existing content (end of prompt)
end

-- Test seam: the input float is a real nvim_open_win prompt buffer, which can't
-- be driven from a headless spec (no interactive <CR>). Routing both input
-- entry points (prompt_input, ask_selection) through this indirection lets the
-- spec override it with a stub that invokes the callback synchronously. In
-- production it's just open_chat_float.
mod._open_chat_float = open_chat_float
-- Exposed for unit tests (pure markdown transform — no buffer writes).
mod._build_md_lines = build_md_lines
mod._render_table   = render_table

--- Open the chat float for the user to type a reply to Claude.
function mod.prompt_input()
  -- Block new input when a diff is pending: accepting/rejecting the edit must
  -- happen before the conversation can continue, so we don't create a race
  -- between a follow-up message and the pending file change on disk.
  if state.perm then
    vim.notify("⚠ Permission required — ←/→ select, <CR> confirm, <Esc> reject",
      vim.log.levels.WARN)
    return
  end
  if state.diff_pending then
    vim.notify("⚠ Awaiting review — accept or reject first", vim.log.levels.WARN)
    return
  end
  -- NOTE: we no longer block while Claude is working. submit() queues the message
  -- (type-ahead) and shows it shaded at the panel bottom until the current turn
  -- ends, then sends it — mirroring the Claude Code TUI.
  mod._open_chat_float("Reply to Claude", function(text)
    if not text then return end
    submit(text)
  end, { persist_draft = true })
end

-- ─── Interrupt (Goal 6.6) ─────────────────────────────────────────────────────

--- Interrupt the current turn WITHOUT killing the session.
-- Sends a stream-json control_request {subtype="interrupt"} to the live process
-- (the Claude Code control protocol). The process aborts the in-flight turn but
-- stays alive, so conversation context is preserved and the user can keep
-- chatting. Falls back to a no-op when nothing is in flight.
-- (Contrast: mod.reset() tears the whole session down and starts blank.)
function mod.interrupt()
  if not (state.job_id and state.working) then return end
  local req = vim.json.encode({
    type       = "control_request",
    request_id = uuid4(),
    request    = { subtype = "interrupt" },
  })
  pcall(vim.fn.chansend, state.job_id, req .. "\n")
  -- The process emits a result/error for the aborted turn; dispatch clears
  -- working + spinner there. Clear the spinner now too so the UI feels snappy.
  state.working = false
  stop_spinner()
  if not state.diff_pending then clear_hint() end
end

-- ─── Over-scroll clamp ────────────────────────────────────────────────────────

-- How many blank rows the panel may scroll PAST the last content line. Set to 1:
-- the view stops one line past the last content row — no dead over-scroll band
-- below the conversation. Scrolling UP to read history is unaffected (free_below
-- returns nil when the last line is off the bottom, so the clamp doesn't fire).
local SCROLL_TAIL = 1

-- Re-entrancy guard: the re-anchor below re-fires WinScrolled. The guard plus the
-- "only when over" test means the correction settles in one step (after the
-- re-anchor the last line sits at its allowed row, so the nested call is a no-op).
local clamping = false

-- Clamp panel over-scroll so the last content line can rise at most SCROLL_TAIL
-- rows above its resting position (pad_rows above the window bottom). Driven by
-- WinScrolled so it catches EVERY scroll source — mouse wheel, <C-e>/<C-d>, search
-- jumps — which a key-by-key approach can't (the wheel especially bypasses
-- normal-mode maps while the float is focused).
--
-- Measured in SCREEN rows via screenpos(), not a topline-vs-line-count formula:
-- the old formula assumed one screen row per buffer line, so wrapped prose and
-- collapsed "thinking" folds made its limit wildly wrong — it trapped the view and
-- the user couldn't scroll down to text that was really there. screenpos() reports
-- the true display row of the last line regardless of wrap/folds.
local function clamp_scroll()
  if clamping then return end
  local win = state.panel_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end

  clamping = true
  pcall(vim.api.nvim_win_call, win, function()
    -- Screen rows between the last content line and the window bottom. nil means
    -- the last line is scrolled off the BOTTOM — the user scrolled UP to read
    -- history; that's allowed, so don't clamp. (Same measurement anchor_last_line
    -- uses, hence the shared helper.)
    local gap = free_below(win, buf)
    if not gap then return end
    -- The last line legitimately rests in the band [floor, limit] above the bottom:
    -- `floor` = pad_rows (the chat bar / question card's reserved space) is the
    -- closest it may sit; `limit` adds SCROLL_TAIL of over-scroll breathing room.
    -- gap > limit → sliding off the top (re-anchor down to limit). gap < floor →
    -- the last line dropped UNDER the reserved pad — happens when a thinking fold
    -- EXPANDS above it, inserting display rows while the topline holds — so lift it
    -- back up to floor or the newest output hides behind the card. Inside the band:
    -- leave it. Both corrections pin to a target via Gzb + an <C-e> nudge (the same
    -- method as anchor_last_line); pinning to the exact boundary makes the
    -- correction only the overshoot delta, so the view holds instead of bouncing.
    local floor  = (state.pad_rows or 0)
    local limit  = floor + SCROLL_TAIL
    local target
    if gap > limit then target = limit
    elseif gap < floor then target = floor end
    if target then
      local so = vim.wo[win].scrolloff
      vim.wo[win].scrolloff = 0
      vim.cmd("keepjumps normal! Gzb")
      local fb = free_below(win, buf)
      if fb and fb < target then
        vim.cmd("keepjumps normal! " .. (target - fb) .. "\005")  -- <C-e> ×(target-fb)
      end
      vim.wo[win].scrolloff = so
    end
  end)
  clamping = false
end

-- Test seam: drive the over-scroll clamp directly in the headless spec.
mod._clamp_scroll = clamp_scroll
mod._SCROLL_TAIL  = SCROLL_TAIL

-- Mouse-wheel-down pre-empt. The WinScrolled clamp corrects AFTER a scroll lands;
-- discrete keyboard scrolls (G, <C-e>) settle in one correction, but the mouse wheel
-- streams events continuously, so the clamp fights every tick → the bounce the user
-- only saw with the mouse. Here we scroll only the room left below the limit and
-- SWALLOW once at it, so the over-scroll never happens and there's nothing to undo.
-- Scroll-up (<ScrollWheelUp>) stays native so reading history is unrestricted.
local WHEEL_STEP = 3   -- rows per wheel notch (matches the default 'mousescroll' ver)
local function panel_wheel_down()
  local win = state.panel_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end
  pcall(vim.api.nvim_win_call, win, function()
    local step  = WHEEL_STEP
    local gap   = free_below(win, buf)
    -- gap nil = last line is below the viewport (scrolled up in history): tons of
    -- room, scroll the full notch. Otherwise cap the step to the rows left so we
    -- land exactly on the limit and never overshoot (overshoot is what bounced).
    if gap then
      local room = ((state.pad_rows or 0) + SCROLL_TAIL) - gap
      if room <= 0 then return end          -- already at the limit → swallow the notch
      if room < step then step = room end
    end
    local so = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    vim.cmd("keepjumps normal! " .. step .. "\005")  -- step × <C-e>
    vim.wo[win].scrolloff = so
  end)
end

-- ─── Panel window placement ───────────────────────────────────────────────────

-- Open a new vertical split, place it at the far-right column (via
-- term_layout.place_vertical), and associate it with the panel buffer.
-- Also hooks up claude_diff autocmds (on_panel_open) and the input keymaps.
local function open_panel_window(buf)
  local width = panel_width()
  -- vsplit creates a new window; the new window becomes current.
  -- We immediately retarget it to the panel buffer before resizing.
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- place_vertical calls `wincmd L` to push the panel to the far-right column,
  -- then resizes it to `width` columns. Same strategy as the OpenCode panel;
  -- see term_layout.lua header for why this defeats toggleterm's split grouping.
  require("utils.term_layout").place_vertical(width)

  state.panel_win    = win
  state.claude_active = true
  -- foldmethod must be window-local (vim.wo), not buffer-local (vim.bo).
  -- Set it here, after the window is created and associated with the buffer,
  -- so render_thinking's nvim_win_call fold commands work correctly.
  vim.wo[win].foldmethod = "manual"
  -- Custom foldtext so a collapsed thinking block reads as "▶ Thought · <time>"
  -- (see mod._foldtext) instead of Vim's default "+-- N lines:" line.
  vim.wo[win].foldtext = "v:lua.require('utils.claude')._foldtext()"

  -- Pin the panel width so growing the OS/terminal window adds columns to the
  -- editor (the non-fixed window), not the panel. Without this the rightmost
  -- window absorbs the extra width and the Claude panel balloons on resize.
  vim.wo[win].winfixwidth = true

  -- Panel background = ClaudeNormal (CursorLine-derived gray) so the whole Claude
  -- column reads as one flush surface with the chat bar.
  vim.wo[win].winhighlight = PANEL_HL_BASE

  -- Hide end-of-buffer "~" filler lines. The panel is an output surface; the
  -- tildes below the content add visual noise and imply empty-file semantics.
  -- eob: blank the ~ end-of-buffer markers; fold: blank the trailing fill dashes
  -- after the foldtext so a collapsed "▶ Thought" row reads clean to the edge.
  vim.wo[win].fillchars = "eob: ,fold: "

  -- Disable cursorline in the panel. It's a read-only output surface, and the
  -- global cursorline=true otherwise paints a gray strip across whatever row the
  -- cursor rests on (e.g. the banner separator) — that strip is the "orange line
  -- background not flush" artifact. Off here, every row shares the panel bg.
  vim.wo[win].cursorline = false

  -- Panel is a read-only output surface — line numbers add noise and imply an
  -- editable file. Disable both absolute and relative numbers in this window.
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  -- No gutters: panel_width() uses nvim_win_get_width as the text width, so any
  -- reserved fold/sign column would make padded surfaces (code blocks, cards)
  -- overshoot by the gutter width and soft-wrap. Thinking folds are toggled via
  -- the clickable foldtext row + `za`, not the foldcolumn markers, so 0 is safe.
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].signcolumn = "no"

  -- smoothscroll: scroll by SCREEN rows, so the chat-bar push-up (anchor_last_line)
  -- and clamp can lift a partially-wrapped line precisely instead of snapping to
  -- whole-line boundaries. scrolloff=0: nothing holds the last line off the bottom,
  -- so `zb` can place it flush (the bar reserves space via the pad, not scrolloff).
  vim.wo[win].smoothscroll = true
  vim.wo[win].scrolloff    = 0

  -- Enable FileChangedShell interceptor + disable autoread for the session.
  require("utils.claude_diff").on_panel_open()

  local grp = vim.api.nvim_create_augroup("ClaudeDirTrack", { clear = true })

  -- Keep the banner path (and claude's run cwd) tracking the directory the user
  -- is in. DirChanged fires on every :cd / :lcd / autochdir move; we update
  -- stored_root so the next send runs there, and rewrite the banner path line.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      state.stored_root = vim.fn.getcwd()
      update_banner_cwd(vim.fn.fnamemodify(state.stored_root, ":~"))
    end,
  })

  -- Re-fit the separator lines to the panel width whenever the window resizes
  -- (OS window drag, :resize, terminal size change) so the dividers never wrap.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      refit_separators()
    end,
  })

  -- Cap over-scroll so the conversation can't be flung off the top of the window.
  -- The mouse wheel is pre-empted below (prevents the over-scroll outright); this
  -- WinScrolled clamp is the backstop for everything else — G, search jumps, page
  -- keys — that the wheel map can't intercept. See clamp_scroll for the math.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      clamp_scroll()
    end,
  })

  -- Mouse-wheel-down pre-empt (see panel_wheel_down): scroll only the room left to
  -- the limit so the continuous wheel stream can't out-run the after-the-fact clamp
  -- and bounce. Buffer-local so it only governs the panel; wheel-up stays native.
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    vim.keymap.set("n", "<ScrollWheelDown>", panel_wheel_down,
      { buffer = state.panel_buf, silent = true })
  end

  -- Hide the cursor while the panel is focused. guicursor is global so we save on
  -- WinEnter and restore on WinLeave. winhighlight cannot override Cursor/CursorNC —
  -- guicursor is the only per-focus API. We also stash the real (visible) guicursor
  -- in module state so the chat bar can explicitly restore it on open rather than
  -- depending on the WinLeave→restore race, which left the cursor invisible while
  -- typing if _saved_gc had already been consumed.
  local function remember_real_gc()
    if vim.o.guicursor ~= "a:ver1-ClaudeCursorHidden" then
      state.real_guicursor = vim.o.guicursor
    end
  end
  local _saved_gc = nil
  vim.api.nvim_create_autocmd("WinEnter", {
    group  = grp,
    buffer = buf,
    callback = function()
      if vim.o.guicursor ~= "a:ver1-ClaudeCursorHidden" then
        _saved_gc = vim.o.guicursor
      end
      remember_real_gc()
      vim.o.guicursor = "a:ver1-ClaudeCursorHidden"
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group  = grp,
    buffer = buf,
    callback = function()
      if _saved_gc then
        vim.o.guicursor = _saved_gc
        _saved_gc = nil
      end
    end,
  })
  -- vsplit creates the window before nvim_win_set_buf, so WinEnter fires with
  -- the wrong buffer and the buffer= filter skips it. Hide directly.
  _saved_gc = vim.o.guicursor
  remember_real_gc()
  vim.o.guicursor = "a:ver1-ClaudeCursorHidden"


  -- Buffer-local keymaps: must be set after the buffer is associated with a
  -- window (some keymaps reference the window for focus checks).
  set_panel_keymaps(buf)
  clear_hint()
  return win
end

-- ─── Toggle / open / reset (Goals 6.8, 6.6) ──────────────────────────────────

--- Toggle the panel open or closed (`<leader>cc`).
-- @param root_override string|nil  When given (dock-launch flow), this is the
--   authoritative project root the panel anchors to — claude runs in it and the
--   banner shows it. Without it (<leader>cc) the root is detected from the
--   current buffer/cwd. The override exists because the dock picker knows the
--   chosen project, while cwd may still be the launcher dir (~/dev) at this point.
function mod.toggle(root_override)
  if not ensure_available() then return end

  -- Mutex: if OpenCode is open, close it before opening Claude (FINDINGS.md § A5).
  -- Both panels use place_vertical(wincmd L); running both simultaneously would
  -- strand one of them on a stale alternate screen. One panel at a time.
  local ok, opencode = pcall(require, "utils.opencode")
  if ok and opencode.state and opencode.state.opencode_active then
    opencode.toggle()
    vim.notify(
      "Claude panel open — OpenCode closed (<leader>oc to switch)",
      vim.log.levels.INFO
    )
  end

  -- If the panel window is currently visible, close it. The persistent process
  -- is torn down too — a hidden panel shouldn't keep a claude session running.
  if state.claude_active and state.panel_win
      and vim.api.nvim_win_is_valid(state.panel_win) then
    stop_process()
    vim.api.nvim_win_close(state.panel_win, true)
    state.panel_win    = nil
    state.claude_active = false
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeDirTrack")
    require("utils.claude_diff").on_panel_close()
    return
  end

  -- Opening: the panel anchors to whatever directory the user is in — the
  -- current working directory (vim.fn.getcwd()) — so claude runs there and the
  -- banner path matches the editor cwd shown in the title bar. A dock launch may
  -- pass an explicit root before cwd has settled, so it takes precedence. The
  -- DirChanged autocmd (see open_panel_window) keeps this live as the user moves.
  local root        = root_override or vim.fn.getcwd()
  state.stored_root = root

  local buf = ensure_panel_buf()
  open_panel_window(buf)

  -- Render banner on fresh buffer only (reopen after close reuses scrollback).
  -- The persistent subprocess is NOT spawned here; the first send() spawns it.
  if vim.api.nvim_buf_line_count(buf) <= 1 then
    -- cwd + version known now (version from the binary path); model shows the
    -- picked --model if set, else fills from system/init after the first message.
    -- Show ~-relative path so long absolute roots don't overflow the panel.
    render_banner(state.model or "", binary_version(),
      vim.fn.fnamemodify(state.stored_root or root, ":~"))
  end
  clear_hint()
end

--- Open the panel without toggling — dock-launch flow (FINDINGS.md § A2).
-- Idempotent: if the panel is already visible, does nothing.
-- @param root string|nil  Authoritative project root (passed by the dock picker).
function mod.open(root)
  if state.claude_active and state.panel_win
      and vim.api.nvim_win_is_valid(state.panel_win) then
    return
  end
  mod.toggle(root)
end

--- Hard reset: kill the current session and start a completely blank one.
-- Unlike <Esc> (interrupt that keeps the session + history), this kills the
-- process and clears the panel buffer so the next send spawns a brand-new
-- session with an empty scrollback. Model + permission-mode choices persist.
function mod.reset()
  -- Kill the persistent process if running. on_exit fires asynchronously but
  -- stop_process nulls job_id now so it becomes a no-op when it arrives.
  stop_process()

  -- Clear all state synchronously so toggle() below starts with a clean slate.
  -- session_id is cleared too so the next send starts a fresh session rather
  -- than carrying anything over from the one we just abandoned.
  state.job_id        = nil
  state.session_id    = nil
  state.session_cost  = nil
  state.stored_root   = nil
  state.diff_queue    = {}
  state.queue         = {}
  state.working       = false
  state.system_ready  = false
  state.diff_pending  = false
  state.prewrite      = nil
  if state.perm and state.perm.win and vim.api.nvim_win_is_valid(state.perm.win) then
    pcall(vim.api.nvim_win_close, state.perm.win, true)
  end
  state.perm          = nil
  if state.diff_card and state.diff_card.win and vim.api.nvim_win_is_valid(state.diff_card.win) then
    pcall(vim.api.nvim_win_close, state.diff_card.win, true)
  end
  state.diff_card      = nil
  state.claude_active = false
  stdout_buf          = ""

  -- Delete the old panel buffer so ensure_panel_buf() creates a fresh one.
  -- Without this, the new session would append to the old scrollback.
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    vim.api.nvim_buf_delete(state.panel_buf, { force = true })
  end
  state.panel_buf = nil
  state.panel_win = nil

  require("utils.claude_diff").on_panel_close()
  mod.toggle()
end

-- ─── Model picker + plan-mode toggle ─────────────────────────────────────────

-- Selectable model aliases. "default" clears --model (CLI/account default).
-- Aliases resolve to the latest of each family at spawn time, matching the
-- terminal's `--model opus|sonnet|haiku`.
local MODEL_CHOICES = { "default", "opus", "sonnet", "haiku" }

--- Pick the model for the panel session (`<leader>cm`).
-- Model is a spawn-time flag, so a running session can't switch mid-flight: we
-- stop the current process and let the next send respawn with the new --model.
-- That resets conversation context, so we tell the user. The banner updates at
-- once to reflect the choice.
function mod.pick_model()
  vim.ui.select(MODEL_CHOICES, { prompt = "Claude model" }, function(choice)
    if not choice then return end
    state.model = (choice == "default") and nil or choice
    -- Tear down the live process so the next message respawns with --model.
    local had_session = state.job_id ~= nil
    stop_process()
    -- Reflect immediately in the banner. friendly_model maps the alias to the
    -- full display name ("sonnet" → "Sonnet 4.6"); "default" blanks the line so
    -- system/init fills the real model after the first message.
    local fm = state.model and friendly_model(state.model) or ""
    state.model_display = fm   -- modal statusline; "" until system/init re-fills it
    update_banner_model(fm)
    vim.notify(
      "Claude model → " .. choice ..
      (had_session and "  (new session — context reset)" or ""),
      vim.log.levels.INFO
    )
  end)
end

--- Friendly display name of the panel's current model (e.g. "Sonnet 4.6") for the
--- modal statusline. Prefers the picked model, falls back to whatever system/init
--- last reported, then to a generic "Claude" so the segment is never blank.
function mod.current_model()
  if state.model_display and state.model_display ~= "" then return state.model_display end
  local fm = state.model and friendly_model(state.model) or ""
  if fm ~= "" then return fm end
  -- Before the panel's first turn, borrow the model from the burn state file as a
  -- hint (last interactive session's model); fall back to a generic label.
  local bm = require("utils.claude_burn").model()
  if bm ~= "" then return bm end
  return "Claude"
end

--- Session cost of the panel's OWN subprocess, formatted "$0.42", for the
--- statusline. "$0.00" before the first turn completes; tracks the fresh session
--- spawned in this Neovim, not the shared burn-state file's last writer.
function mod.session_cost()
  return string.format("$%.2f", state.session_cost or 0)
end

-- Whitelist of caveman intensity/independent modes that count as "enabled". Mirrors
-- the case statement in the caveman plugin's caveman-statusline.sh so we render a
-- badge for exactly the same set the plugin considers active. "off" is absent: the
-- activate hook DELETES the flag file in off mode, so absence already means off.
local CAVEMAN_MODES = {
  lite = true, full = true, ultra = true,
  ["wenyan-lite"] = true, wenyan = true,
  ["wenyan-full"] = true, ["wenyan-ultra"] = true,
  commit = true, review = true, compress = true,
}

--- True when the user's caveman plugin is currently enabled, for the statusline
--- "CAVEMAN" badge. Reads the plugin's flag file (~/.claude/.caveman-active, or
--- $CLAUDE_CONFIG_DIR/.caveman-active) the same hardened way the plugin's own
--- statusline does: a missing file means off (the activate hook unlinks it then),
--- symlinks are refused (a local attacker could point it at a secret), and the
--- content is capped + validated against the mode whitelist before we trust it.
function mod.caveman_active()
  local dir  = vim.env.CLAUDE_CONFIG_DIR
  if not dir or dir == "" then dir = vim.fn.expand("~/.claude") end
  local flag = dir .. "/.caveman-active"
  -- lstat (NOT stat) so a symlink is seen as a symlink, not followed; reject it.
  local st = vim.loop.fs_lstat(flag)
  if not st or st.type ~= "file" then return false end
  local fd = vim.loop.fs_open(flag, "r", 438)
  if not fd then return false end
  local data = vim.loop.fs_read(fd, 64, 0) or ""
  vim.loop.fs_close(fd)
  local mode = data:gsub("[\r\n]", ""):lower():match("^%s*(.-)%s*$")
  return CAVEMAN_MODES[mode] == true
end

--- Toggle Plan mode for the panel session (`<leader>cp`).
-- Plan mode is the --permission-mode plan flag (read-only planning; no edits).
-- Like the model, it's spawn-time, so toggling respawns; context resets.
function mod.toggle_plan()
  state.permission_mode = (state.permission_mode == "plan") and "default" or "plan"
  local on = state.permission_mode == "plan"
  local had_session = state.job_id ~= nil
  stop_process()
  vim.notify(
    "Claude Plan mode " .. (on and "ON" or "OFF") ..
    (had_session and "  (new session — context reset)" or ""),
    vim.log.levels.INFO
  )
end

-- ─── Ask-selection (`<leader>cq`, Goal 6.7) ───────────────────────────────────

-- Read the last visual selection from '< and '> marks.
-- Must be called after leaving visual mode — the marks are only flushed to the
-- current selection when visual mode is exited. Matches the implementation in
-- opencode.lua get_visual_selection (same edge cases apply).
local function get_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
  if #lines == 0 then return "" end
  local end_col = e[3]
  -- selection=exclusive: '> points one past the last char; subtract 1 to match
  -- the actual last character byte (mirrors the opencode.lua correction).
  if vim.o.selection == "exclusive" then
    end_col = end_col - 1
  end
  lines[#lines] = lines[#lines]:sub(1, end_col)
  lines[1]      = lines[1]:sub(s[3])
  return table.concat(lines, "\n")
end

--- Ask Claude about a visual selection (`<leader>cq`).
-- Opens the panel if needed, then sends "question\n\n```\nselection\n```"
-- as a JSON user message. The fenced code block tells Claude the selection
-- is code, not prose.
function mod.ask_selection()
  if not ensure_available() then return end

  -- This is a mode="v" keymap: it fires while still in visual mode.
  -- Escape to normal mode first so '< and '> flush to the CURRENT selection.
  -- Without this, the marks hold the PREVIOUS selection (empty on first use).
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end

  local selection = get_visual_selection()
  if selection == "" then
    vim.notify("Claude: no text selected", vim.log.levels.WARN)
    return
  end

  mod._open_chat_float("Ask claude @selection", function(question)
    if not question then return end
    -- Open the panel first (idempotent if already open), then send.
    mod.open()
    -- vim.schedule: mod.open() may have triggered autocmds and UI redraws;
    -- sending the message after a scheduler tick ensures the panel is fully
    -- initialised before we try to write to the subprocess stdin.
    vim.schedule(function()
      submit(question .. "\n\n```\n" .. selection .. "\n```")
    end)
  end)
end

-- ─── Diff state bridge (called by claude_diff.lua) ────────────────────────────

--- Called by claude_diff when a vimdiff opens — locks the input bar and raises
-- the Accept/Reject card (Goal 14.3). `info` is { path, kind } — kind is "new"
-- (Claude-created file) or "edit" (existing file changed); nil path skips the
-- card (defensive — on_diff_open should always be called with one in practice).
-- The user must accept or reject the proposed edit before sending another
-- message; allowing a follow-up while the file is in-diff risks confusing
-- Claude with a half-applied change still on disk.
function mod.on_diff_open(info)
  state.diff_pending = true
  set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
  local path = info and info.path
  if path then
    -- pcall so a card-rendering failure can't leave diff_pending set without
    -- ANY visible way to resolve it — the hint above (and the winbar fallback
    -- in claude_diff.lua) still tell the user how to proceed via <leader>ca/cx.
    local ok, err = pcall(show_diff_card, path, info.kind)
    if not ok then
      vim.notify("Claude: diff review card failed to render (" .. tostring(err) .. ")",
        vim.log.levels.ERROR)
    end
  end
end

--- Called by claude_diff when the current diff is resolved — unlocks input.
function mod.on_diff_close()
  state.diff_pending = false
  -- The card may still be up if the diff resolved via the winbar/<leader>ca/cx
  -- fallback rather than the card itself — drop it either way.
  close_diff_card()
  if not state.working then
    clear_hint()
    -- Review done: release any messages queued during the diff.
    mod._maybe_send_next()
  end
  if state.diff_card_reopen_bar then
    state.diff_card_reopen_bar = false
    vim.schedule(function() mod.prompt_input() end)
  end
end

return mod
