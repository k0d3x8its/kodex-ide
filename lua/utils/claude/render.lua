-- lua/utils/claude/render.lua
--
-- The transcript renderers + the stream-json event dispatcher. Everything that
-- turns a parsed CLI event into painted panel-buffer lines lives here: prose /
-- user-echo / thinking-fold renderers, the cornered ●/└ tool block, the collapsed
-- tool_result foundation (build_collapsed/build_expanded/apply_line_hls + the
-- <C-o> expand toggle), the search-block renderers, the turn "done" line, and the
-- `dispatch(event)` router that fans events out to all of them. Extracted from the
-- former monolithic claude.lua (Goal 15.7 — the last extraction) to bring init's
-- main chunk under the 200-local ceiling and below 2000 lines.
--
-- Single-module cut (render + dispatch together, not split into a dispatch.lua
-- sibling): dispatch and the render_* branch targets it calls are mutually
-- recursive and share the tool_result foundation + the search-block state, so a
-- split would force a bidirectional require or a fat wire surface between the two
-- files. One module leaves the fewest cross-requires — the plan's stated
-- tie-breaker. (Decision recorded for review.)
--
-- Dependencies: core (state + buffer/hl primitives) + markdown (build_md_lines/
-- render_code_block/is_fence/disp_take) + widgets (task-plan + search classifier)
-- + gate (permission card / pre-write gate / EDIT_TOOLS) + question (AskUserQuestion
-- card) all come from direct requires; claude_diff is required inline at the three
-- watch/poll bridge sites (verbatim from the pre-move code). Ten init-owned helpers
-- couple to init's spinner/hint/typing-placeholder/pad/banner machinery (which
-- stays in init because it holds timers / touches window management) and are
-- injected via Render.wire{} at load time.
--
-- Init re-sources dispatch + render_user back out (into process.wire{}, so the
-- subprocess module keeps feeding on_stdout events here) and re-exports
-- mod.expand_result / mod._foldtext (the <C-o> keymap + the window foldtext expr).

local Render = {}

local require_prefix = "utils.claude."
local core     = require(require_prefix .. "core")
local markdown  = require(require_prefix .. "markdown")
local widgets  = require(require_prefix .. "widgets")
local gate     = require(require_prefix .. "gate")
local question = require(require_prefix .. "question")

local state       = core.state
local buf_append  = core.buf_append
local hl_lines    = core.hl_lines
local hl_range    = core.hl_range
local sep_line    = core.sep_line
local panel_width = core.panel_width

local build_md_lines    = markdown.build_md_lines
local render_code_block = markdown.render_code_block
local is_fence          = markdown.is_fence
local disp_take         = markdown.disp_take

