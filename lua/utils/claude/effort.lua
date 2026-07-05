-- lua/utils/claude/effort.lua
--
-- The /effort slider: a focusable modal float, anchored to the bottom of the panel,
-- that picks the CLI reasoning-effort level (low ─ medium ─ high ─ xhigh ─ max) on
-- a "Faster ─ Smarter" axis. Mirrors the Claude Code TUI's own /effort picker.
--
-- Why a modal (not the slash menu's inline float): effort is a one-of-five choice
-- with its OWN key handling (←/→ adjust, <CR> confirm, <Esc> cancel), so it takes
-- focus and owns its keymaps rather than riding the chat bar's keystrokes. The CLI
-- can't switch effort mid-session (it's a spawn-time --effort flag), so confirming
-- calls back into init's apply hook, which respawns the process (same as --model).
--
-- Dependencies: core.state, widgets.float_bottom_row (panel-bottom anchor) and two
-- init-owned float helpers injected via Effort.wire{} (panel_float_geom +
-- harden_float_scroll), same pattern as slash.lua/question.lua.

local Effort = {}

local require_prefix = "utils.claude."
local core    = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")
local state   = core.state

-- Ordered levels, low→max, mapped left→right on the Faster→Smarter axis.
local LEVELS = { "low", "medium", "high", "xhigh", "max" }

-- Init-owned float helpers, injected by Effort.wire{} at load time.
local panel_float_geom
local harden_float_scroll

--- Inject init's float helpers. Called once from init after they are defined.
function Effort.wire(hooks)
  panel_float_geom    = hooks.panel_float_geom
  harden_float_scroll = hooks.harden_float_scroll
end

-- Live modal state (only ever one at a time). sel = 1-based index into LEVELS,
-- on_confirm = init's apply(level) callback, prev_win = window to refocus on close.
local modal = { win = nil, buf = nil, ns = nil, sel = 1, on_confirm = nil, prev_win = nil }

--- True while the slider is open.
function Effort.active()
  return modal.win ~= nil and vim.api.nvim_win_is_valid(modal.win)
end

