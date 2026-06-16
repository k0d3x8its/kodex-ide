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

H.summary("term_layout")
