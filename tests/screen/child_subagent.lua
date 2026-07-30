-- [DEBUG-b7c1] Child scenario: reproduces the subagent drill-in float stack using
-- the REAL formulas lifted from widgets.lua, so the composited screen can be read
-- back by screen_harness.lua and the overlap seen rather than computed.
--
-- Formulas mirrored verbatim:
--   gate.lua panel_float_geom()   -> col = panel win col, width = panel_w - 2
--   widgets.lua update_subagent_bar() -> anchor SW, row = lines-2, width = w-2,
--                                        height = #lines, zindex 30, rounded
--                                        subagent_h = #lines + 2
--   init.lua set_bottom_pad()     -> pad_rows = chat_pad + todo_h + subagent_h
--   widgets.lua subagent_view_geom() -> row = prow, height = total_h - 2,
--                                       total_h = ph - pad_rows, zindex 40, rounded
--   widgets.lua open_subagent_tag()  -> anchor NE, row = prow + total_h - 1,
--                                      col = view_col + view_w, zindex 60

local CENSUS_PATH = vim.env.CENSUS_PATH or "/tmp/subagent_census.txt"
local BAR_ROW_COUNT = tonumber(vim.env.BAR_ROW_COUNT or "2")

-- The bar anchors to vim.o.lines while the view sizes off the PANEL window height.
-- laststatus/cmdheight change the gap between those two bases, so sweep them.
vim.o.laststatus = tonumber(vim.env.LASTSTATUS or "2")
vim.o.cmdheight = tonumber(vim.env.CMDHEIGHT or "1")

-- TOP_OFFSET pushes the panel down the screen. At 0 the view's top border wants
-- row -1 and nvim CLAMPS the float down; at >=1 the top border fits on-screen and
-- no clamp happens, which is the configuration the off-by-one is not masked in.
local TOP_OFFSET = tonumber(vim.env.TOP_OFFSET or "0")
if TOP_OFFSET >= 1 then
	vim.o.showtabline = 2
	vim.o.tabline = "TABLINE"
else
	vim.o.showtabline = 0
end

-- Left (editor) window carries the sentinel: every float lives in the right column,
-- so col 0 stays uncovered and the harness can tell "rendered" from "timed out".
local editor_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "SCREENREADY" })

vim.cmd("vsplit")
vim.cmd("wincmd l")
local panel_win = vim.api.nvim_get_current_win()
local panel_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(panel_win, panel_buf)
vim.api.nvim_win_set_width(panel_win, 60)

-- Distinctive transcript content: TXnn tells us exactly which row got clipped.
local transcript_lines = {}
for line_number = 1, 120 do
	transcript_lines[line_number] = string.format("TX%03d transcript row %d", line_number, line_number)
end
vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, transcript_lines)

local function panel_float_geom()
	local panel_w = vim.api.nvim_win_get_width(panel_win)
	local float_col = vim.api.nvim_win_get_position(panel_win)[2]
	return float_col, math.max(panel_w - 2, 1)
end

-- ── switcher bar (zindex 30) ────────────────────────────────────────────────
local bar_lines = {}
for row_index = 1, BAR_ROW_COUNT do
	bar_lines[row_index] = "BARROW" .. row_index
end
local bar_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bar_buf, 0, -1, false, bar_lines)

local panel_row = vim.api.nvim_win_get_position(panel_win)[1]
local panel_height = vim.api.nvim_win_get_height(panel_win)

-- Candidate bar anchors, swept against the rendered screen:
--   0 = shipped: relative="editor" + absolute `vim.o.lines - 2`. Assumes a fixed
--       statusline+cmdline row count.
--   1 = relative="editor" + the panel window's own bottom row. Same base pad_rows
--       uses -- but still re-derives an absolute row, so it inherits SW-anchor and
--       clamping semantics.
--   2 = relative="win" against the panel, letting nvim resolve the anchor itself.
--   BAR_ROW_ADJUST shifts whichever absolute row was chosen, for offset sweeps.
local anchor_mode = tonumber(vim.env.FIX_ANCHOR or "0")
local row_adjust = tonumber(vim.env.BAR_ROW_ADJUST or "0")

local bar_col, bar_width_base = panel_float_geom()
local bar_cfg = {
	relative = "editor",
	anchor = "SW",
	row = (anchor_mode == 1 and (panel_row + panel_height - 1) or (vim.o.lines - 2)) + row_adjust,
	col = bar_col,
	width = math.max(bar_width_base - 2, 1),
	height = #bar_lines,
	style = "minimal",
	focusable = false,
	zindex = 30,
	border = "rounded",
	title = " SUBAGENTS ",
	title_pos = "left",
}
if anchor_mode == 2 then
	bar_cfg.relative = "win"
	bar_cfg.win = panel_win
	bar_cfg.row = panel_height + row_adjust
	bar_cfg.col = 0
end
local bar_win = vim.api.nvim_open_win(bar_buf, false, bar_cfg)
local subagent_h = #bar_lines + 2

-- ── drill-in view (zindex 40) ───────────────────────────────────────────────
local pad_rows = subagent_h

