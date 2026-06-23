-- tests/term_layout_spec.lua
--
-- Regression for the OpenCode/dev-terminal layout bug. toggleterm GROUPS
-- terminal splits (ui.open_split anchors a new split to any already-open
-- toggleterm window), so before utils.term_layout the second terminal landed
-- glued to the first: OpenCode stacked horizontally UNDER the dev term, and the
-- dev term opened as a full-height column right of OpenCode. The fix re-asserts
-- each terminal's edge on open, and the dev term re-pins OpenCode so it sits
-- BESIDE the strip, not above a full-width one.
--
-- Unlike the other specs (which stub toggleterm), this one loads the REAL
-- plugin — layout is exactly the behaviour under test, so a stub proves nothing.
-- If toggleterm isn't installed (e.g. a clean checkout with no plugins synced),
-- the spec skips rather than failing the suite.
--
-- SCOPE: this exercises the term_layout PRIMITIVES against the real plugin, but
-- it copies the on_open wiring inline and uses a `sleep` job — it does NOT drive
-- the real term_toggle/opencode orchestration, and a `sleep` is not a TUI, so it
-- cannot catch on_open drift or the blank-OpenCode redraw bug. Those are covered
-- by the human-in-the-loop checklist in tests/MANUAL-opencode-layout.md.
local H = dofile("tests/helpers.lua")

-- Generous grid so 40%/10-row splits have unambiguous room.
vim.o.columns = 200
vim.o.lines = 40

local function find_toggleterm()
  for _, base in ipairs({
    vim.fn.stdpath("data") .. "/lazy/toggleterm.nvim",
    vim.fn.expand("~/.local/share/nvim/lazy/toggleterm.nvim"),
  }) do
    if vim.fn.isdirectory(base) == 1 then
      return base
    end
  end
  return nil
end

local tt_path = find_toggleterm()
if not tt_path then
  print("SKIP  toggleterm not installed — layout spec needs the real plugin")
  H.summary("term_layout")
  return
end

vim.opt.runtimepath:append(tt_path)
vim.opt.runtimepath:append(vim.fn.fnamemodify(tt_path, ":h") .. "/plenary.nvim")

-- Mirror the real toggleterm.setup (crucially: NO open_mapping).
require("toggleterm").setup {
  direction       = "horizontal",
  size            = 15,
  start_in_insert = true,
  close_on_exit   = false,
}

local Terminal = require("toggleterm.terminal").Terminal
local layout = require("utils.term_layout")

local DEV_HEIGHT = 10
local function panel_width()
  return math.floor(vim.o.columns * 0.40)
end

-- harmless long-lived job; geometry is independent of the command
local JOB = "sleep 1000"

-- on_open wiring mirrors the real modules: dev → place_horizontal (homes under
-- the editor, never touches OpenCode), OpenCode → place_vertical.
local dev = Terminal:new {
  cmd = JOB, direction = "horizontal", size = DEV_HEIGHT,
  close_on_exit = false, hidden = true,
  on_open = function() layout.place_horizontal(DEV_HEIGHT) end,
}
local oc = Terminal:new {
  cmd = JOB, direction = "vertical",
  close_on_exit = false, hidden = true,
  on_open = function() layout.place_vertical(panel_width()) end,
}

-- a real editor window must exist first
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "file" })

local function win_of(term)
  return term.window
end
local function geom(win)
  local pos = vim.api.nvim_win_get_position(win)
  return {
    row = pos[1], col = pos[2],
    w = vim.api.nvim_win_get_width(win),
    h = vim.api.nvim_win_get_height(win),
  }
end

-- Assert the canonical 3-pane layout: editor top-left, OpenCode full-height
-- right, dev strip bottom-left under the editor only.
local function assert_canonical(prefix)
  local o = geom(win_of(oc))
  local d = geom(win_of(dev))
  -- OpenCode: vertical panel pinned to the right, near-full height
  H.check(prefix .. " opencode is a right-side vertical panel",
    o.w < vim.o.columns and o.col > vim.o.columns * 0.5, vim.inspect(o))
  H.check(prefix .. " opencode is near-full height",
    o.h > vim.o.lines * 0.6, vim.inspect(o))
  -- dev: short horizontal strip pinned to the bottom
  H.check(prefix .. " dev is a short bottom strip",
    d.h <= DEV_HEIGHT + 2 and d.row > vim.o.lines * 0.5, vim.inspect(d))
  -- the actual user complaint: the strip must NOT span under OpenCode too
  H.check(prefix .. " dev sits under the editor only (not full width)",
    d.w < vim.o.columns, vim.inspect(d))
end

-- Scenario 1: dev terminal first, then OpenCode.
dev:toggle()
oc:toggle(panel_width())
assert_canonical("dev→oc:")
oc:close(); dev:close()