-- Init-owned helpers, injected by Render.wire{} at load time (see init.lua).
-- Declared as forward locals so the render functions below close over them.
local set_hint            -- eol randomizer / awaiting-review hint
local clear_hint
local stop_spinner        -- turn-end teardown of the braille spinner + timer
local remove_typing_ph    -- drop the in-body "typing" placeholder before a render
local reanchor_pad        -- re-pin the last line above a reserved pad after a height change
local friendly_model      -- model id/alias → display name (shared with init's picker)
local fmt_think_dur       -- ms → "3.2s" / "1m 04s"
local FLAVOR_DONE         -- past-tense flavour words for the turn "done" line
local maybe_send_next     -- drain one type-ahead queue item after a turn ends
local patch_banner        -- fill the banner's version/model lines on system/init
-- Clawd pet event sink (init injects pet.emit). nil = pet disabled → no-op, so
-- dispatch never hard-couples to the pet. Every emit is guarded `if pet_emit`.
local pet_emit

--- Inject init's spinner/hint/pad/banner helpers + the FLAVOR_DONE table. Called
--- once from init after those are defined. maybe_send_next comes from the process
--- module (init passes process.maybe_send_next through); patch_banner keeps the
--- BANNER_* constants + banner buffer-patching in init with the rest of the banner.
function Render.wire(hooks)
  set_hint         = hooks.set_hint
  clear_hint       = hooks.clear_hint
  stop_spinner     = hooks.stop_spinner
  remove_typing_ph = hooks.remove_typing_ph
  reanchor_pad     = hooks.reanchor_pad
  friendly_model   = hooks.friendly_model
  fmt_think_dur    = hooks.fmt_think_dur
  FLAVOR_DONE      = hooks.FLAVOR_DONE
  maybe_send_next  = hooks.maybe_send_next
  patch_banner     = hooks.patch_banner
  pet_emit         = hooks.pet_emit
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
    or input.url                                          -- WebFetch target
    or (input.command and tostring(input.command):sub(1, 70))
    or ""
  -- This value renders as ONE line (the "⚙ Verb: target" entry). A multi-line
  -- command/query (e.g. a Bash heredoc, or a `find … \n …`) keeps its newline
  -- through the :sub() truncation, and nvim_buf_set_lines REJECTS any item with an
  -- embedded newline → render_tool crashes the whole dispatch (hit on a Bash tool
  -- whose command spanned lines). Collapse all vertical whitespace to spaces here.
  return (t:gsub("[\r\n\t]+", " "))
end

-- A stream-json message.content is USUALLY a block array, but some events carry it
-- as a plain STRING — notably the summary injected after /compact (manual OR auto).
-- Every dispatch loop below iterates the blocks, so a raw string there crashed the
-- whole dispatch with "bad argument #1 to 'ipairs' (table expected, got string)"
-- (2026-07-13, on the compact summary). Normalize once: a string becomes a single
-- text block; nil/other becomes empty. Callers that only care about tool_result
-- blocks simply find none in a text block (correct — a compact summary is context,
-- not a tool result, and must not render inline).
local function content_blocks(message)
  local c = (message or {}).content
  if type(c) == "table" then return c end
  if type(c) == "string" and c ~= "" then return { { type = "text", text = c } } end
  return {}
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

-- note (optional): the ~-relative path of a file whose context was attached to
-- the WIRE this turn (open-buffer awareness v2). When set, a dim "· with @<file>"
-- line is drawn under the echo so the ambient injection is visible to the user.
local function render_user(text, note)
  if not text or text == "" then return end
  -- Draw the turn separator at the TOP of this turn (above the echo), unless a
  -- separator already sits there (banner divider on the first turn). Responses
  -- no longer end with a trailing divider — the next turn's top one divides them.
  if not last_line_is_sep() then
    local sep_at = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ sep_line() })
    hl_lines(sep_at, sep_at, "ClaudeHeader")
  end
  -- Fence-aware echo: prose lines get the ❯ arrow (first) / 2-space indent and
  -- ClaudeUser; a ```lang fenced block (e.g. the selection from <leader>cq)
  -- renders as a real syntax-highlighted code block via render_code_block, so
  -- the user's own submitted code reads the same as Claude's code blocks — not
  -- literal backticks. Only fences are special-cased; a plain message with no
  -- fence renders exactly as before.
  local raw = vim.split(text, "\n", { plain = true })
  local idx, prose_row = 1, 0
  while idx <= #raw do
    local line = raw[idx]
    if is_fence(line) then
      local lang = line:match("^%s*```%s*(%S*)") or ""
      local body, j = {}, idx + 1
      while j <= #raw and not is_fence(raw[j]) do
        body[#body + 1] = raw[j]; j = j + 1
      end
      local clean, hls = render_code_block(lang, body)
      local cfirst = vim.api.nvim_buf_line_count(state.panel_buf)
      buf_append(clean)
      for li = 1, #clean do
        local ln = cfirst + li - 1
        for _, h in ipairs(hls[li]) do hl_range(ln, h[1], h[2], h[3]) end
      end
      idx = (j <= #raw) and j + 1 or j          -- skip the closing fence
    else
      prose_row = prose_row + 1
      local disp = (prose_row == 1 and USER_ARROW or "  ") .. line
      local ln   = vim.api.nvim_buf_line_count(state.panel_buf)
      buf_append({ disp })
      hl_lines(ln, ln, "ClaudeUser")
      -- Paint just the arrow glyph terminal-green so it reads like a shell
      -- prompt and matches the input bar's arrow.
      if prose_row == 1 then hl_range(ln, 0, #USER_ARROW, "ClaudeArrow") end
      idx = idx + 1
    end
  end
  -- Open-buffer awareness v2 (c): a dim note showing which file's context rode
  -- along on the wire this turn. Indented to sit under the prose echo.
  if note and note ~= "" then
    local ln = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ "  · with @" .. note })
    hl_lines(ln, ln, "ClaudeDim")
  end
end
Render.render_user = render_user

-- Foldtext for a collapsed thinking block. The buffer's first fold line is the
-- literal "▼ Thought" header (only shown when expanded); when collapsed Neovim
-- shows THIS instead — a "▶ Thought · <time>" row, so the
-- arrow flips ▼→▶ to signal the closed state. Used for every panel fold, but only
-- thinking blocks create folds. Exposed on mod so the window's foldtext expr
-- (`v:lua.require('utils.claude')._foldtext()`) can reach it.
function Render._foldtext()
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
  -- start. Shown only when the fold is expanded; collapsed shows Render._foldtext.
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
  -- Guard on panel_win ALSO showing panel_buf (same guard used at the other
  -- fold/extmark sites): if a diff transiently swapped the panel window's buffer, folding line
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

-- Devicon glyph for a path, as " <glyph>" (leading space) so callers concat it
-- straight AFTER the name — the glyph always trails the filename wherever a path
-- is shown. "" when nvim-web-devicons is absent (no nerd font) so the panel still
-- renders without it — and so headless tests see plain text.
local function file_glyph(path)
  if not path or path == "" then return "" end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return "" end
  local icon = devicons.get_icon(
    vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
  return icon and (" " .. icon) or ""
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
-- Source-line count of a Write's content (trailing newline doesn't count as a
-- line), matching what render_write_body actually lists.
local function content_line_count(s)
  local lines = vim.split(tostring(s or ""), "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then return #lines - 1 end
  return #lines
end

local function tool_lines(name, input)
  local path = input.file_path or input.path
  if name == "Write" then
    -- Write gets its own header (CC-TUI shape) + a "Wrote N lines to <path>" corner;
    -- the written content renders as a numbered, collapsible body (render_write_body).
    local rel = rel_path(path)
    local n = content_line_count(input.content)
    return "● Write " .. rel .. file_glyph(path),
           string.format("Wrote %d %s to %s", n, n == 1 and "line" or "lines", rel)
  elseif EDIT_NAMES[name] then
    local a, r = edit_counts(name, input)
    return "● Editing " .. vim.fn.fnamemodify(path or "", ":t") .. file_glyph(path),
           change_summary(a, r)
  elseif name == "Read" or name == "NotebookRead" then
    return "● Reading 1 file", rel_path(path) .. file_glyph(path)
  elseif name == "Bash" then
    -- .sh devicon after "bash" for the shell glyph the user asked for.
    return "● Running bash" .. file_glyph("run.sh"), corner_one_line(input.command)
  elseif name == "Grep" then
    return "● Searching", corner_one_line(input.pattern)
      .. (input.path and ("  ·  " .. rel_path(input.path)) or "")
  elseif name == "Glob" then
    return "● Listing", corner_one_line(input.pattern)
  elseif name == "Skill" then
    -- Name the skill in the header (CC-TUI shape); the "Successfully loaded
    -- skill …" result body renders via the shared tool_result-body foundation.
    local skill = input.skill or input.name or input.command
    return "● Skill(" .. corner_one_line(skill or "") .. ")", nil
  elseif name == "Task" or name == "Agent" then
    -- Subagent spawn (headless build names the tool "Agent"; classic CC "Task").
    -- Header brands the subagent "neoclaude" + its short description, matching the
    -- CC-TUI's "● <agent>(<desc>)" shape (their "claude" → our "neoclaude"). Inner
    -- activity nests below (compact + capped, render_subagent_inline); the full
    -- transcript is in the drill-in view (ctrl+b to cycle).
    local desc = input.description or input.subagent_type or "subagent"
    return "● neoclaude(" .. corner_one_line(desc) .. ")", nil
  elseif name == "Artifact" then
    -- Published-artifact tool: the target (file_path, or a URL on an update/list)
    -- rides the header in CC-TUI "● Artifact(<target>)" shape. The "published · <url>"
    -- confirmation arrives with the RESULT, rendered by render_artifact_result.
    local tgt = (path and rel_path(path)) or input.url or ""
    return "● Artifact" .. (tgt ~= "" and ("(" .. tgt .. ")") or ""), nil
  elseif name == "ExitPlanMode" then
    -- The proposed plan rides the tool INPUT (input.plan), not the result body;
    -- render a clean "● Plan" header + a one-line preview (the full plan text also
    -- lands in the model's surrounding prose, so we don't multi-line it here).
    return "● Plan", corner_one_line(input.plan or "")
  end
  -- MCP tools arrive as `mcp__<server>__<tool>`. Render them Skill-style: the SHORT
  -- tool name wrapped in `● MCP(<tool>)` (server prefix dropped — it's noise at a
  -- glance), with the `└` corner pointing at the one-line JSON of the call params.
  -- The MCP server's response still renders as the body via the tool_result
  -- foundation. (`<tool>` = the last `__`-delimited segment; the server may itself
  -- contain single underscores, so we split on the double-underscore separator.)
  if not TOOL_VERB[name] and name:match("^mcp__") then
    local rest = name:gsub("^mcp__", "")
    local tool = rest:match(".*__(.-)$") or rest
    local params
    if next(input) ~= nil then
      local ok, js = pcall(vim.fn.json_encode, input)
      if ok then params = corner_one_line(js) end
    end
    return "● MCP(" .. corner_one_line(tool) .. ")", params
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

-- ── Post-approval edit hunk (Goal 14.4) ──────────────────────────────────────
-- After an edit is ACCEPTED, drop a numbered red/green diff block into the
-- transcript — a scannable record of what changed, mirroring the Claude Code
-- TUI. Purely ADDITIVE: the vimdiff review surface is unchanged; this only
-- appends to the panel. old_lines/new_lines are the before/after buffer contents
-- captured by claude_diff at accept time (orig_buf vs scratch). vim.diff's
-- unified output gives grouping, context, and real line numbers for free.
local HUNK_CTX = 3    -- context lines each side of a change (user spec)
local HUNK_CAP = 40   -- max changed (+/-) lines before the rest collapses to "…"

-- The ClaudeCode* token groups bake in the code-block bg (#21222C); applied over
-- the red/green hunk bands they'd punch near-black holes on every token cell. So
-- we derive an fg-ONLY twin per group (same fg/italic/bold, NO bg) on first use —
-- the band bg then shows through under the coloured token, matching the real
-- Claude Code TUI. Cached to skip the derivation on every render.
--
-- Staleness IS a hazard: the twins live in namespace 0, so a `:colorscheme` (which
-- runs `:highlight clear`) WIPES them. The plugin's ColorScheme autocmd re-creates
-- the base ClaudeCode* groups but not these derived twins — so without cache
-- invalidation the next render reuses a cached twin NAME pointing at a now-empty
-- group, and the token renders in the default fg (no visible syntax colour). The
-- ColorScheme autocmd therefore calls reset_hunk_fg_cache() so the twins re-derive
-- from the freshly-restored base groups on the next render.
local hunk_fg_cache = {}
local function hunk_fg_group(group)
  local twin = hunk_fg_cache[group]
  if twin then return twin end
  twin = group .. "Fg"
  local hl = vim.api.nvim_get_hl(0, { name = group })
  vim.api.nvim_set_hl(0, twin, { fg = hl.fg, italic = hl.italic, bold = hl.bold })
  hunk_fg_cache[group] = twin
  return twin
end

-- Drop every derived fg-only twin so the next hunk_fg_group() re-derives it from
-- the current base group. Called from the ColorScheme autocmd (plugins/claude.lua)
-- after define_highlights() restores the base ClaudeCode* palette — a :colorscheme
-- clears ns-0 groups, and a cached twin name would otherwise point at an empty
-- (wiped) group forever. Mutated in place so the hunk_fg_group upvalue stays bound.
local function reset_hunk_fg_cache()
  for k in pairs(hunk_fg_cache) do hunk_fg_cache[k] = nil end
end
Render.reset_hunk_fg_cache = reset_hunk_fg_cache
Render._hunk_fg_group = hunk_fg_group   -- exposed for the regression spec (S21)

local function render_edit_hunk(path, old_lines, new_lines)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local old_text = table.concat(old_lines or {}, "\n")
  local new_text = table.concat(new_lines or {}, "\n")
  if old_text == new_text then return end
  local ud = vim.diff(old_text, new_text, { ctxlen = HUNK_CTX, result_type = "unified" })
  if not ud or ud == "" then return end

  -- Treesitter token runs for each side, keyed by that side's line number. Added
  -- + context rows colour from the NEW content, deleted rows from the OLD. `lang`
  -- = the target's filetype (lua/python/…); code_ts_hls maps it to a parser and
  -- returns nil (→ no syntax, plain text) when none is available. pcall-guarded.
  local lang = (path and path ~= "" and vim.filetype.match({ filename = path })) or ""
  local ok_n, syn_new = pcall(markdown.code_ts_hls, lang, new_lines or {})
  local ok_o, syn_old = pcall(markdown.code_ts_hls, lang, old_lines or {})
  if not ok_n then syn_new = nil end
  if not ok_o then syn_old = nil end

  -- Parse the unified diff into typed rows, tracking real line numbers off each
  -- @@ header. Deleted rows carry the OLD number; added/context carry the NEW.
  -- Once HUNK_CAP changed lines are shown, further +/- are counted into `dropped`
  -- (rendered as a single collapse line) and context is stopped.
  local rows, oldno, newno, changed, dropped = {}, nil, nil, 0, 0
  for _, dl in ipairs(vim.split(ud, "\n", { plain = true })) do
    local ho, hn = dl:match("^@@ %-(%d+),?%d* %+(%d+)")
    if ho then
      oldno, newno = tonumber(ho), tonumber(hn)
      if #rows > 0 then rows[#rows + 1] = { kind = "gap" } end  -- ⋮ between groups
    elseif oldno then
      local sign = dl:sub(1, 1)
      if sign == "+" then
        if changed < HUNK_CAP then rows[#rows + 1] = { kind = "add", num = newno, text = dl:sub(2) }; changed = changed + 1
        else dropped = dropped + 1 end
        newno = newno + 1
      elseif sign == "-" then
        if changed < HUNK_CAP then rows[#rows + 1] = { kind = "del", num = oldno, text = dl:sub(2) }; changed = changed + 1
        else dropped = dropped + 1 end
        oldno = oldno + 1
      elseif sign == " " then
        if changed < HUNK_CAP then rows[#rows + 1] = { kind = "ctx", num = newno, text = dl:sub(2) } end
        oldno = oldno + 1; newno = newno + 1
      end
      -- sign "\" ("\ No newline at end of file") falls through — ignored.
    end
  end
  if #rows == 0 then return end
  if dropped > 0 then rows[#rows + 1] = { kind = "more", n = dropped } end

  -- Gutter width = widest line number actually shown (min 3 for alignment).
  local maxnum = 1
  for _, r in ipairs(rows) do if r.num and r.num > maxnum then maxnum = r.num end end
  local gw   = math.max(#tostring(maxnum), 3)
  local pad  = string.rep(" ", gw)
  local ind  = "    "                          -- indent so the hunk nests UNDER the ● Editing / └ block (TUI-style)
  local ind_b    = #ind
  local prefix_b = ind_b + gw + 3              -- indent + "<num> <sign> " = code start byte col
  local cw   = math.max(panel_width() - prefix_b - 1, 8)   -- code width before HARD wrap

  -- Flatten rows → display lines. A code row wider than `cw` is HARD-WRAPPED into
  -- chunks here (not left to Vim's soft wrap) so EACH screen row keeps its own
  -- gutter + band + clipped syntax; a soft-wrapped continuation would otherwise
  -- render bare — no gutter, broken band, stray ↪ (same fix as render_code_block).
  -- Continuation chunks carry a blank gutter so the code stays column-aligned.
  local disp = {}   -- { text=, band=hlgroup|nil, dim_gutter=bool, sep=bool, spans={{b0,b1,grp}} }
  for _, r in ipairs(rows) do
    if r.kind == "gap" then
      disp[#disp + 1] = { text = ind .. pad .. " ⋮", sep = true }
    elseif r.kind == "more" then
      disp[#disp + 1] = { text = ind .. pad .. "   … +" .. r.n .. " more changed line"
        .. (r.n == 1 and "" or "s"), sep = true }
    else
      local sign = (r.kind == "add" and "+") or (r.kind == "del" and "-") or " "
      local head = ind .. string.format("%" .. gw .. "d %s ", r.num, sign)  -- prefix_b bytes total
      local band = (r.kind == "add" and "ClaudeHunkAdd")
        or (r.kind == "del" and "ClaudeHunkDel") or nil
      local numhl = (r.kind == "add" and "ClaudeHunkNumAdd")
        or (r.kind == "del" and "ClaudeHunkNumDel") or "ClaudeDim"
      local syn  = (r.kind == "del") and syn_old or syn_new
      local runs = syn and r.num and syn[r.num] or nil
      local rest, boff, firstrow = r.text, 0, true
      repeat
        local chunk = (rest == "") and "" or disp_take(rest, cw)
        local clen  = #chunk
        local spans = {}
        if runs then                            -- clip each token run to this chunk's byte span
          for _, s in ipairs(runs) do
            local cs = math.max(s[1], boff)
            local ce = math.min(s[2], boff + clen)
            if ce > cs then
              spans[#spans + 1] = { prefix_b + (cs - boff), prefix_b + (ce - boff), s[3] }
            end
          end
        end
        disp[#disp + 1] = {
          text       = (firstrow and head or string.rep(" ", prefix_b)) .. chunk,
          band       = band,
          dim_gutter = firstrow,               -- only the first chunk shows the number
          numhl      = numhl,                  -- gutter colour: green add / red del / dim ctx
          spans      = spans,
        }
        rest, boff, firstrow = rest:sub(clen + 1), boff + clen, false
      until rest == ""
    end
  end

  -- Sit flush under the ● Editing / └ block: drop any trailing blank rows first
  -- (render_tool leaves a randomizer blank below the corner) so there's no gap
  -- between the header and the hunk.
  local lc = vim.api.nvim_buf_line_count(buf)
  while lc > 0 and (vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)[1] or "") == "" do
    local was = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, lc - 1, lc, false, {})
    vim.bo[buf].modifiable = was
    lc = lc - 1
  end

  local first, texts = vim.api.nvim_buf_line_count(buf), {}
  for i, d in ipairs(disp) do texts[i] = d.text end
  buf_append(texts)

  -- Highlight: full-line bg band for add/del (line_hl_group fills the EOL gap to
  -- the window edge); dim the line-number gutter on the first chunk; dim the ⋮
  -- separators / collapse line; fg-only treesitter tokens over the code.
  state.hunk_ns = state.hunk_ns or vim.api.nvim_create_namespace("ClaudeHunk")
  for i, d in ipairs(disp) do
    local ln = first + i - 1
    if d.band then
      vim.api.nvim_buf_set_extmark(buf, state.hunk_ns, ln, 0, { line_hl_group = d.band })
    end
    if d.sep then
      hl_lines(ln, ln, "ClaudeDim")
    else
      if d.dim_gutter then hl_range(ln, ind_b, ind_b + gw, d.numhl or "ClaudeDim") end
      for _, sp in ipairs(d.spans) do
        hl_range(ln, sp[1], sp[2], hunk_fg_group(sp[3]))
      end
    end
  end
  buf_append({ "" })   -- trailing blank so the next content/spinner anchors below
end
Render.render_edit_hunk = render_edit_hunk

-- Normalise a tool_result `content` field to a flat list of display lines.
-- The CLI sends `content` as either a plain STRING (the common case, e.g.
-- "1\n2\n…") or an array of `{type="text",text=…}` blocks. Tabs → two spaces
-- (nvim_buf_set_lines forbids raw tabs in some widths and they render ragged).
-- Blank/whitespace-only lines are DROPPED so the glance-preview stays dense —
-- a Read result's separator blank (e.g. after a <system-reminder> banner) would
-- otherwise open a gap; numbered `cat -n` lines survive (they carry the number).
local function tool_result_lines(content)
  local s
  if type(content) == "string" then
    s = content
  elseif type(content) == "table" then
    local parts = {}
    for _, c in ipairs(content) do
      if type(c) == "table" and (c.type == "text") then
        parts[#parts + 1] = c.text or ""
      elseif type(c) == "string" then
        parts[#parts + 1] = c
      end
    end
    s = table.concat(parts, "\n")
  else
    s = ""
  end
  s = tostring(s):gsub("\t", "  ")
  local lines = {}
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    if not l:match("^%s*$") then lines[#lines + 1] = l end
  end
  return lines
end

-- Visible body lines before a tool_result is collapsed behind the expand
-- affordance. Kept small so a big Read/Bash result is a preview, not a dump.
local RESULT_HEAD_K = 5

-- Strip a `cat -n` leading line number ("    12  code" → "code") so a Read body
-- parses cleanly as source when rendered through the code-block renderer.
local function strip_line_numbers(body)
  local out = {}
  for i, l in ipairs(body) do out[i] = (l:gsub("^%s*%d+%s+", "")) end
  return out
end

-- Corner + continuation prefixes for a rendered tool_result body.
local RES_CORNER, RES_INDENT = "  └ ", "    "

-- Content lines shown in a Write body before it collapses to a "… +N" affordance.
local WRITE_HEAD_K = 10

-- Build the numbered, indented, syntax-highlighted body for a Write's content
-- (entry.code_lines / entry.lang). `limit` caps how many source lines render (nil
-- = all, for the expanded view). Returns (lines, hls) in apply_line_hls span
-- format: a dim right-aligned line-number gutter + fg-ONLY treesitter token spans
-- over the code (fg-only via hunk_fg_group so the code-block bg doesn't punch a
-- dark box through the panel). Long lines hard-wrap into gutter-blank rows so each
-- screen row keeps its own number + clipped syntax (same discipline as the hunk).
local function write_body_lines(entry, limit)
  local code  = entry.code_lines
  local total = #code
  local shown = limit and math.min(limit, total) or total
  local ok, syn = pcall(markdown.code_ts_hls, entry.lang or "", code)
  if not ok then syn = nil end

  local gw   = math.max(#tostring(total), 2)
  local ind  = "    "
  local prefix_b = #ind + gw + 2                 -- indent + number + 2 spaces = code start col
  local cw   = math.max(panel_width() - prefix_b - 1, 8)

  local lines, hls = {}, {}
  for i = 1, shown do
    local runs = syn and syn[i] or nil
    local head = ind .. string.format("%" .. gw .. "d  ", i)   -- exactly prefix_b bytes
    local rest, boff, firstrow = code[i], 0, true
    repeat
      local chunk = (rest == "") and "" or disp_take(rest, cw)
      local clen  = #chunk
      local spans = {}
      if firstrow then spans[#spans + 1] = { #ind, #ind + gw, "ClaudeDim" } end  -- gutter number
      if runs then                                -- clip each token run to this chunk's byte span
        for _, s in ipairs(runs) do
          local cs = math.max(s[1], boff)
          local ce = math.min(s[2], boff + clen)
          if ce > cs then
            spans[#spans + 1] = { prefix_b + (cs - boff), prefix_b + (ce - boff), hunk_fg_group(s[3]) }
          end
        end
      end
      lines[#lines + 1] = (firstrow and head or string.rep(" ", prefix_b)) .. chunk
      hls[#hls + 1]     = spans
      rest, boff, firstrow = rest:sub(clen + 1), boff + clen, false
    until rest == ""
  end
  if limit and total > shown then
    local hidden = total - shown
    lines[#lines + 1] = string.format("%s… +%d %s (ctrl+o to expand)",
      RES_INDENT, hidden, hidden == 1 and "line" or "lines")
    hls[#hls + 1] = { { 0, -1, "ClaudeDim" } }
  end
  return lines, hls
end

-- Greedy display-width word-wrap: split `s` into rows no wider than `width` cells.
-- A single word longer than width is hard-split via disp_take so it never overflows.
-- Used for the advisor summary so the whole sentence reads instead of clipping.
local function wrap_disp(s, width)
  local rows, line = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if line == "" then
      line = word
    elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
      line = line .. " " .. word
    else
      rows[#rows + 1] = line; line = word
    end
    while vim.fn.strdisplaywidth(line) > width do   -- lone over-long word: hard-split
      rows[#rows + 1] = disp_take(line, width)
      line = line:sub(#disp_take(line, width) + 1)
    end
  end
  if line ~= "" then rows[#rows + 1] = line end
  return rows
end

-- Build the COLLAPSED preview: first K one-row-truncated lines off a dim `└`
-- corner + a dim "… +N lines (ctrl+o to expand)" affordance on overflow.
-- Returns (lines, line_hls) where line_hls[i] = list of {b0, b1, group}.
local function build_collapsed(entry)
  if entry.kind == "write" then return write_body_lines(entry, WRITE_HEAD_K) end
  -- Advisor-style summary collapse: the advice body is prose (a few VERY long
  -- paragraph-lines), so a first-K preview would clip each paragraph to one row
  -- with `…` and — when the body is ≤ RESULT_HEAD_K lines — leave no expand
  -- affordance (dead ctrl+o). Instead collapse to a fixed one-line summary + a
  -- green ✔, always expandable, mirroring the CC TUI's advisor block.
  if entry.summary then
    local avail = math.max(panel_width() - 6, 20)
    local ck    = #"✔"                             -- byte width of the check glyph
    -- Word-wrap the whole sentence + the expand affordance as one run, so the
    -- "(ctrl+o to expand)" rides the last summary row instead of a line of its own
    -- (clipping to one row hid the tail). ✔ leads row 1 (green); continuations hang
    -- at the indent, all dim.
    local rows  = wrap_disp("✔ " .. entry.summary .. "  (ctrl+o to expand)", avail)
    local lines, hls = {}, {}
    for i, r in ipairs(rows) do
      local corner = (i == 1)
      lines[i] = (corner and RES_CORNER or RES_INDENT) .. r
      hls[i]   = corner
        and { { 0, #RES_CORNER, "ClaudeDim" },                       -- dim corner
              { #RES_CORNER, #RES_CORNER + ck, "ClaudeAdvisor" },    -- green ✔
              { #RES_CORNER + ck, -1, "ClaudeDim" } }                -- dim text
        or  { { 0, -1, "ClaudeDim" } }                               -- dim continuation
    end
    return lines, hls
  end
  local group   = entry.is_error and "ClaudeError" or "ClaudeDim"
  local n_shown = math.min(#entry.body, RESULT_HEAD_K)
  local hidden  = #entry.body - n_shown
  local avail   = math.max(panel_width() - 6, 20)   -- wrap budget after the prefix
  -- Word-wrap each previewed line (rather than clipping to one row with `…`) so a
  -- tool result reads in full — the whole point of a preview. A ROW_BUDGET caps the
  -- total display rows so a single very wide line (e.g. a <system-reminder> banner)
  -- can't balloon the collapsed block: once the budget is hit, the remaining logical
  -- lines fold into the "… +N lines" affordance below.
  local ROW_BUDGET = 10
  local lines, hls = {}, {}
  for i = 1, n_shown do
    if #lines >= ROW_BUDGET then hidden = #entry.body - (i - 1); break end
    local clean = tostring(entry.body[i]):gsub("[\r\n\t]+", " ")
    for ri, r in ipairs(wrap_disp(clean, avail)) do
      -- corner_each: every logical line gets its own `└` (a file list reads best that
      -- way); otherwise only the first line is cornered. Wrapped continuation rows
      -- (ri > 1) always hang at the indent, never re-cornered.
      local corner = ri == 1 and (i == 1 or entry.corner_each)
      lines[#lines + 1] = (corner and RES_CORNER or RES_INDENT) .. r
      hls[#lines]       = corner
        and { { 0, #RES_CORNER, "ClaudeDim" }, { #RES_CORNER, -1, group } }
        or  { { 0, -1, group } }
    end
  end
  if hidden > 0 then
    lines[#lines + 1] = string.format("%s… +%d %s (ctrl+o to expand)",
      RES_INDENT, hidden, hidden == 1 and "line" or "lines")
    hls[#hls + 1] = { { 0, -1, "ClaudeDim" } }
  end
  return lines, hls
end

-- Build the EXPANDED view: a ▎-gutter syntax-highlighted code block when the
-- source was a Read of a known filetype (entry.lang set), else the full body off
-- the dim corner (un-truncated; wrapping is fine — the user asked to see it all).
local function build_expanded(entry)
  if entry.kind == "write" then return write_body_lines(entry, nil) end
  if entry.lang then
    return render_code_block(entry.lang, entry.code_body)
  end
  local group = entry.is_error and "ClaudeError" or "ClaudeDim"
  local lines, hls = {}, {}
  for i, l in ipairs(entry.body) do
    local corner = (i == 1 or entry.corner_each)
    lines[i] = (corner and RES_CORNER or RES_INDENT) .. l
    hls[i]   = corner
      and { { 0, #RES_CORNER, "ClaudeDim" }, { #RES_CORNER, -1, group } }
      or  { { 0, -1, group } }
  end
  return lines, hls
end

-- Apply per-line hl span lists (from build_*/render_code_block) starting at the
-- 0-indexed buffer line `s`.
local function apply_line_hls(buf, s, hls)
  for i, spans in ipairs(hls) do
    for _, h in ipairs(spans) do
      vim.api.nvim_buf_add_highlight(buf, -1, h[3], s + i - 1, h[1], h[2])
    end
  end
end

-- Derive code metadata for a tool_result from its originating tool_use (matched
-- by tool_use_id upstream). Only a Read of a filetype-matchable file becomes
-- "code"; returns (lang, stripped_body) or (nil, nil).
local function result_code_meta(meta, body)
  if not (meta and meta.path) then return nil, nil end
  if meta.name ~= "Read" and meta.name ~= "NotebookRead" then return nil, nil end
  local ft = vim.filetype.match({ filename = meta.path })
  if not ft or ft == "" then return nil, nil end
  return ft, strip_line_numbers(body)
end

-- Render a tool_result body under its tool block as the collapsed preview, and
-- stash it on state.tool_results for the <C-o> toggle. `meta` is the originating
-- tool_use {name,path} — a Read result renders as a syntax-highlighted code block
-- when expanded. Shared foundation for the skill-result / error / search features.
local function render_tool_result(content, is_error, meta, opts)
  local body = tool_result_lines(content)
  if #body == 0 then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  state.tool_result_ns = state.tool_result_ns
    or vim.api.nvim_create_namespace("claude_tool_result")
  state.tool_results = state.tool_results or {}

  -- The running tool block left a trailing blank (the eol randomizer's row); drop
  -- it so the result attaches DIRECTLY under the `└ <command>` line with no gap,
  -- matching the CC TUI. set_hint re-anchors the randomizer on the next tick.
  local last = vim.api.nvim_buf_line_count(buf)
  if last > 0 and vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] == "" then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, {})
    vim.bo[buf].modifiable = false
  end

  local lang, code_body = result_code_meta(meta, body)
  local entry = {
    body       = body,                    -- full, unindented lines
    is_error   = is_error,
    lang       = lang,                    -- filetype for the expanded code block (or nil)
    code_body  = code_body,               -- line-number-stripped body for code render
    -- toggleable normally means vertical overflow (> K lines). always_toggle forces
    -- it for prose blocks (advisor) whose few long lines would otherwise clip with no
    -- expand escape. summary, when set, drives the one-line collapsed view above.
    toggleable = (#body > RESULT_HEAD_K) or (opts and opts.always_toggle) or false,
    summary    = opts and opts.summary,
    expanded   = false,
  }

  local lines, hls = build_collapsed(entry)
  local first = vim.api.nvim_buf_line_count(buf)
  buf_append(lines)
  apply_line_hls(buf, first, hls)
  -- Start/end extmarks bound the block's line range across later appends so the
  -- <C-o> toggle can locate and replace it in place.
  entry.start_mark = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns, first, 0, {})
  entry.end_mark   = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns,
    first + #lines - 1, 0, {})

  buf_append({ "" })   -- trailing blank so the eol randomizer / next block clears the body
  state.tool_results[#state.tool_results + 1] = entry
end

-- The Claude Code Artifact tool has two actions, BOTH URL-centric — there is no
-- inline/non-URL artifact at the CLI layer (that's a claude.ai-chat concept, not a
-- CLI tool_result):
--   publish (default) → one hosted claude.ai URL ("published · <url>")
--   list              → many title+URL rows (the user's published artifacts)
-- So the result render collects EVERY http(s) token from the body (one line each)
-- rather than only the first — otherwise a `list` would drop all but one entry. The
-- exact field shape isn't pinned to a captured fixture, so we pattern-match the text
-- rather than assume a key (robust to wire drift). No URL at all (error / unpublished
-- / an unexpected shape) falls back to the generic body so nothing is swallowed.
local function render_artifact_result(content, is_error)
  local body = tool_result_lines(content)
  local urls = {}
  for _, line in ipairs(body) do
    for u in line:gmatch("(https?://%S+)") do
      urls[#urls + 1] = u
    end
  end
  if is_error or #urls == 0 then
    render_tool_result(content, is_error, nil)
    return
  end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  -- Drop the running block's trailing randomizer blank so this attaches directly
  -- under the "● Artifact(…)" header (same seam as render_tool_result).
  local last = vim.api.nvim_buf_line_count(buf)
  if last > 0 and vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] == "" then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, {})
    vim.bo[buf].modifiable = false
  end
  local first = vim.api.nvim_buf_line_count(buf)
  local lines = {}
  -- Single publish → "published · <url>"; a list → one bare "└ <url>" per entry.
  for i, u in ipairs(urls) do
    lines[i] = (#urls == 1) and ("  └ published · " .. u) or ("  └ " .. u)
  end
  buf_append(lines)
  hl_lines(first, first + #lines - 1, "ClaudeAdvisor")   -- bright green: success verb
  buf_append({ "" })                                       -- randomizer's own row below
end

-- ── /compact modal (F4) ──────────────────────────────────────────────────────
-- The compaction lifecycle over stream-json (captured 2026-07-13):
--   system/status  status="compacting"                    → START (manual OR auto)
--   system/status  status=null, compact_result="success"  → done signal (no stats)
--   system/init                                            → fresh context
--   system/compact_boundary compact_metadata{trigger,pre_tokens,post_tokens,…} → stats
-- There is NO incremental %% in the stream, so the "modal" is an animated one-line
-- status block that persists from the compacting signal until the boundary replaces
-- it with a token receipt. Both manual and autocompact emit the same compacting
-- status, so autocompact populates it too (the user's explicit ask).
local COMPACT_SPIN = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local compact_spin_i = 1

-- Compact/dropped token counts in a one-decimal K form (30762 → "30.8K"; <1000 raw).
local function fmt_ktok(n)
  if type(n) ~= "number" then return "?" end
  if n >= 1000 then return string.format("%.1fK", n / 1000) end
  return tostring(math.floor(n))
end

local function compact_ns()
  state.compact_ns = state.compact_ns or vim.api.nvim_create_namespace("claude_compact")
  return state.compact_ns
end

-- Rewrite the tracked compacting line with the current spinner frame (in place).
local function paint_compact_line()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state.compact_mark) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, compact_ns(), state.compact_mark, {})
  if not (pos and pos[1]) then return end
  local ln = pos[1]
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, buf, ln, ln + 1, false,
    { COMPACT_SPIN[compact_spin_i] .. " Compacting conversation…" })
  vim.bo[buf].modifiable = false
  hl_lines(ln, ln, "ClaudeThink")
end

local function start_compact_modal()
  if state.compact_mark then return end            -- already compacting (idempotent)
  remove_typing_ph()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local first = vim.api.nvim_buf_line_count(buf)
  buf_append({ COMPACT_SPIN[1] .. " Compacting conversation…", "" })
  hl_lines(first, first, "ClaudeThink")
  -- right_gravity=false: paint_compact_line rewrites this exact row every 110ms via
  -- set_lines(ln, ln+1) — a delete+reinsert. Default right-gravity drags the mark to
  -- the RIGHT edge of the reinserted text (next row) each tick, so the spinner walks
  -- downward painting a fresh "Compacting…" line every frame (the flood). Left-gravity
  -- pins it to the row's start so the rewrite stays in place.
  state.compact_mark = vim.api.nvim_buf_set_extmark(buf, compact_ns(), first, 0,
    { right_gravity = false })
  compact_spin_i = 1
  state.compact_timer = vim.fn.timer_start(110, function()
    compact_spin_i = compact_spin_i % #COMPACT_SPIN + 1
    paint_compact_line()
  end, { ["repeat"] = -1 })
end

-- Replace the animated line with a token receipt (from compact_boundary stats) or a
-- bare "compacted" line (done signal with no stats). Idempotent + safe if never armed.
local function finish_compact_modal(meta)
  if state.compact_timer then
    vim.fn.timer_stop(state.compact_timer)
    state.compact_timer = nil
  end
  local buf = state.panel_buf
  local mark = state.compact_mark
  state.compact_mark = nil
  if not (buf and vim.api.nvim_buf_is_valid(buf) and mark) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, compact_ns(), mark, {})
  if not (pos and pos[1]) then return end
  local ln = pos[1]
  local line, receipt_hl = nil, "ClaudeAdvisor"
  if type(meta) == "table" then
    local trig    = (meta.trigger == "auto") and "auto" or "manual"
    local dropped = meta.cumulative_dropped_tokens
      or (type(meta.pre_tokens) == "number" and type(meta.post_tokens) == "number"
          and (meta.pre_tokens - meta.post_tokens)) or nil
    line = string.format("✓ Compacted %s → %s tokens%s · %s",
      fmt_ktok(meta.pre_tokens), fmt_ktok(meta.post_tokens),
      dropped and (" (−" .. fmt_ktok(dropped) .. ")") or "", trig)
  elseif meta == "interrupted" then
    -- The session died mid-compaction (F5 sweep): a "✓ compacted" receipt would
    -- lie — the CLI never confirmed the boundary.
    line, receipt_hl = "✗ Compacting interrupted — session ended", "ClaudeDim"
  else
    line = "✓ Conversation compacted"
  end
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, buf, ln, ln + 1, false, { line })
  vim.bo[buf].modifiable = false
  hl_lines(ln, ln, receipt_hl)
end

-- ── F5+F9 teardown sweep (FINDINGS § Q-ERROR-AUDIT) ───────────────────────────
-- CLI death (process.on_exit) or a session reset with decision state up used to
-- strand it: cards froze on "Waiting…" forever (answers no-op on a nil job_id),
-- queued permission requests leaked, a held pre-write request pinned its diff
-- windows, and the compact spinner's timer animated a zombie line until quit
-- (F9 — nothing outside the boundary/status events ever stopped it). One sweep,
-- called from both paths; every branch guards on its own state so the reset →
-- async-on_exit double-fire is harmless. `receipt` says why (shown in the cards'
-- transcript receipts).
local function abort_decision_state(receipt)
  gate.abort_permission_cards(receipt)
  question.abort_question_card(receipt)
  -- Safe when no compaction is in flight: with no extmark armed the receipt
  -- rewrite is skipped and only the (already-nil) timer handle is cleared.
  finish_compact_modal("interrupted")
end
Render.abort_decision_state = abort_decision_state

-- ── Rate-limit block (F5) ─────────────────────────────────────────────────────
-- rate_limit_event fires as telemetry EVERY turn — usually status="allowed" (fine).
-- The panel only surfaces a block when the status is NOT allowed (an actual limit),
-- matching the TUI's rate-limit screen. Headless stream-json cannot drive the TUI's
-- interactive upgrade selector, so this is an INFORMATIONAL block: the reset time +
-- the same options as read-only guidance (upgrades happen on the web). De-duped so a
-- limit re-reported each turn doesn't stack; cleared when status returns to allowed.
local function fmt_reset(ts)
  if type(ts) ~= "number" then return "soon" end
  return os.date("%H:%M", ts)              -- local wall-clock, matches the TUI
end

-- True only for a status that means the request was actually BLOCKED. The CLI emits
-- rate_limit_event every turn as telemetry, and near a window edge it reports a
-- non-"allowed" but still-permitted status (e.g. an approaching-limit warning). The
-- old "anything ≠ allowed = reached" test rendered that as a false "Rate limit
-- reached (five hour)" while the user was well under the cap (live 2026-07-14). Treat
-- any allowed/warning/approaching-family status as non-blocking; only a hard rejection
-- surfaces the block. NOTE: the exact blocking enum is still an open [VERIFY] (see
-- FINDINGS § Q-RATE-LIMIT) — this blacklists the known-safe statuses rather than
-- whitelisting the blocking one, so a real limit is never silently swallowed.
local function is_rate_limit_blocking(status)
  if type(status) ~= "string" then return false end
  local s = status:lower()
  if s == "allowed" or s:find("allow", 1, true) or s:find("warn", 1, true)
      or s:find("approach", 1, true) or s == "ok" then
    return false
  end
  return true
end

local function render_rate_limit(info)
  local status = info.status
  -- vim.json maps JSON null → vim.NIL (userdata). Guard nil/NIL and any non-blocking
  -- status (allowed / approaching-limit warning) — only a real block renders the card.
  if not is_rate_limit_blocking(status) then
    state.rate_limit_shown = nil           -- back under the limit → allow a future re-show
    return
  end
  local key = tostring(status) .. ":" .. tostring(info.resetsAt)
  if state.rate_limit_shown == key then return end   -- same limit already shown
  state.rate_limit_shown = key
  remove_typing_ph()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local ltype = (type(info.rateLimitType) == "string")
    and (" (" .. info.rateLimitType:gsub("_", " ") .. ")") or ""
  local first = vim.api.nvim_buf_line_count(buf)
  buf_append({
    "⚠ Rate limit reached" .. ltype,
    "  Resets at " .. fmt_reset(info.resetsAt),
    "  1. Stop and wait for the limit to reset",
    "  2. Upgrade your plan · claude.ai/settings/billing",
    "  3. Upgrade to Team plan · claude.ai",
    "",
  })
  hl_lines(first, first, "ClaudeError")                       -- red header
  hl_lines(first + 1, first + 1, "ClaudeDim")                 -- reset time
  hl_lines(first + 2, first + 4, "ClaudeLabel")               -- the three options
end

-- The advisor tool (the "advisor strategy") is a SERVER-side tool: the executor
-- model escalates a hard call to a stronger advisor model, which streams back as an
-- `advisor_tool_result` content block, then the executor resumes. Two quirks drive
-- this render:
--   1. The tool_use arrives as `server_tool_use` (name "advisor"), not `tool_use`.
--   2. The advisor MODEL is NOT in the stream — the executor envelope's model is
--      the EXECUTOR. So we label "using <model>" from the panel's tracked
--      state.advisor_model (the /advisor pick), exactly as the CC TUI does.
-- Header mirrors a tool block: "● Advising using Opus 4.8" in bright-green ClaudeAdvisor.
-- The canned one-line collapsed summary, verbatim from the CC TUI's advisor block.
-- Unverified against a real (non-mock) consult — update if the live wording differs.
local ADVISOR_SUMMARY = "Advisor has reviewed the conversation and will apply the feedback"
local function render_advisor_header()
  -- Mark the advisor call in-flight so the compute-phase word reads "Consulting"
  -- (not "Typing") until the advice arrives. Cleared in render_advisor_result and,
  -- as a safety net, at turn-end (result event) so it can never stick.
  state.advisor_pending = true
  local model  = state.advisor_model and friendly_model(state.advisor_model) or ""
  local header = "● Advising" .. (model ~= "" and (" using " .. model) or "")
  local first  = vim.api.nvim_buf_line_count(state.panel_buf)
  buf_append({ header })
  hl_lines(first, first, "ClaudeAdvisor")
  buf_append({ "" })   -- randomizer row / attach point the advice body strips
end

-- The advice itself → the standard collapsible tool-result body under the
-- "● Advising …" header. `content` is { type="advisor_result", text=<markdown> };
-- an error result (e.g. "Advisor unavailable") carries no usable text, so render a
-- short error line instead.
local function render_advisor_result(content)
  -- Advice arrived: the consult is over, so the compute word reverts to "Typing" as
  -- the executor resumes composing (paired with render_advisor_header's set).
  state.advisor_pending = false
  local text = (type(content) == "table") and content.text or content
  if type(text) ~= "string" or text == "" then
    render_tool_result("Advisor unavailable", true, nil)
  else
    -- Collapsed = a fixed summary + green ✔ (always ctrl+o-expandable to the full,
    -- word-wrapped advice), mirroring the CC TUI's advisor block. ADVISOR_SUMMARY is
    -- the string observed in the TUI; if the real wording differs, change it here.
    render_tool_result(text, false, nil, {
      summary       = ADVISOR_SUMMARY,
      always_toggle = true,
    })
  end
end

-- Render a Write's content as a numbered, indented, syntax-highlighted body under
-- its ● Write(...) header — the TUI-faithful "here's the new file" block. Fires at
-- tool_use time (input.content is present then) for NEW files; overwrite Writes
-- keep the accept-time red/green diff hunk. Registers a "write" fold entry so <C-o>
-- expands the collapsed preview to the whole file (build_collapsed/expanded route
-- to write_body_lines on entry.kind == "write").
local function render_write_body(path, content)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local code = vim.split(tostring(content or ""):gsub("\t", "  "), "\n", { plain = true })
  if #code > 1 and code[#code] == "" then table.remove(code) end   -- drop trailing newline's empty line
  if #code == 0 then return end

  state.tool_result_ns = state.tool_result_ns
    or vim.api.nvim_create_namespace("claude_tool_result")
  state.tool_results = state.tool_results or {}

  -- Drop the running tool block's trailing randomizer blank so the body sits
  -- directly under the `└ Wrote …` corner (same as render_tool_result).
  local last = vim.api.nvim_buf_line_count(buf)
  if last > 0 and vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] == "" then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, {})
    vim.bo[buf].modifiable = false
  end

  local lang = (path and path ~= "" and vim.filetype.match({ filename = path })) or nil
  if lang == "" then lang = nil end
  local entry = {
    kind       = "write",
    code_lines = code,
    lang       = lang,
    toggleable = #code > WRITE_HEAD_K,
    expanded   = false,
  }

  local lines, hls = build_collapsed(entry)
  local first = vim.api.nvim_buf_line_count(buf)
  buf_append(lines)
  apply_line_hls(buf, first, hls)
  entry.start_mark = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns, first, 0, {})
  entry.end_mark   = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns,
    first + #lines - 1, 0, {})

  buf_append({ "" })
  state.tool_results[#state.tool_results + 1] = entry
end
Render.render_write_body = render_write_body


-- Render the PROVISIONAL search header at tool_use time and register the block so
-- the matching tool_result can rewrite the header + attach the results. The header
-- row is tracked by extmark (not position) so interleaved output can't desync the
-- later rewrite.
local function render_search(sd, id)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  state.search_ns = state.search_ns
    or vim.api.nvim_create_namespace("claude_search")
  state.search_blocks = state.search_blocks or {}

  local first = vim.api.nvim_buf_line_count(buf)
  buf_append({ "● " .. sd.verb .. "…" })
  hl_lines(first, first, "ClaudeTool")
  buf_append({ "" })   -- randomizer row; render_search_result drops it before the body
  state.search_blocks[id] = {
    header_mark = vim.api.nvim_buf_set_extmark(buf, state.search_ns, first, 0, {}),
    sd          = sd,
  }
  state.tool_run = { t0 = vim.loop.now() }
end

-- Parse a file-list search body into (file_count, file_list). Handles the Grep
-- TOOL's "Found N files\n<paths>" summary, the empty "No files/matches" form, and
-- a bare path list (Bash rg -l / fd / find; count = #lines).
local function parse_search_result(body)
  if #body == 0 then return 0, {} end
  local n = body[1]:match("^Found%s+(%d+)")
  if n then
    local files = {}
    for i = 2, #body do files[#files + 1] = body[i] end
    return tonumber(n), files
  end
  if body[1]:match("^No files") or body[1]:match("^No matches") then
    return 0, {}
  end
  return #body, body
end

-- Rewrite a registered search header to the CC-TUI form and attach results. A
-- file-list search (Grep/Glob tool, or rg -l / fd / find via Bash) gets the count
-- header + a `└`-per-line collapsible file list. A match-line search (rg/grep/
-- ast-grep default) shows "● <Verb>  <pattern>" + the match body. Errors keep a
-- plain header + the generic red body.
local function render_search_result(sb, content, is_error, meta)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local sd   = sb.sd
  local pos  = vim.api.nvim_buf_get_extmark_by_id(buf, state.search_ns, sb.header_mark, {})
  local hrow = pos and pos[1]

  local function set_header(text)
    if not hrow then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, hrow, hrow + 1, false, { text })
    vim.bo[buf].modifiable = false
    hl_lines(hrow, hrow, "ClaudeTool")
  end

  if is_error then
    set_header("● " .. sd.verb .. " — failed")
    render_tool_result(content, true, meta)   -- generic red body under the header
    return
  end

  -- Match-line search (rg/grep/ast-grep default): header names the pattern, the
  -- match lines render as the generic (foundation) body — truncate/expand intact.
  if not sd.files then
    set_header("● " .. sd.verb .. "  " .. corner_one_line(sd.pattern or ""))
    render_tool_result(content, false, meta)
    return
  end

  local body = tool_result_lines(content)
  local m, files = parse_search_result(body)
  if m == 0 then
    set_header("● " .. sd.verb .. " — no matches")
    return
  end

  local overflow = m > RESULT_HEAD_K
  local expand   = overflow and " (ctrl+o to expand)" or ""
  if sd.verb == "Listing" then
    set_header(string.format("● Listing %d %s%s", m, m == 1 and "file" or "files", expand))
  else
    set_header(string.format("● Searching for 1 pattern, reading %d %s%s",
      m, m == 1 and "file" or "files", expand))
  end

  -- Show paths relative to cwd; each on its own `└` corner (corner_each).
  local rel = {}
  for i, f in ipairs(files) do rel[i] = rel_path(f) end

  -- Drop the header's trailing randomizer blank so the list attaches directly
  -- under it (mirrors render_tool_result).
  local last = vim.api.nvim_buf_line_count(buf)
  if last > 0 and vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] == "" then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, {})
    vim.bo[buf].modifiable = false
  end

  state.tool_result_ns = state.tool_result_ns
    or vim.api.nvim_create_namespace("claude_tool_result")
  state.tool_results = state.tool_results or {}
  local entry = {
    body        = rel,
    is_error    = false,
    corner_each = true,                    -- a file list reads best with a `└` each
    toggleable  = #rel > RESULT_HEAD_K,
    expanded    = false,
  }
  local lines, hls = build_collapsed(entry)
  local first = vim.api.nvim_buf_line_count(buf)
  buf_append(lines)
  apply_line_hls(buf, first, hls)
  entry.start_mark = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns, first, 0, {})
  entry.end_mark   = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns,
    first + #lines - 1, 0, {})
  buf_append({ "" })
  state.tool_results[#state.tool_results + 1] = entry
end


-- Toggle the tool_result block at (or nearest to) the cursor between its collapsed
-- preview and the full body (a syntax-highlighted code block for Read results,
-- reverting to the dim preview on collapse). Panel-buffer-local <C-o>; no-op
-- unless a toggleable block is near.
function Render.expand_result()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if not (state.tool_results and state.tool_result_ns) then return end
  local win = state.panel_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local cur = vim.api.nvim_win_get_cursor(win)[1] - 1   -- 0-indexed cursor line

  -- Pick the toggleable block whose [start, end] span holds the cursor, else the
  -- nearest by line distance.
  local pick, pick_d
  for _, e in ipairs(state.tool_results) do
    if e.toggleable and e.start_mark and e.end_mark then
      local sp = vim.api.nvim_buf_get_extmark_by_id(buf, state.tool_result_ns, e.start_mark, {})
      local ep = vim.api.nvim_buf_get_extmark_by_id(buf, state.tool_result_ns, e.end_mark, {})
      if sp and sp[1] and ep and ep[1] then
        local s, en = sp[1], ep[1]
        local d = (cur >= s and cur <= en) and 0
          or math.min(math.abs(cur - s), math.abs(cur - en))
        if not pick_d or d < pick_d then pick_d, pick = d, { e = e, s = s, en = en } end
      end
    end
  end
  if not pick then return end

  local e = pick.e
  -- NB: build_* return TWO values; the `cond and f() or g()` idiom truncates
  -- multi-returns to one, so use an explicit if/else to keep (lines, hls).
  local lines, hls
  if e.expanded then
    lines, hls = build_collapsed(e)
  else
    lines, hls = build_expanded(e)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, pick.s, pick.en + 1, false, lines)
  vim.bo[buf].modifiable = false
  apply_line_hls(buf, pick.s, hls)
  -- Refresh the marks around the newly written range.
  e.start_mark = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns, pick.s, 0, {})
  e.end_mark   = vim.api.nvim_buf_set_extmark(buf, state.tool_result_ns,
    pick.s + #lines - 1, 0, {})
  e.expanded = not e.expanded
  reanchor_pad()   -- the height change may push the last row under a reserved pad
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
  -- Exclude modal-wait time so the done line matches the paused live timer.
  local line = "  ✻ " .. word .. " for " .. fmt_think_dur(core.turn_elapsed_ms())
  local l    = vim.api.nvim_buf_line_count(buf)
  buf_append({ line })
  hl_lines(l, l, "ClaudeDim")
end

-- ─── Subagent lookup helpers (Goal 17) ────────────────────────────────────────

-- Resolve a subagent entry by the Agent tool_use id (inner events +
-- task_notification key on this). nil if none / no subagents yet.
local function subagent_by_id(id)
  if not (id and state.subagents) then return nil end
  for _, s in ipairs(state.subagents) do
    if s.id == id then return s end
  end
  return nil
end

-- Clawd: is any subagent still running? Drives the pet's `subagent` condition,
-- which must stay true from spawn until the last one finishes (a diff-review or
-- reading can interleave, but the resolver prioritises subagent over them). Emit
-- active=this after every subagent lifecycle change (spawn / status / final).
local function any_subagent_running()
  for _, s in ipairs(state.subagents or {}) do
    if s.status == "running" then return true end
  end
  return false
end
local function emit_subagent_state()
  if pet_emit then pet_emit("subagent", { active = any_subagent_running() }) end
end

-- Resolve by task_id (task_updated keys on this; linked to the Agent id at
-- task_started). Separate id space from the tool_use id above.
local function subagent_by_task(task_id)
  if not (task_id and state.subagents) then return nil end
  for _, s in ipairs(state.subagents) do
    if s.task_id == task_id then return s end
  end
  return nil
end

-- Compact one-line render of a subagent's inner tool CALLS, nested under its
-- agent header in the main transcript (mirrors the CC-TUI: the subagent's
-- Bash/Read/etc. show as dim indented one-liners; its prose, thinking, and
-- result bodies stay in the drill-in view so main isn't flooded with the full
-- inner stream). Only tool_use blocks surface here.
-- Max DISPLAY lines shown nested under a subagent header in MAIN before it's cut
-- off (the full transcript lives in the drill-in view, ctrl+b). Tool text WRAPS
-- rather than truncating, but the whole block stays ≤ this many rows so a chatty
-- subagent can't consume unbounded vertical space.
local SUBAGENT_MAIN_CAP = 6

-- Emit the one-time "… (ctrl+b to view)" pointer when the nested block is full.
local function subagent_cap_pointer(sub)
  if sub.main_capped then return end
  sub.main_capped = true
  local ln = vim.api.nvim_buf_line_count(state.panel_buf)
  buf_append({ "    … (ctrl+b to view)" })
  hl_lines(ln, ln, "ClaudeDim")
end

local function render_subagent_inline(event, sub)
  if (event.type or "") ~= "assistant" then return end
  for _, b in ipairs(content_blocks(event.message)) do
    if (b.type or "") == "tool_use" then
      if (sub.main_lines or 0) >= SUBAGENT_MAIN_CAP then subagent_cap_pointer(sub); return end
      local a    = b.input or {}
      local arg  = a.command or a.pattern or a.file_path or a.description or a.path or ""
      local text = (b.name or "tool") .. "(" .. tostring(arg) .. ")"
      -- First nested line of the block gets the └ connector under the header; later
      -- tool calls align under it; wrapped continuation rows indent further.
      local first_prefix = sub.main_started and "    " or "  └ "
      sub.main_started   = true
      -- Wrap to the panel width (accounting for the deepest indent) so nothing is
      -- truncated; the block is still bounded by the display-line cap below.
      local rows = wrap_disp(text, math.max(panel_width() - 6, 12))
      for wi, wl in ipairs(rows) do
        if (sub.main_lines or 0) >= SUBAGENT_MAIN_CAP then subagent_cap_pointer(sub); return end
        local ln = vim.api.nvim_buf_line_count(state.panel_buf)
        buf_append({ ((wi == 1) and first_prefix or "      ") .. wl })
        hl_lines(ln, ln, "ClaudeDim")
        sub.main_lines = (sub.main_lines or 0) + 1
      end
    end
  end
end

-- Body lines shown for a single subagent tool_result in the drill-in view before
-- it's cut with a "… +N more" pointer. The drill-in is the FULL view (vs. the
-- capped nested block in main), so this is generous — but still bounded so a
-- subagent that reads a 2000-line file can't blow the buffer to that length.
local SUBAGENT_VIEW_RESULT_CAP = 40

-- Build the RICH, fully-expanded render of ONE subagent inner event for the
-- drill-in view buffer. Reuses the main transcript's PURE formatters (tool_lines,
-- tool_result_lines) so the drill-in matches the main panel's look — cornered ●/└
-- tool blocks, full thinking bodies, wrapped coloured results — WITHOUT importing
-- the main renderers' fold / expand / tool_meta machinery. That machinery keys off
-- single-buffer global state (state.tool_meta line numbers, search_blocks, fold
-- registry); routing the live INTERLEAVED main+subagent stream through it would
-- corrupt it, and the drill-in view is read-only (no fold-toggle / expand keymaps),
-- so those affordances can't fire there anyway. Returns (lines, hls) in the span
-- format append_subagent_lines expects: hls[i] = { {startcol, endcol, group}, … }
-- aligned to lines[i] (empty table = no highlight).
local function subagent_lines(ev)
  local lines, hls = {}, {}
  local width = math.max(panel_width() - 2, 12)
  local function push(text, group)
    lines[#lines + 1] = text
    hls[#lines]       = group and { { 0, -1, group } } or {}
  end
  if (ev.type or "") == "assistant" then
    for _, b in ipairs(content_blocks(ev.message)) do
      local bt = b.type or ""
      if bt == "text" and type(b.text) == "string" and b.text ~= "" then
        for _, ln in ipairs(vim.split(b.text, "\n", { plain = true })) do
          for _, wl in ipairs(wrap_disp(ln, width)) do push("  " .. wl, "ClaudeProse") end
        end
      elseif bt == "thinking" and type(b.thinking) == "string" and b.thinking ~= "" then
        -- Full thinking body (was a bare "▸ Thinking" stub before). Not folded —
        -- the read-only view has no toggle — so it renders fully expanded + dim.
        push("▸ Thought", "ClaudeLabel")
        for _, ln in ipairs(vim.split(b.thinking, "\n", { plain = true })) do
          for _, wl in ipairs(wrap_disp(ln, width - 2)) do push("  " .. wl, "ClaudeThink") end
        end
      elseif bt == "tool_use" then
        -- Same cornered ●/└ block the main panel renders (render_tool), minus the
        -- eol randomizer row — reuse tool_lines so header verb / target match.
        local header, detail = tool_lines(b.name or "tool", b.input or {})
        push(header, TOOL_HL[TOOL_VERB[b.name] or b.name] or "ClaudeTool")
        if detail and detail ~= "" then
          local rows = wrap_disp(detail, math.max(width - 4, 8))
          for wi, wl in ipairs(rows) do push((wi == 1 and "  └ " or "      ") .. wl, "ClaudeDim") end
        end
      end
    end
  elseif (ev.type or "") == "user" then
    for _, b in ipairs(content_blocks(ev.message)) do
      if (b.type or "") == "tool_result" then
        local body = tool_result_lines(b.content)
        local grp  = (b.is_error == true) and "ClaudeError" or "ClaudeDim"
        local shown = 0
        for _, raw in ipairs(body) do
          if shown >= SUBAGENT_VIEW_RESULT_CAP then
            push("    … +" .. (#body - shown) .. " more lines", "ClaudeDim")
            break
          end
          for _, wl in ipairs(wrap_disp(raw, math.max(width - 4, 8))) do push("    " .. wl, grp) end
          shown = shown + 1
        end
      end
    end
  end
  return lines, hls
end

-- ─── Stream-json event dispatcher (Goal 6.3) ──────────────────────────────────

-- Dispatch one fully parsed stream-json event object.
local function dispatch(event)
  local ev_type = event.type or ""

  -- F8: panel_buf dead (manual :bd or reset race) → drop rather than crash in a
  -- renderer. All downstream paths — including subagent inline render — use panel_buf.
  if not (state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf)) then return end

  -- Subagent inner-event routing. A spawned Agent/Task subagent's inner activity
  -- (thinking/tool_use/tool_result) streams tagged with parent_tool_use_id = the
  -- spawning Agent tool_use id; main-session events carry null. Accumulate the raw
  -- event into the matching subagent's .events sink (for the drill-in view), render
  -- a COMPACT nested one-liner for its tool calls in main, then RETURN — do NOT
  -- fall through to the full inline render (that flooded main with every inner
  -- event). See FINDINGS § Q-SUBAGENT-STREAM.
  local parent = event.parent_tool_use_id
  if parent then
    local sub = subagent_by_id(parent)
    if sub then
      -- The subagent's model isn't in the spawn event — it first appears on its
      -- inner assistant messages. Capture it once + rewrite the main-transcript
      -- header in place (● neoclaude(desc) → ● <model>(desc)).
      if (not sub.model) and event.type == "assistant"
          and type((event.message or {}).model) == "string" then
        sub.model = friendly_model(event.message.model)
        if sub.header_lnum and state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf)
            and sub.header_lnum < vim.api.nvim_buf_line_count(state.panel_buf) then
          local hdr = "● " .. sub.model .. "(" .. corner_one_line(sub.desc or "") .. ")"
          vim.bo[state.panel_buf].modifiable = true
          pcall(vim.api.nvim_buf_set_lines, state.panel_buf,
            sub.header_lnum, sub.header_lnum + 1, false, { hdr })
          vim.bo[state.panel_buf].modifiable = false
          hl_lines(sub.header_lnum, sub.header_lnum, "ClaudeTool")
        end
        widgets.update_subagent_bar()
      end
      sub.events[#sub.events + 1] = event
      widgets.append_subagent_event(sub, event)   -- stream into the subagent's live buffer
      remove_typing_ph()
      render_subagent_inline(event, sub)          -- compact, capped trail in main
      return
    end
  end

  if ev_type == "system" and event.subtype == "init" then
    -- NOTE: system/init fires once per TURN in stream-json mode (verified: 2 inits
    -- for a 2-turn session), NOT once per session — so the task-list reset must NOT
    -- live here (it wiped the widget on the next turn). It lives in ensure_process
    -- (genuine once-per-spawn). See FINDINGS § Q-TODO-TRIGGER.
    -- The banner was pre-rendered at panel open with the cwd but no model/version
    -- (those only arrive in system/init). patch_banner (init-owned, holds the
    -- BANNER_* constants) fills the version + model lines in place so a second
    -- banner is never appended. The init event carries the CLI version under
    -- `claude_code_version` (NOT `version`); fall back to `version` for forward-compat.
    local model = friendly_model(event.model or "")
    if model ~= "" then state.model_display = model end  -- modal statusline model
    local raw_ver = event.claude_code_version or event.version or ""
    patch_banner(model, raw_ver)
    -- Capture the advertised slash commands (plain-string names) for the chat
    -- bar's "/" menu. Fires every turn but the list is stable, so only take it
    -- once (first non-empty wins; a later empty init must not wipe it).
    if type(event.slash_commands) == "table" and #event.slash_commands > 0
        and not state.slash_commands then
      -- F10: keep only plain strings — a corrupted cache or future CLI change
      -- emitting non-string elements causes name:match crashes in all_commands().
      local slash_names = {}
      for _, cmd in ipairs(event.slash_commands) do
        if type(cmd) == "string" then slash_names[#slash_names + 1] = cmd end
      end
      state.slash_commands = slash_names
      -- Persist for next session so the "/" menu works before the first message
      -- (the CLI only advertises the list here, AFTER the first turn). Deferred so
      -- the require doesn't run on every non-init event.
      require(require_prefix .. "slash").save_cache(slash_names)
    end
    state.system_ready = true
    -- working hint already set by send(); don't clobber it

  elseif ev_type == "system" and event.subtype == "status" then
    -- Compaction lifecycle (F4). status="compacting" opens the animated modal (manual
    -- OR auto); the done signal (status=null, compact_result set) is a safety-net close
    -- in case no compact_boundary follows — normally the boundary finalizes with stats.
    if event.status == "compacting" then
      start_compact_modal()
    elseif event.compact_result ~= nil and event.compact_result ~= vim.NIL then
      -- Boundary (with stats) usually lands in the same batch; defer the bare close so
      -- it wins. The guard skips if the boundary already finalized.
      vim.defer_fn(function()
        if state.compact_mark then finish_compact_modal(nil) end
      end, 500)
    end

  elseif ev_type == "system" and event.subtype == "compact_boundary" then
    -- The token receipt: replaces the animated modal with pre→post/dropped stats.
    finish_compact_modal(event.compact_metadata)

  elseif ev_type == "rate_limit_event" then
    -- Per-turn rate-limit telemetry; renders a block only on an actual limit (F5).
    render_rate_limit(event.rate_limit_info or {})

  elseif ev_type == "system" and event.subtype == "thinking_tokens" then
    -- Live estimated-token count while the model thinks; the spinner appends it to
    -- the "Thinking… Xs" label (e.g. "· 111 tok"). Type-guarded like session_cost.
    if type(event.estimated_tokens) == "number" then
      state.think_tokens = event.estimated_tokens
    end

  elseif ev_type == "system" and event.subtype == "task_started" then
    -- Goal 17.1: subagent spawned. This event LINKS the two id spaces — task_id
    -- (which task_updated keys on) and tool_use_id (the Agent id inner events +
    -- task_notification key on). Attach task_id + refresh the naming fields on the
    -- entry captured at the Agent tool_use. (FINDINGS § Q-SUBAGENT-STREAM.)
    local sub = subagent_by_id(event.tool_use_id)
    if sub then
      sub.task_id = event.task_id
      if type(event.description) == "string" then sub.desc = event.description end
      if type(event.subagent_type) == "string" then sub.kind = event.subagent_type end
      widgets.update_subagent_bar()   -- refresh row text (same height, no reflow)
    end

  elseif ev_type == "system" and event.subtype == "task_updated" then
    -- Status transition (running → completed). Keyed by task_id, so resolve via
    -- the task_started link. patch carries { status, end_time }.
    local sub = subagent_by_task(event.task_id)
    if sub and type(event.patch) == "table" and type(event.patch.status) == "string" then
      sub.status = event.patch.status
      widgets.update_subagent_bar()          -- status word → glyph/meta refresh
      widgets.maybe_dismiss_subagents()      -- all finished → auto-hide the switcher
      emit_subagent_state()   -- Clawd: clear juggling once the last one finishes
    end

  elseif ev_type == "system" and event.subtype == "task_notification" then
    -- Final subagent close: carries the token/duration totals the switcher shows
    -- (usage.total_tokens / duration_ms), a summary string, and the terminal
    -- status. Keyed by tool_use_id (the Agent id) — match by id, fall back to task.
    local sub = subagent_by_id(event.tool_use_id) or subagent_by_task(event.task_id)
    if sub then
      if type(event.usage) == "table" then sub.usage = event.usage end
      if type(event.summary) == "string" then sub.summary = event.summary end
      if type(event.status) == "string" then sub.status = event.status end
      widgets.update_subagent_bar()          -- final tokens/duration → meta refresh
      widgets.maybe_dismiss_subagents()      -- all finished → auto-hide the switcher
      emit_subagent_state()   -- Clawd: clear juggling on the final subagent close
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
      if pet_emit then pet_emit("thinking") end   -- Clawd: reasoning phase
    elseif st == "content_block_start" and (se.content_block or {}).type == "text" then
      -- Clawd: text block STARTED = Claude is now generating prose. This is the true
      -- typing signal — the other `typing` emit (assistant text block below) only
      -- fires once the AGGREGATED text lands, i.e. AFTER compose finishes, so the pet
      -- never animated typing during the live stream the transcript shows `Typing`
      -- for. Firing on the start (not the TTFT gap before any block, not the
      -- aggregated end) keeps the pet in step with the streamed text.
      if pet_emit then pet_emit("typing") end
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
    -- Render the tool_result BODY under its tool block (was dropped as "v2").
    -- Drop the typing placeholder first so the body never lands below it.
    remove_typing_ph()
    for _, block in ipairs(content_blocks(event.message)) do
      if (block.type or "") == "tool_result" then
        local meta = state.tool_meta and state.tool_meta[block.tool_use_id]
        local sb   = state.search_blocks and state.search_blocks[block.tool_use_id]
        -- NOTE: do NOT treat the parent-turn Agent tool_result as "done" — for a
        -- BACKGROUND agent it's only a "launched successfully" ack that arrives
        -- immediately while the agent keeps running (probed 2026-07-06, FINDINGS
        -- § Q-SUBAGENT-STREAM). The real terminal signal is system/task_updated
        -- (patch.status) + system/task_notification (status + usage), handled above.
        if meta and (meta.name == "TodoWrite"
            or meta.name == "TaskCreate" or meta.name == "TaskUpdate") then
          -- Noisy "Todos modified" / "Task #N created" ack — the bottom widget
          -- already reflects it, so drop the body (don't render it inline).
        elseif meta and EDIT_NAMES[meta.name] and block.is_error ~= true then
          -- "The file … has been updated successfully" ack — redundant with the
          -- diff window AND the post-approval red/green hunk block, so drop it.
          -- Errors still render (the user needs to see why an edit failed).
        elseif meta and meta.name == "Artifact" then
          -- Artifact publish/list → the "published · <url>" (or per-entry URL) line,
          -- not the generic body (see render_artifact_result).
          render_artifact_result(block.content, block.is_error == true)
        elseif sb then
          -- A registered search (Grep/Glob tool, or search-shaped Bash) rewrites
          -- its own header + renders the file list.
          render_search_result(sb, block.content, block.is_error == true, meta)
          state.search_blocks[block.tool_use_id] = nil
        else
          render_tool_result(block.content, block.is_error == true, meta)
        end
      end
    end
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
    local content = content_blocks(event.message)
    for _, block in ipairs(content) do
      local btype = block.type or ""
      if btype == "text" then
        render_prose(block.text or "")
        if pet_emit then pet_emit("typing") end   -- Clawd: Claude generating output
      elseif btype == "thinking" then
        render_thinking(block.thinking or "")
      elseif btype == "server_tool_use" and (block.name == "advisor") then
        -- Escalation to the advisor model: "● Advising using <model>" header. The
        -- advice arrives as a separate advisor_tool_result block (below).
        render_advisor_header()
      elseif btype == "advisor_tool_result" then
        render_advisor_result(block.content)
      elseif btype == "tool_use" then
        local name  = block.name or ""
        local input = block.input or {}
        -- Clawd: classify the tool → reading/cleaning/debugging (pet's own map;
        -- Agent/Task classify to nil here and are handled by the subagent emit
        -- at the spawn block below).
        if pet_emit then pet_emit("tool_use", { name = name, input = input }) end
        local subagent_hdr_lnum = nil   -- Agent/Task header line, for model rewrite
        -- TodoWrite drives the bottom-pinned task widget, not an inline block:
        -- capture the full list (each call replaces it) and re-render the float.
        local sd = block.id and widgets.search_descriptor(name, input)
        if name == "TodoWrite" then
          state.todos = input.todos or {}
          widgets.update_todo_widget()
          widgets.reflow_bottom_floats()
        elseif name == "TaskCreate" or name == "TaskUpdate" then
          -- Headless toolset has no TodoWrite; the plan rides the Task* family.
          -- Drives the same bottom-pinned widget, not an inline tool block.
          widgets.apply_task_tool(name, input)
        elseif sd then
          -- A search (Grep/Glob tool, or a search-shaped Bash command like
          -- `rg`/`ast-grep`/`fd`) renders a provisional header that its result
          -- rewrites; everything else renders inline now.
          render_search(sd, block.id)
        else
          -- Header line of the tool block = the current end (render_tool appends it
          -- first). Captured so an Agent/Task header can be rewritten in place once
          -- the subagent reveals its model (not in the spawn event).
          subagent_hdr_lnum = vim.api.nvim_buf_line_count(state.panel_buf)
          render_tool(name, input)
          -- A Write to a NEW file (doesn't exist on disk yet at request time) shows
          -- its content as a numbered, syntax-highlighted body — like Read/Edit do.
          -- Overwrite Writes fall through to the accept-time red/green diff hunk.
          if name == "Write" and type(input.content) == "string" and input.content ~= ""
              and vim.fn.filereadable(input.file_path or input.path or "") == 0 then
            render_write_body(input.file_path or input.path, input.content)
          end
        end
        -- Correlate this tool_use with its later tool_result (by id) so the
        -- result render knows the tool + file path (e.g. a Read → code block).
        if block.id then
          state.tool_meta = state.tool_meta or {}
          state.tool_meta[block.id] = { name = name, path = input.file_path or input.path }
        end
        -- Goal 17.1: an Agent/Task spawn opens a subagent session. Record it (keyed
        -- insertion order = switcher index) so its inner events (routed at the top
        -- of dispatch by parent_tool_use_id) accumulate into .events. task_id/model/
        -- usage/summary fill in later from the system/task_* lifecycle events. The
        -- ● Task header still renders inline above (17.2 refines it to the agent name).
        if (name == "Agent" or name == "Task") and block.id then
          state.subagents = state.subagents or {}
          state.subagents[#state.subagents + 1] = {
            id          = block.id,
            task_id     = nil,
            desc        = input.description or input.subagent_type or "subagent",
            kind        = input.subagent_type,
            model       = nil,
            header_lnum = subagent_hdr_lnum,   -- main-transcript header, rewritten on model
            status      = "running",
            events      = {},
            usage       = nil,
            summary     = nil,
          }
          -- The switcher appears / grows a row → refresh it AND reflow (its height
          -- changed, so the Task card + chat bar must lift above it). 17.2.
          widgets.update_subagent_bar()
          widgets.reflow_bottom_floats()
          emit_subagent_state()   -- Clawd: juggling while a subagent runs
        end
        -- MG 14.2: pre-load the edit target so the FileChangedShell interceptor
        -- catches the CLI's write (covers new + unloaded files). tool_use always
        -- precedes execution in the stream, so the buffer loads with pre-edit
        -- content. NotebookEdit carries notebook_path, the rest file_path.
        -- GATED tools are reviewed pre-write at can_use_tool instead — watching
        -- them here would queue a post-write diff of the already-approved edit
        -- (and put a new file in pending_new for sweep_new to double-gate).
        if EDIT_NAMES[name] and not gate.GATED_EDIT_TOOLS[name] then
          require("utils.claude_diff").watch(input.file_path or input.notebook_path)
        end
      end

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
    -- Clawd: turn closed → happy (success) or error. is_error marks a failed turn
    -- (error_max_turns / error_during_execution); success flashes happy then the
    -- pet hands off to the idle progression.
    if pet_emit then pet_emit("result", { ok = event.is_error ~= true }) end
    if state.diff_pending then
      -- Hold queued messages until the edit is reviewed (on_diff_close drains).
      set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
    else
      clear_hint()
      -- Turn finished: send the next type-ahead message if one is queued.
      maybe_send_next()
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
    if gate.EDIT_TOOLS[tool] then
      local input = req.input or {}
      local gated = gate.GATED_EDIT_TOOLS[tool]
        and gate.try_prewrite_gate(event.request_id, tool, input)
      if not gated then
        -- Post-write flow (MultiEdit/NotebookEdit, or a gated edit the pre-write
        -- diff couldn't reconstruct/show): pre-load the target so the
        -- FileChangedShell interceptor catches the write, then auto-allow — the
        -- vimdiff review happens AFTER the CLI writes. (Gated tools skip watch()
        -- at tool_use time, so the fallback must watch here; for the others this
        -- is a harmless re-watch of the same path.)
        require("utils.claude_diff").watch(input.file_path or input.notebook_path)
        gate.send_permission_response(event.request_id, "allow", { input = req.input })
      end
    elseif tool == "AskUserQuestion" then
      -- Structured multiple-choice questions ride the same gate but are NOT an
      -- allow/reject decision — render the vertical question selector instead of
      -- the permission card (.work/FINDINGS.md § Q-ASK). MUST come before the
      -- generic non-edit branch, which would mis-route it to show_permission_card.
      question.show_question_card(event)
    else
      -- Non-edit tool: render the interactive permission card and wait for the
      -- user's Allow once / Allow always / Reject choice (resolve_permission
      -- sends the control_response). The CLI blocks the turn until we answer.
      gate.show_permission_card(event)
    end

  elseif ev_type == "control_request" then
    -- Unknown subtype (F3): the CLI blocks its turn until EVERY control_request
    -- is answered — dropping one hangs the session behind the spinner. Answer
    -- the error variant instead of guessing at success semantics we don't know.
    gate.send_control_error(event.request_id, tostring((event.request or {}).subtype))
  end
end
Render.dispatch = dispatch
Render.subagent_lines = subagent_lines   -- rich drill-in formatter (widgets pulls via lazy require)

return Render
