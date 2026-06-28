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
local PANEL_HL_BASE = "Normal:ClaudeNormal,NormalNC:ClaudeNormal,EndOfBuffer:ClaudeNormal"

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

  -- Extmark namespace for the virtual-text "Reply to Claude…" hint at bottom of
  -- panel. Cleared and re-set on every state transition.
  hint_ns       = nil,

  -- Active braille-spinner timer handle while a turn is in flight; nil otherwise.
  spin_timer    = nil,

  -- Model alias/id passed to --model on (re)spawn. nil = CLI default model.
  -- Set by the <leader>cm picker; changing it respawns the process (model is a
  -- spawn-time flag, so the running session can't switch mid-flight).
  model         = nil,

  -- Permission mode passed to --permission-mode on (re)spawn. "acceptEdits" by
  -- default; <leader>cp toggles it to "plan" (and back), respawning the process.
  permission_mode = "acceptEdits",

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

-- Extract the most meaningful target string from a tool_use input dict.
-- Priority: file_path > path > pattern > query > command (truncated to 70 chars).
-- Falls back to "" when none present, so callers can skip the target display.
local function tool_target(input)
  return input.file_path
    or input.path
    or input.pattern
    or input.query
    or (input.command and tostring(input.command):sub(1, 70))
    or ""
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

  for i, bl in ipairs(body) do
    local row = pad_display(CODE_GUTTER .. bl, w)
    local hls = {
      { 0, gutter_b, "ClaudeCodeGutter" },
      { gutter_b, #row, "ClaudeCodeBlock" },          -- bg + neutral fg base, covers inset pad
    }
    if syn and syn[i] then                            -- overlay syntax fg spans
      for _, s in ipairs(syn[i]) do
        local s0 = #CODE_GUTTER + s[1]
        local e0 = #CODE_GUTTER + math.min(s[2], #bl)
        if e0 > s0 then hls[#hls + 1] = { s0, e0, s[3] } end
      end
    end
    out_lines[#out_lines + 1] = row
    out_hls[#out_hls + 1] = hls
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
  vim.api.nvim_buf_set_extmark(buf, state.hint_ns, last, 0, {
    virt_text     = { { text, hl or "ClaudeInput" } },
    virt_text_pos = "eol",
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

-- Test seams: expose the pad/anchor internals so the headless spec can drive the
-- exact push-up math (winh/line-count/topline) without an interactive float.
mod._anchor_last_line = anchor_last_line
mod._set_bottom_pad   = set_bottom_pad
mod._clear_bottom_pad = clear_bottom_pad

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

local function stop_spinner()
  if state.spin_timer then
    vim.fn.timer_stop(state.spin_timer)
    state.spin_timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  spin_i = 1
  set_hint(SPINNER[spin_i] .. " Working…  <Esc> to interrupt", "ClaudeInput")
  render_queue()
  state.spin_timer = vim.fn.timer_start(110, function()
    if not state.working then stop_spinner(); return end
    spin_i = spin_i % #SPINNER + 1
    set_hint(SPINNER[spin_i] .. " Working…  <Esc> to interrupt", "ClaudeInput")
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

-- Render a thinking block as a collapsible manual fold (FINDINGS.md Q3).
--
-- Why manual folds, not marker/indent folds?
--   foldmethod=marker would pollute the buffer content with fold markers.
--   foldmethod=indent is fragile (the indented body lines would auto-fold
--   to depth 1, but prose lines wouldn't fold at all). Manual folds let us
--   set exact start/end lines programmatically after each block is appended.
--
-- Why zR immediately after fold creation?
--   Without zR, newly created folds start closed. The spec calls for thinking
--   blocks to be expanded by default so the user can read them; they can toggle
--   individually with `za` or close all with `zM`.
local function render_thinking(text)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  -- fold header line
  local header_idx = vim.api.nvim_buf_line_count(buf)  -- 0-indexed insertion point
  buf_append({ "▼ Thinking" })
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
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_win_call(state.panel_win, function()
      vim.cmd(fold_start .. "," .. fold_end .. "fold")
      vim.cmd("normal! zR")  -- open all folds: blocks expand by default
    end)
  end
end

-- Render a tool_use block as a single-line "⚙ Verb: target" entry.
-- One line per tool call keeps the panel scannable during long multi-tool turns.
-- Matches the compact format from ingest.py _fmt_tool_use_rich.
-- A blank line is appended after the tool entry so the working spinner has its
-- own line below (the spinner timer re-anchors EOL virt_text to the buffer's
-- last line on every tick; without the blank it shares the tool line).
local function render_tool(name, input)
  local verb   = TOOL_VERB[name] or name
  local target = tool_target(input)
  local line   = "  ⚙ " .. verb .. (target ~= "" and (": " .. target) or "")
  local first  = vim.api.nvim_buf_line_count(state.panel_buf)
  buf_append({ line })
  hl_lines(first, first, "ClaudeTool")
  buf_append({ "" })   -- spinner gets its own line below
end

-- Render the result event that closes a turn. The turn separator is drawn at
-- the TOP of the NEXT turn (by render_user), not here — so a response never
-- ends with a trailing divider. The result event's text duplicates the
-- assistant prose already rendered and may contain embedded newlines (which
-- nvim_buf_set_lines forbids in a single line — the old crash), so we render
-- nothing for it. Kept as a named no-op for the dispatch turn-close semantics.
local function render_result(_text) end

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

-- Dispatch one fully parsed stream-json event object.
local function dispatch(event)
  local ev_type = event.type or ""

  if ev_type == "system" and event.subtype == "init" then
    -- Fill the banner's version (line 0) and model (line 1) now that they're
    -- known. The banner was pre-rendered at panel open with the cwd but no model
    -- or version (those only arrive in system/init). With per-message spawning
    -- system/init fires on every turn; we patch the lines in-place so a second
    -- banner is never appended.
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

  elseif ev_type == "assistant" then
    -- assistant events carry a message with a content array. Each block is one
    -- of: text (prose), thinking (extended thinking), or tool_use.
    local content = (event.message or {}).content or {}
    for _, block in ipairs(content) do
      local btype = block.type or ""
      if btype == "text" then
        render_prose(block.text or "")
      elseif btype == "thinking" then
        render_thinking(block.thinking or "")
      elseif btype == "tool_use" then
        render_tool(block.name or "", block.input or {})
      end
      -- tool_result body rendering is deferred to v2 (TODOS.md backlog)
    end

  elseif ev_type == "result" then
    -- result closes the current turn. After this, claude is waiting for more
    -- input — unlock the input bar (unless a diff review is still pending).
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
  for _, key in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", key, open_input, {
      buffer  = buf,
      noremap = true,
      silent  = true,
      desc    = "Claude: open reply float",
    })
  end
  -- <Esc> in normal mode = interrupt the current turn (control_request) while
  -- keeping the session alive. Matches the Claude Code TUI's Esc behaviour.
  vim.keymap.set("n", "<Esc>", function()
    mod.interrupt()
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: interrupt current turn",
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
    "--permission-mode", state.permission_mode or "acceptEdits",
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
  -- the two border chars.
  local panel_w   = panel_width()
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    panel_w = vim.api.nvim_win_get_width(state.panel_win)
  end
  local float_col = vim.o.columns - panel_w
  local float_w   = math.max(panel_w - 2, 1)   -- -2 for left+right border chars

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype   = "prompt"   -- <CR> fires prompt_setcallback; no manual map needed
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].swapfile  = false
  -- Same filetype as the panel buffer so the modal statusline keys off it.
  vim.bo[ibuf].filetype  = "claude"

  local label    = title .. (state.permission_mode == "plan" and " - Plan Mode" or "")
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
  -- float fixed at open-time col drifts out of the column). Recompute col/row/width
  -- and re-fit the meters to the new width.
  local resize_grp = vim.api.nvim_create_augroup("ClaudeChatFloat", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = resize_grp,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return true end  -- bar gone → self-remove
      local pw = panel_width()
      if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
        pw = vim.api.nvim_win_get_width(state.panel_win)
      end
      float_w = math.max(pw - 2, 1)
      local c = vim.api.nvim_win_get_config(win)
      c.col   = vim.o.columns - pw
      c.row   = vim.o.lines - 2
      c.width = float_w
      pcall(vim.api.nvim_win_set_config, win, c)
      apply_layout()   -- re-fit meters to the new width + resize height
    end,
  })

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
    vim.o.guicursor = "a:block-ClaudeCursorHidden"   -- re-hide; focus returns to panel
    clear_bottom_pad()   -- drop the reserved space so output reflows to the bottom
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeChatFloat")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

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

-- How many blank rows the panel may scroll PAST the last content line. Enough to
-- read the tail of a response without the conversation sliding off the top of the
-- window (the user's complaint: free scroll ran content off-screen). In the 5–8
-- range they asked for.
local SCROLL_TAIL = 6

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
    local n        = vim.api.nvim_buf_line_count(buf)
    local lasttext = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
    -- Screen row of the last line's final cell under the CURRENT view. row 0 means
    -- the last line is scrolled off the BOTTOM — i.e. the user scrolled UP to read
    -- history; that's allowed, so don't clamp.
    local sp = vim.fn.screenpos(win, n, math.max(#lasttext, 1))
    if sp.row == 0 then return end
    local info       = vim.fn.getwininfo(win)[1]
    local win_bottom = info.winrow + info.height - 1
    local free_below = win_bottom - sp.row
    -- The last line legitimately rests pad_rows above the bottom (the chat bar's
    -- reserved space). Allow SCROLL_TAIL of extra over-scroll for breathing room;
    -- beyond that the conversation is sliding off the top, so re-anchor it back.
    local limit = (state.pad_rows or 0) + SCROLL_TAIL
    if free_below > limit then
      local so = vim.wo[win].scrolloff
      vim.wo[win].scrolloff = 0
      vim.cmd("keepjumps normal! Gzb")
      vim.wo[win].scrolloff = so
    end
  end)
  clamping = false
end

-- Test seam: drive the over-scroll clamp directly in the headless spec.
mod._clamp_scroll = clamp_scroll
mod._SCROLL_TAIL  = SCROLL_TAIL

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

  -- Pin the panel width so growing the OS/terminal window adds columns to the
  -- editor (the non-fixed window), not the panel. Without this the rightmost
  -- window absorbs the extra width and the Claude panel balloons on resize.
  vim.wo[win].winfixwidth = true

  -- Panel background = ClaudeNormal (CursorLine-derived gray) so the whole Claude
  -- column reads as one flush surface with the chat bar.
  vim.wo[win].winhighlight = PANEL_HL_BASE

  -- Hide end-of-buffer "~" filler lines. The panel is an output surface; the
  -- tildes below the content add visual noise and imply empty-file semantics.
  vim.wo[win].fillchars = "eob: "

  -- Disable cursorline in the panel. It's a read-only output surface, and the
  -- global cursorline=true otherwise paints a gray strip across whatever row the
  -- cursor rests on (e.g. the banner separator) — that strip is the "orange line
  -- background not flush" artifact. Off here, every row shares the panel bg.
  vim.wo[win].cursorline = false

  -- Panel is a read-only output surface — line numbers add noise and imply an
  -- editable file. Disable both absolute and relative numbers in this window.
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false

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

  -- Cap over-scroll so the conversation can't be flung off the top of the window
  -- (catches mouse wheel + keys + jumps). See clamp_scroll for the math.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      clamp_scroll()
    end,
  })

  -- Hide the cursor while the panel is focused. guicursor is global so we save on
  -- WinEnter and restore on WinLeave. winhighlight cannot override Cursor/CursorNC —
  -- guicursor is the only per-focus API. We also stash the real (visible) guicursor
  -- in module state so the chat bar can explicitly restore it on open rather than
  -- depending on the WinLeave→restore race, which left the cursor invisible while
  -- typing if _saved_gc had already been consumed.
  local function remember_real_gc()
    if vim.o.guicursor ~= "a:block-ClaudeCursorHidden" then
      state.real_guicursor = vim.o.guicursor
    end
  end
  local _saved_gc = nil
  vim.api.nvim_create_autocmd("WinEnter", {
    group  = grp,
    buffer = buf,
    callback = function()
      if vim.o.guicursor ~= "a:block-ClaudeCursorHidden" then
        _saved_gc = vim.o.guicursor
      end
      remember_real_gc()
      vim.o.guicursor = "a:block-ClaudeCursorHidden"
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
  vim.o.guicursor = "a:block-ClaudeCursorHidden"


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

--- Toggle Plan mode for the panel session (`<leader>cp`).
-- Plan mode is the --permission-mode plan flag (read-only planning; no edits).
-- Like the model, it's spawn-time, so toggling respawns; context resets.
function mod.toggle_plan()
  state.permission_mode = (state.permission_mode == "plan") and "acceptEdits" or "plan"
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

--- Called by claude_diff when a vimdiff opens — locks the input bar.
-- The user must accept or reject the proposed edit before sending another
-- message; allowing a follow-up while the file is in-diff risks confusing
-- Claude with a half-applied change still on disk.
function mod.on_diff_open()
  state.diff_pending = true
  set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
end

--- Called by claude_diff when the current diff is resolved — unlocks input.
function mod.on_diff_close()
  state.diff_pending = false
  if not state.working then
    clear_hint()
    -- Review done: release any messages queued during the diff.
    mod._maybe_send_next()
  end
end

return mod
