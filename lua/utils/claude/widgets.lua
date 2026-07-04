-- lua/utils/claude/widgets.lua
--
-- The panel's bottom-pinned Task-plan card widget (headless Task* protocol → a
-- bordered status float) plus the pure search-tool CLASSIFIER (search_descriptor).
-- Extracted from the former monolithic claude.lua (Goal 15.3), dissolving the two
-- `do ... end` band-aid scopes that had held these helpers' constants off init's
-- main chunk (Lua's 200-local-per-function ceiling). The search RENDERERS stay in
-- init for now — they depend on the tool_result render foundation and will move
-- together with it into the render module (Goal 15.7).
--
-- Dependencies: core.state, and three init-owned float/pad helpers injected via
-- Widgets.wire{} (they couple to init's chat-bar/float machinery; injection avoids
-- a require cycle and lets 15.5/15.7 re-home them with a one-line change here).

local Widgets = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local state = core.state

-- Init-owned helpers, injected by Widgets.wire{} at load time (see init.lua).
-- Declared as forward locals so the widget functions below close over them.
local set_bottom_pad
local panel_float_geom
local harden_float_scroll

--- Inject init's float/pad helpers. Called once from init after they are defined.
function Widgets.wire(hooks)
  set_bottom_pad      = hooks.set_bottom_pad
  panel_float_geom    = hooks.panel_float_geom
  harden_float_scroll = hooks.harden_float_scroll
end

-- ─── Search-tool classifier ──────────────────────────────────────────────────
-- Descriptor for a search tool_use, or nil if it isn't a search. Covers the Grep/
-- Glob TOOLS (clean output) and search-shaped Bash COMMANDS (headless reality: the
-- panel's claude has NO Grep/Glob tool, so it searches via Bash). { verb, pattern,
-- files } — `files` (clean path-list output) gates the count-header + `└ file` list.
-- Scoped in a do-block so its lookup table + helper stay off the main local budget.
-- Search-shaped shell commands → the verb they read as.
local SEARCH_CMDS = {
  rg = "Searching", grep = "Searching", egrep = "Searching", fgrep = "Searching",
  ["ast-grep"] = "Searching", sg = "Searching",
  fd = "Listing", fdfind = "Listing", find = "Listing",
}
-- Flags that make a search emit a bare FILE LIST rather than match lines.
local function files_mode(base, cmd)
  if base == "fd" or base == "fdfind" or base == "find" then return true end
  return cmd:match("%s%-l%f[%s]") ~= nil
    or cmd:match("%-%-files%-with%-matches") ~= nil
    or cmd:match("%-%-files%f[%s]") ~= nil
end
function Widgets.search_descriptor(name, input)
if name == "Grep" then
  return { verb = "Searching", pattern = input.pattern, files = true }
elseif name == "Glob" then
  return { verb = "Listing", pattern = input.pattern, files = true }
elseif name == "Bash" then
  local cmd = input.command
  if type(cmd) ~= "string" or cmd == "" then return nil end
  -- Leading command word, past any "cd X &&" prefix; basename if a path.
  local c    = (cmd:match("&&%s*(.+)$") or cmd):gsub("^%s+", "")
  local word = c:match("^([%w%-%._/]+)")
  local base = word and (word:match("([^/]+)$") or word)
  local verb = base and SEARCH_CMDS[base]
  if not verb then return nil end
  -- Pattern: prefer the first quoted string (keeps multi-word patterns whole),
  -- else the first non-flag token. Strip any surrounding quotes either way.
  local pat = c:match('"([^"]*)"') or c:match("'([^']*)'")
  if not pat then
    for tok in c:gmatch("%S+") do
      if tok ~= base and not tok:match("^%-") then pat = tok; break end
    end
    if pat then pat = pat:gsub("^[\"']", ""):gsub("[\"']$", "") end
  end
  return { verb = verb, pattern = pat or c, files = files_mode(base, c) }
end
return nil
end

-- ─── Task-plan card widget ───────────────────────────────────────────────────
-- ─── TodoWrite task-list widget (bottom-pinned float) ────────────────────────

-- Render the task list to (lines, hls): a dim "N tasks (X done, Y in progress,
-- Z open)" header, then one row per task (✔ done strikethrough / ▦ in-progress
-- orange / □ pending), capped at CAP with a "… +N more" tail. hls[i] is a list of
-- {b0, b1, group} spans. Pure — unit-tested directly. Scoped in a do-block (its
-- constants + helper stay off the main chunk's local budget — 200-local limit).
local CAP    = 8
local GLYPH  = { completed = "✔", in_progress = "▦", pending = "□" }
local TEXTHL = {
  completed   = "ClaudeTodoDone",
  in_progress = "ClaudeTodoActive",
  pending     = "ClaudeTodoPending",
}
-- Count tasks by status. Anything not completed/in_progress counts as open.
local function counts(todos)
  local done, active, open = 0, 0, 0
  for _, t in ipairs(todos) do
    local s = t.status
    if s == "completed" then done = done + 1
    elseif s == "in_progress" then active = active + 1
    else open = open + 1 end
  end
  return done, active, open
end
-- One-space left gutter so rows don't sit flush against the card border. Every
-- rendered line carries it; every highlight column offset is shifted by #PAD to
-- stay in sync with the padded text (tests S17/S18 encode the shifted offsets).
local PAD = " "
function Widgets.render_todo_lines(todos)
  local done, active, open = counts(todos)
  local n = #todos
  local header = string.format("%d task%s (%d done, %d in progress, %d open)",
    n, n == 1 and "" or "s", done, active, open)
  local lines, hls = { PAD .. header }, { { { 0, -1, "ClaudeTodoHeader" } } }

  local shown, more = n, 0
  if n > CAP then shown, more = CAP - 1, n - (CAP - 1) end
  for i = 1, shown do
    local t      = todos[i]
    local status = t.status or "pending"
    local glyph  = GLYPH[status] or GLYPH.pending
    -- In-progress tasks read better in their gerund activeForm ("Applying …").
    local text   = (status == "in_progress" and t.activeForm and t.activeForm ~= "")
      and t.activeForm or (t.content or "")
    lines[#lines + 1] = PAD .. glyph .. " " .. text
    local glyph_hl = status == "completed" and "ClaudeTodoCheck"
      or (TEXTHL[status] or "ClaudeTodoPending")
    hls[#hls + 1] = {
      { #PAD, #PAD + #glyph, glyph_hl },                          -- status glyph
      -- Start the text span AFTER the pad + separator space (#PAD + #glyph + 1),
      -- not at the glyph: a completed row's strikethrough (ClaudeTodoDone) would
      -- otherwise cover the space touching the ✔ and bleed a line into the glyph.
      { #PAD + #glyph + 1, -1, TEXTHL[status] or "ClaudeTodoPending" }, -- task text
    }
  end
  if more > 0 then
    lines[#lines + 1] = PAD .. string.format("… +%d more", more)
    hls[#hls + 1] = { { 0, -1, "ClaudeTodoHeader" } }
  end
  return lines, hls
end

-- Rows the widget currently occupies (0 when hidden). Other bottom floats + the
-- chat pad add this so they stack ABOVE the task list. Assigns the forward-declared
-- local so the early pad math can see it.
function Widgets.todo_height()
  return (state.todos and #state.todos > 0) and (state.todo_h or 0) or 0
end

-- SW `row` for a bottom float (chat bar / permission / question / diff): the
-- panel bottom, lifted above the task widget when it is visible. Single source so
-- every float + the resize handler stack consistently.
function Widgets.float_bottom_row()
  return vim.o.lines - 2 - Widgets.todo_height()
end

-- Close the task-list widget float (kept buffer is reused on next open).
function Widgets.close_todo_widget()
  if state.todo_resize_teardown then state.todo_resize_teardown(); state.todo_resize_teardown = nil end
  if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
    pcall(vim.api.nvim_win_close, state.todo_win, true)
  end
  state.todo_win = nil
  state.todo_h   = 0
  state.todo_done_pending = false
end

-- Lift every currently-open bottom float above the task widget and re-reserve
-- transcript space. Called when the widget appears / changes height while floats
-- are already open (their open-time row is otherwise stale).
function Widgets.reflow_bottom_floats()
  local row = Widgets.float_bottom_row()
  local function move(win)
    if win and vim.api.nvim_win_is_valid(win) then
      local c = vim.api.nvim_win_get_config(win)
      if c.relative and c.relative ~= "" then
        c.row = row
        pcall(vim.api.nvim_win_set_config, win, c)
      end
    end
  end
  move(state.perm and state.perm.win)
  move(state.qask and state.qask.win)
  move(state.diff_card and state.diff_card.win)
  move(state.chat_win)
  set_bottom_pad(state.chat_pad or 0)   -- recompute total (chat base + widget)
end

-- Apply a headless-SDK Task* tool call to state.todos + refresh the widget.
-- The panel's claude runs the headless toolset, which has NO TodoWrite tool; it
-- tracks a plan via the Task* orchestration family instead (RE'd live 2026-07-03,
-- FINDINGS § Q-TODO-TRIGGER). Unlike TodoWrite (one call carries the whole array),
-- Task* is incremental: TaskCreate adds one item, TaskUpdate mutates one by id.
-- The CLI numbers tasks with a global running counter ("Task #N created"), and
-- TaskUpdate.taskId is that N — so we mint ids from our own todo_seq in creation
-- order to match. We rebuild the same {content,status,activeForm} rows the widget
-- already renders. Returns true when it handled the tool.
-- True only when the plan is non-empty AND every task is completed. Pure — the
-- auto-dismiss decision is tested through this, not the timer.
function Widgets.plan_complete(todos)
  if not (todos and #todos > 0) then return false end
  for _, t in ipairs(todos) do
    if t.status ~= "completed" then return false end
  end
  return true
end

function Widgets.apply_task_tool(name, input)
  input = input or {}
  if name == "TaskCreate" then
    state.todos    = state.todos or {}
    state.todo_seq = (state.todo_seq or 0) + 1
    state.todos[#state.todos + 1] = {
      id         = state.todo_seq,
      content    = input.subject or "",
      activeForm = input.activeForm,
      status     = "pending",
    }
  elseif name == "TaskUpdate" then
    local id    = tonumber(input.taskId)
    local todos = state.todos or {}
    if input.status == "deleted" then
      for i, t in ipairs(todos) do
        if t.id == id then table.remove(todos, i); break end
      end
    else
      for _, t in ipairs(todos) do
        if t.id == id then t.status = input.status or t.status; break end
      end
    end
  else
    return false
  end
  -- Only reflow (which recomputes the bottom pad and re-anchors the transcript) when
  -- the card's HEIGHT actually changes — i.e. a create/delete adds/removes a row. A
  -- status-only TaskUpdate keeps the same line count, and reflowing on every one of
  -- those nudged the view → the "slight jitter" while Claude ticks tasks off.
  local old_h = state.todo_h or 0
  Widgets.update_todo_widget()
  if (state.todo_h or 0) ~= old_h then Widgets.reflow_bottom_floats() end

  -- Auto-dismiss the card once the WHOLE plan is done. Armed ONLY from a completing
  -- TaskUpdate (never a TaskCreate), so a model that creates-then-completes tasks
  -- one at a time can't momentarily read as "all done" and dismiss early. The
  -- deferred close re-checks plan_complete at fire time, so any task added/reopened
  -- within the window cancels it. Guarded so repeated updates don't stack timers.
  if name == "TaskUpdate" and Widgets.plan_complete(state.todos) then
    if not state.todo_done_pending then
      state.todo_done_pending = true
      vim.defer_fn(function()
        state.todo_done_pending = false
        if Widgets.plan_complete(state.todos) then
          Widgets.close_todo_widget()
          Widgets.reflow_bottom_floats()
        end
      end, 2500)
    end
  else
    state.todo_done_pending = false
  end
  return true
end

-- Open or update the bottom-pinned task-plan card from state.todos. A bordered
-- (rounded, amber-outlined, titled) non-focusable SW float at the bottom of the
-- panel column — same modal styling as the permission/question cards, but a
-- persistent status display (no focus, no keymaps). The other bottom floats + the
-- chat pad read todo_height() (content + 2 border rows) to stack ABOVE it. Hidden
-- (closed) when the list is empty. The caller reflows the other floats after.
function Widgets.update_todo_widget()
  local todos = state.todos
  if not (todos and #todos > 0) then Widgets.close_todo_widget(); return end
  if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then return end

  local lines, hls = Widgets.render_todo_lines(todos)
  local buf = state.todo_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    state.todo_buf = buf
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  state.todo_ns = state.todo_ns or vim.api.nvim_create_namespace("claude_todo")
  vim.api.nvim_buf_clear_namespace(buf, state.todo_ns, 0, -1)
  for i, spans in ipairs(hls) do
    for _, h in ipairs(spans) do
      vim.api.nvim_buf_add_highlight(buf, state.todo_ns, h[3], i - 1, h[1], h[2])
    end
  end
  -- Footprint = content rows + 2 for the rounded border, so float_bottom_row /
  -- set_bottom_pad reserve the FULL bordered height and the chat bar + modals
  -- stack cleanly above the card (not over its top border).
  state.todo_h = #lines + 2

  local col, w = panel_float_geom()
  -- Bordered card (matches the permission/question modals): rounded outline in the
  -- amber ClaudePermBorder, titled, but non-focusable + persistent (a status
  -- display, not a decision prompt — no keymaps, never steals focus). width is the
  -- panel-column minus the 2 border cells.
  local cfg = {
    relative = "editor", anchor = "SW",
    row = vim.o.lines - 2, col = col, width = math.max(w - 2, 1), height = #lines,
    style = "minimal", focusable = false, zindex = 30,   -- below modals (default 50)
    border = "rounded", title = " ✻ Task Plan ", title_pos = "left",
  }
  if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
    pcall(vim.api.nvim_win_set_config, state.todo_win, cfg)
  else
    state.todo_win = vim.api.nvim_open_win(buf, false, cfg)
    vim.wo[state.todo_win].winhl =
      "Normal:ClaudeNormal,NormalNC:ClaudeNormal,FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder"
    harden_float_scroll(state.todo_win)
    -- The widget pins to the panel BOTTOM (not float_bottom_row), so it needs its
    -- own resize path: re-render at lines-2 + re-fit width, then reflow the floats
    -- above it. (The shared attach_panel_float_resize would lift it by its own
    -- height.)
    vim.api.nvim_create_augroup("ClaudeTodoResize", { clear = true })
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = "ClaudeTodoResize",
      callback = function()
        if not (state.todo_win and vim.api.nvim_win_is_valid(state.todo_win)) then
          return true   -- gone → self-remove
        end
        Widgets.update_todo_widget()
        Widgets.reflow_bottom_floats()
      end,
    })
    state.todo_resize_teardown = function()
      pcall(vim.api.nvim_del_augroup_by_name, "ClaudeTodoResize")
    end
  end
end

return Widgets