-- Emulate init.lua set_bottom_pad(): the real panel reserves pad_rows at its bottom
-- with virt_lines and rests the transcript tail above them, so panel content never
-- draws into the band the bar occupies. Without this the panel has content at every
-- row and any uncovered row leaks a transcript line -- a harness artifact, not a bug.
if tonumber(vim.env.PANEL_PAD or "0") == 1 then
	local pad_ns = vim.api.nvim_create_namespace("probe_panel_pad")
	local virt_lines = {}
	for _ = 1, pad_rows do
		virt_lines[#virt_lines + 1] = { { "", "NonText" } }
	end
	vim.api.nvim_buf_set_extmark(panel_buf, pad_ns, #transcript_lines - 1, 0, {
		virt_lines = virt_lines,
	})
	vim.api.nvim_win_set_cursor(panel_win, { #transcript_lines, 0 })
	vim.api.nvim_win_call(panel_win, function()
		vim.cmd("normal! zb")
	end)
end
local view_col, view_w = panel_float_geom()
local total_h = math.max(panel_height - pad_rows, 5)

local view_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(view_buf, 0, -1, false, transcript_lines)
local view_win = vim.api.nvim_open_win(view_buf, false, {
	relative = "editor",
	anchor = "NW",
	row = panel_row,
	col = view_col,
	width = math.max(view_w, 1),
	height = total_h - 2,
	style = "minimal",
	zindex = 40,
	border = "rounded",
})

-- ── title tag (zindex 60) ───────────────────────────────────────────────────
local tag_label = " TAGCARD "
local tag_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tag_buf, 0, -1, false, { tag_label })
local tag_win = vim.api.nvim_open_win(tag_buf, false, {
	relative = "editor",
	anchor = "NE",
	row = panel_row + total_h - 1,
	col = view_col + view_w,
	width = #tag_label,
	height = 1,
	style = "minimal",
	focusable = false,
	zindex = 60,
})

-- ── permission modal (zindex 60), positioned by widgets.lua float_bottom_row() ──
-- float_bottom_row() is one of the three `vim.o.lines - 2` sites NOT changed by the
-- bar fix. Modelled here to check the two still stack flush: the modal's bottom
-- border should sit exactly one row above the bar's top border, no gap.
local PERM_ROWS = tonumber(vim.env.PERM_ROWS or "0")
if PERM_ROWS > 0 then
	local perm_buf = vim.api.nvim_create_buf(false, true)
	local perm_lines = {}
	for row_index = 1, PERM_ROWS do
		perm_lines[row_index] = "PERMROW" .. row_index
	end
	vim.api.nvim_buf_set_lines(perm_buf, 0, -1, false, perm_lines)

	-- widgets.lua: float_bottom_row() = vim.o.lines - 2 - subagent_height() - todo_height()
	-- FIX_FLOATROW=1 swaps in the panel-relative base the bar fix now uses.
	local float_bottom_row = tonumber(vim.env.FIX_FLOATROW or "0") == 1 and (panel_row + panel_height - subagent_h)
		or (vim.o.lines - 2 - subagent_h)

	vim.api.nvim_open_win(perm_buf, false, {
		relative = "editor",
		anchor = "SW",
		row = float_bottom_row,
		col = bar_col,
		width = math.max(bar_width_base - 2, 1),
		height = #perm_lines,
		style = "minimal",
		focusable = false,
		zindex = 60,
		border = "rounded",
		title = " PERMISSION ",
		title_pos = "left",
	})
end

-- ── census: what the code ASSUMED vs what nvim REPORTS ──────────────────────
local function footprint(win, has_border)
	local position = vim.api.nvim_win_get_position(win)
	local height = vim.api.nvim_win_get_height(win)
	local text_top = position[1]
	local text_bottom = text_top + height - 1
	if has_border then
		return text_top - 1, text_bottom + 1, text_top, text_bottom
	end
	return text_top, text_bottom, text_top, text_bottom
end

local census = io.open(CENSUS_PATH, "w")
local function record(...)
	census:write(table.concat({ ... }, " ") .. "\n")
end

record("screen lines/columns  :", vim.o.lines, vim.o.columns)
record("panel_row / panel_h   :", panel_row, panel_height)
record("pad_rows / subagent_h :", pad_rows, subagent_h)
record("total_h               :", total_h)
record("")

local view_top, view_bottom, view_text_top, view_text_bottom = footprint(view_win, true)
record(
	"VIEW  footprint rows  :",
	view_top .. ".." .. view_bottom,
	"(text " .. view_text_top .. ".." .. view_text_bottom .. ")"
)
local bar_top, bar_bottom, bar_text_top, bar_text_bottom = footprint(bar_win, true)
record(
	"BAR   footprint rows  :",
	bar_top .. ".." .. bar_bottom,
	"(text " .. bar_text_top .. ".." .. bar_text_bottom .. ")"
)
local tag_top, tag_bottom = footprint(tag_win, false)
record("TAG   footprint rows  :", tag_top .. ".." .. tag_bottom)
record("")
record("CODE assumed view bottom border :", panel_row + total_h - 1)
record("REAL  view bottom border        :", view_bottom)
record("tag placed at row               :", tag_top)
record("")
if tag_top >= view_text_top and tag_top <= view_text_bottom then
	record("TAG OVERLAPS VIEW TEXT -> clips transcript row", tag_top)
elseif tag_top == view_bottom then
	record("TAG sits on the view bottom border (intended)")
else
	record("TAG sits OUTSIDE the view; gap/overlap vs bar top", bar_top)
end
if view_bottom >= bar_top then
	record("VIEW OVERLAPS BAR: view bottom", view_bottom, ">= bar top", bar_top)
else
	record("gap rows between view bottom and bar top:", bar_top - view_bottom - 1)
end
census:close()

vim.cmd("redraw")