-- Scenario 2: OpenCode first, then dev terminal (the order that regressed).
oc:toggle(panel_width())
dev:toggle()
assert_canonical("oc→dev:")
oc:close(); dev:close()

-- Scenario 3: OpenCode open, dev term closed then REOPENED. This is the case
-- that blanked OpenCode live — the old fix moved OpenCode's window on every dev
-- open, stranding its TUI on a stale screen. The strip must re-home under the
-- editor while OpenCode stays open, valid, and unmoved.
oc:toggle(panel_width())
dev:toggle()
dev:close()
dev:toggle()
H.check("oc→dev reopen: opencode still open", oc:is_open())
-- the black-window symptom was OpenCode's window being replaced/stranded; assert
-- it still shows its OWN terminal buffer (not an empty/blank one)
H.check("oc→dev reopen: opencode window still shows its buffer",
  vim.api.nvim_win_is_valid(win_of(oc))
    and vim.api.nvim_win_get_buf(win_of(oc)) == oc.bufnr,
  "win=" .. tostring(win_of(oc)) .. " buf=" .. tostring(oc.bufnr))
assert_canonical("oc→dev reopen:")
oc:close(); dev:close()

-- Scenario 4: no file open — the main window is the alpha dashboard
-- (buftype "nofile", filetype "alpha"). This is what actually shipped broken:
-- editor detection required buftype=="" so it skipped the dashboard, fell back
-- to wincmd J, and the strip spanned full-width UNDER OpenCode. The strip must
-- still home under the dashboard (beside OpenCode), not below it.
local dash = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_option_value("buftype", "nofile", { buf = dash })
vim.api.nvim_set_option_value("filetype", "alpha", { buf = dash })
vim.api.nvim_win_set_buf(0, dash)
oc:toggle(panel_width())
dev:toggle()
assert_canonical("alpha-dashboard:")
oc:close(); dev:close()

-- ── Mutex tests (MG 10.3) ────────────────────────────────────────────────────
--
-- Verify that each panel's toggle() closes the sibling panel when it is open.
-- These tests don't need real panel processes — stubs capture the call count.
-- They run here (not in claude_spec / opencode_spec) because A5 (dual-panel
-- contention) is a term_layout concern: both panels call place_vertical, so
-- simultaneous open strands one on a stale window.

-- Stubs that claude.toggle() / opencode.toggle() depend on at runtime.
-- (term_layout is already the real module from the scenarios above.)
package.loaded["utils.claude_diff"] = {
  on_panel_open  = function() end,
  on_panel_close = function() end,
  on_diff_open   = function() end,
  on_diff_close  = function() end,
}
H.stub_project_root("/tmp")
vim.fn.jobstart = function() return 99 end  -- fake job_id
vim.fn.chansend = function() end
vim.fn.jobstop  = function() end

-- Mutex A: opencode is marked active → claude.toggle() must call opencode.toggle()
-- (so OpenCode collapses before Claude opens its panel window).
local oc_toggle_calls = 0
package.loaded["utils.opencode"] = {
  state  = { opencode_active = true },
  toggle = function() oc_toggle_calls = oc_toggle_calls + 1 end,
}
local claude = require("utils.claude")
claude.state.claude_active = false  -- panel closed — put module in "will open" state
claude.is_available = function() return true end  -- bypass binary check on CI

claude.toggle()
vim.wait(50)
H.check("mutex A: claude.toggle() calls opencode.toggle() when opencode active",
  oc_toggle_calls == 1, "calls=" .. oc_toggle_calls)

-- Clean up the panel window that toggle() just opened.
if claude.state.panel_win and vim.api.nvim_win_is_valid(claude.state.panel_win) then
  vim.api.nvim_win_close(claude.state.panel_win, true)
end
claude.state.claude_active = false
claude.state.job_id        = nil

-- Mutex B: claude is marked active → opencode.toggle() must call claude.toggle()
-- Before calling opencode.toggle(), override package.loaded["utils.claude"] so
-- the pcall(require) inside opencode.toggle() gets our spy instead of the real module.
local cl_toggle_calls = 0
package.loaded["utils.claude"] = {
  state  = { claude_active = true },
  toggle = function() cl_toggle_calls = cl_toggle_calls + 1 end,
}
package.loaded["utils.opencode"] = nil  -- force fresh require of real opencode
local opencode = require("utils.opencode")
opencode.is_available = function() return true end  -- bypass binary check on CI

opencode.toggle()
vim.wait(100)
H.check("mutex B: opencode.toggle() calls claude.toggle() when claude active",
  cl_toggle_calls == 1, "calls=" .. cl_toggle_calls)

H.summary("term_layout")