-- Even column centres for the 5 slots across an interior [lm, W-rm]. Used by both
-- the marker row and the label row so the ▲ sits over its level.
local function slot_centers(width)
  local lm, rm = 2, 2
  local span = math.max(width - lm - rm - 1, #LEVELS - 1)
  local out = {}
  for i = 1, #LEVELS do
    out[i] = lm + math.floor(span * (i - 1) / (#LEVELS - 1))
  end
  return out
end

-- Build a width-W line as a cell array (one string per display column), stamp
-- ASCII `text` starting at 0-based `col`, and return it. ASCII only, so cell index
-- == byte column for later highlight math.
local function blank(width) local c = {}; for i = 1, width do c[i] = " " end; return c end
local function stamp(cells, col, text)
  for i = 1, #text do
    local p = col + i
    if p >= 1 and p <= #cells then cells[p] = text:sub(i, i) end
  end
end

-- Render the modal buffer + highlights from modal.sel.
local function render()
  if not (modal.buf and vim.api.nvim_buf_is_valid(modal.buf)) then return end
  local width = select(2, panel_float_geom())
  local centers = slot_centers(width)

  -- Axis labels row: "Faster" left, "Smarter" right-aligned.
  local axis = blank(width)
  stamp(axis, 2, "Faster")
  stamp(axis, width - 2 - #("Smarter"), "Smarter")

  -- Track row: a horizontal rule with the ▲ marker over the selected slot.
  local track_cells = blank(width)
  for i = 3, width - 2 do track_cells[i] = "─" end
  track_cells[centers[modal.sel] + 1] = "▲"
  local track = table.concat(track_cells)

  -- Labels row (ASCII): each level centred on its slot; remember the selected
  -- span so it can be bolded.
  local labels = blank(width)
  local sel_start, sel_end
  for i, name in ipairs(LEVELS) do
    local start = centers[i] - math.floor(#name / 2)
    if start < 0 then start = 0 end
    stamp(labels, start, name)
    if i == modal.sel then sel_start, sel_end = start, start + #name end
  end

  local lines = {
    " Effort",
    "",
    table.concat(axis),
    track,
    table.concat(labels),
    "",
    " ←/→ to adjust · Enter to confirm · Esc to cancel",
  }
  vim.bo[modal.buf].modifiable = true
  vim.api.nvim_buf_set_lines(modal.buf, 0, -1, false, lines)
  vim.bo[modal.buf].modifiable = false

  -- Highlights (line indices are 0-based).
  local ns = modal.ns
  vim.api.nvim_buf_clear_namespace(modal.buf, ns, 0, -1)
  local function band(lnum, hl)
    vim.api.nvim_buf_set_extmark(modal.buf, ns, lnum, 0, { end_row = lnum + 1, hl_group = hl, hl_eol = true })
  end
  band(0, "ClaudeEffortTitle")   -- " Effort"
  band(2, "ClaudeEffortAxis")    -- Faster / Smarter
  band(3, "ClaudeEffortAxis")    -- track + marker
  band(6, "ClaudeEffortHint")    -- footer
  -- Labels row (index 4): dim the whole row, then bold the selected span.
  band(4, "ClaudeEffortDim")
  if sel_start then
    vim.api.nvim_buf_set_extmark(modal.buf, ns, 4, sel_start, {
      end_col = sel_end, hl_group = "ClaudeEffortSel",
    })
  end
end

--- Close the slider without applying. Refocuses the panel window.
function Effort.close()
  if modal.win and vim.api.nvim_win_is_valid(modal.win) then
    vim.api.nvim_win_close(modal.win, true)
  end
  if modal.prev_win and vim.api.nvim_win_is_valid(modal.prev_win) then
    pcall(vim.api.nvim_set_current_win, modal.prev_win)
  end
  modal.win, modal.buf, modal.ns, modal.on_confirm, modal.prev_win = nil, nil, nil, nil, nil
end

-- Move the selection (±1), clamped, and redraw.
local function move(delta)
  if not Effort.active() then return end
  modal.sel = math.min(math.max(modal.sel + delta, 1), #LEVELS)
  render()
end

-- Confirm the highlighted level: close, then hand it to init's apply hook.
local function confirm()
  local level, cb = LEVELS[modal.sel], modal.on_confirm
  Effort.close()
  if cb then cb(level) end
end

--- Open the slider. `current` is the level to preselect (defaults to medium),
--- `on_confirm(level)` fires when the user presses <CR>.
function Effort.open(current, on_confirm)
  if Effort.active() then Effort.close() end
  modal.sel = 2   -- medium
  for i, l in ipairs(LEVELS) do if l == current then modal.sel = i end end
  modal.on_confirm = on_confirm
  modal.prev_win   = vim.api.nvim_get_current_win()
  modal.ns  = vim.api.nvim_create_namespace("claude_effort_modal")
  modal.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[modal.buf].bufhidden = "wipe"

  local col, width = panel_float_geom()
  local bottom = widgets.float_bottom_row()
  modal.win = vim.api.nvim_open_win(modal.buf, true, {
    relative = "editor", anchor = "SW",
    row = bottom, col = col, width = width, height = 7,
    border = "rounded", style = "minimal",
    zindex = 75,   -- above the chat bar / slash menu, alongside permission cards
  })
  vim.wo[modal.win].winhighlight = "NormalFloat:ClaudeSlashBg,FloatBorder:ClaudeSlashBorder"
  harden_float_scroll(modal.win)

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = modal.buf, nowait = true, silent = true })
  end
  map("<Left>",  function() move(-1) end)
  map("<Right>", function() move(1) end)
  map("h",       function() move(-1) end)
  map("l",       function() move(1) end)
  map("<CR>",    confirm)
  map("<Esc>",   Effort.close)
  map("q",       Effort.close)
  -- Closing on focus loss keeps it modal-ish: clicking away dismisses it.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = modal.buf, once = true, callback = function() Effort.close() end,
  })

  render()
end

--- The current effort level for the statusline (defaults to "medium" when unset,
--- matching the CLI's shown default).
function Effort.current()
  return state.effort or "medium"
end

return Effort
