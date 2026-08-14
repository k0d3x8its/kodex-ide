-- tests/claude_refit_separators_spec.lua
-- Coverage for init.lua's refit_separators (Goal 12 batch 1 Low finding,
-- init.lua:1241): rewrites every TRACKED separator line (banner divider + turn
-- dividers, both appended via core.append_separator and marked with
-- core.sep_ns) to the current panel width on resize. Previously content-
-- sniffed ("is this line entirely '─'?"), which also matched horizontal-rule
-- lines inside Claude's OWN rendered markdown output — not a panel-owned
-- separator at all — and rewrote those to the panel width too. No prior test
-- exercised this function at all (it wasn't exported).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_refit_separators_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

vim.fn.jobstart = function(_, opts)
	return 99
end
vim.fn.jobstop = function() end
vim.fn.chansend = function(_, data)
	return #data
end
vim.fn.chanclose = function() end
package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
	on_panel_open = function() end,
	on_panel_close = function() end,
	on_diff_open = function() end,
	on_diff_close = function() end,
	watch = function() end,
	poll = function() end,
}
package.loaded["utils.opencode"] = { state = { opencode_active = false }, toggle = function() end }

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function()
	return true
end
local core = require("utils.claude.core")

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)

local buf = claude.state.panel_buf
H.check("panel buffer exists", buf ~= nil and vim.api.nvim_buf_is_valid(buf))

local function sep_mark_count()
	return #vim.api.nvim_buf_get_extmarks(buf, core.sep_ns, 0, -1, {})
end

H.check("banner divider marked on open", sep_mark_count() == 1, "count=" .. sep_mark_count())

-- Append an UNTRACKED all-dash line (simulating a markdown horizontal rule
-- inside Claude's own rendered output — never went through append_separator,
-- so it carries no sep_ns mark).
local hr_line = string.rep("─", 20)
core.buf_append({ hr_line })
local hr_row = vim.api.nvim_buf_line_count(buf) - 1

-- Append a REAL tracked separator (the turn-divider path).
core.append_separator()
H.check("tracked separator added → mark count grows to 2", sep_mark_count() == 2, "count=" .. sep_mark_count())

-- Shrink the panel and refit.
local before_width = vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf, hr_row, hr_row + 1, false)[1])
claude._refit_separators()

H.check(
	"untracked horizontal-rule line is UNTOUCHED by refit (not panel-width-resized)",
	vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf, hr_row, hr_row + 1, false)[1]) == before_width,
	"before=" .. before_width
)

local tracked_row = vim.api.nvim_buf_line_count(buf) - 1
local tracked_line = vim.api.nvim_buf_get_lines(buf, tracked_row, tracked_row + 1, false)[1]
H.check(
	"tracked separator rewritten to core.sep_line() width",
	tracked_line == core.sep_line(),
	"got=" .. tostring(tracked_line)
)

-- Repeated refits must not lose or duplicate marks (extmarks survive their
-- own line's rewrite — nvim_buf_set_lines replacing exactly one line keeps an
-- extmark anchored at col 0 of that row).
claude._refit_separators()
claude._refit_separators()
H.check(
	"mark count stable across repeated refits (no loss, no duplication)",
	sep_mark_count() == 2,
	"count=" .. sep_mark_count()
)

H.summary("claude_refit_separators")
