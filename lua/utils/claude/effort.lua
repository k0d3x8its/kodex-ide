-- lua/utils/claude/effort.lua
--
-- The /effort slider: a focusable modal float, anchored to the bottom of the panel,
-- that picks the CLI reasoning-effort level (low ─ medium ─ high ─ xhigh ─ max) on
-- a "Faster ─ Smarter" axis. Mirrors the Claude Code TUI's own /effort picker.
--
-- Why a modal (not the slash menu's inline float): effort is a one-of-five choice
-- with its OWN key handling (←/→ adjust, <CR> confirm, <Esc> cancel), so it takes
-- focus and owns its keymaps rather than riding the chat bar's keystrokes. As of
-- CLI 2.1.201 no live setter was found for changing effort mid-session (it's a
-- spawn-time --effort flag) — unconfirmed, see .work/CLAUDE-PANEL-TODOS.md #158 —
-- so confirming calls back into init's apply hook, which respawns the process
-- (same as --model).
--
-- Dependencies: core.state, widgets.float_bottom_row (panel-bottom anchor) and the
-- init-owned float/pad/queue helpers injected via Effort.wire{} — see the wire()
-- function below for the current list — same pattern as slash.lua/question.lua.

local Effort = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")
local state = core.state

-- Ordered levels, low→max, mapped left→right on the Faster→Smarter axis.
local LEVELS = { "low", "medium", "high", "xhigh", "max" }

-- Init-owned float helpers, injected by Effort.wire{} at load time.
local panel_float_geom
local harden_float_scroll
local attach_panel_float_resize
local set_bottom_pad
local clear_bottom_pad
local pet_attach_surface -- Clawd hops onto the modal's top border while it's open
local pet_attach_panel -- …and back to the panel corner on close
-- A question/permission card can arrive while this slider is up (see
-- show_question_card/show_permission_card's open-guards) and queue behind it —
-- unlike those cards, the slider has no queue of its own to hand off to on close,
-- so it must explicitly poke init to retry whatever's waiting.
local try_resume_decision_queues

--- Inject init's float helpers. Called once from init after they are defined.
function Effort.wire(hooks)
	panel_float_geom = hooks.panel_float_geom
	harden_float_scroll = hooks.harden_float_scroll
	attach_panel_float_resize = hooks.attach_panel_float_resize
	set_bottom_pad = hooks.set_bottom_pad
	clear_bottom_pad = hooks.clear_bottom_pad
	pet_attach_surface = hooks.pet_attach_surface
	pet_attach_panel = hooks.pet_attach_panel
	try_resume_decision_queues = hooks.try_resume_decision_queues
end

-- Live modal state (only ever one at a time). sel = 1-based index into LEVELS,
-- on_confirm = init's apply(level) callback, prev_win = window to refocus on close,
-- resize_close = detach fn for the resize-track augroup (attach_panel_float_resize).
local modal = { win = nil, buf = nil, ns = nil, sel = 1, on_confirm = nil, prev_win = nil, resize_close = nil }

--- True while the slider is open.
function Effort.active()
	return modal.win ~= nil and vim.api.nvim_win_is_valid(modal.win)
end

--- The modal's window (valid handle) while open, else nil. Consumed by init's
--- focus-trap so a panel click bounces focus back here instead of stranding it.
function Effort.win()
	if Effort.active() then
		return modal.win
	end
	return nil
end

-- Even column centres for the 5 slots across an interior [lm, W-rm]. Used by both
-- the marker row and the label row so the ▲ sits over its level. The panel is
-- user-resizable down to widths narrower than the 5-slot layout wants — span used
-- to floor at #LEVELS-1 regardless of width, which could push a center past the
-- last valid column index; clamp each one back into [0, width-1] so it never
-- indexes past the cell arrays render() builds at this same width.
local function slot_centers(width)
	local lm, rm = 2, 2
	local span = math.max(width - lm - rm - 1, 0)
	local max_col = math.max(width - 1, 0)
	local out = {}
	for i = 1, #LEVELS do
		out[i] = math.min(lm + math.floor(span * (i - 1) / (#LEVELS - 1)), max_col)
	end
	return out
end

-- Build a width-W line as a cell array (one string per display column), stamp
-- ASCII `text` starting at 0-based `col`, and return it. ASCII only, so cell index
-- == byte column for later highlight math.
local function blank(width)
	local c = {}
	for i = 1, width do
		c[i] = " "
	end
	return c
end
local function stamp(cells, col, text)
	for i = 1, #text do
		local p = col + i
		if p >= 1 and p <= #cells then
			cells[p] = text:sub(i, i)
		end
	end
end

-- Render the modal buffer + highlights from modal.sel.
local function render()
	if not (modal.buf and vim.api.nvim_buf_is_valid(modal.buf)) then
		return
	end
	local width = select(2, panel_float_geom())
	local centers = slot_centers(width)

	-- Axis labels row: "Faster" left, "Smarter" right-aligned.
	local axis = blank(width)
	stamp(axis, 2, "Faster")
	stamp(axis, width - 2 - #"Smarter", "Smarter")

	-- Track row: a horizontal rule with the ▲ marker over the selected slot.
	local track_cells = blank(width)
	for i = 3, width - 2 do
		track_cells[i] = "─"
	end
	track_cells[centers[modal.sel] + 1] = "▲"
	local track = table.concat(track_cells)

	-- Labels row (ASCII): each level centred on its slot; remember the selected
	-- span so it can be bolded.
	local labels = blank(width)
	local sel_start, sel_end
	for i, name in ipairs(LEVELS) do
		local start = centers[i] - math.floor(#name / 2)
		if start < 0 then
			start = 0
		end
		stamp(labels, start, name)
		if i == modal.sel then
			sel_start, sel_end = start, start + #name
		end
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
	band(0, "ClaudeEffortTitle") -- " Effort"
	band(2, "ClaudeEffortAxis") -- Faster / Smarter
	band(3, "ClaudeEffortAxis") -- track + marker
	band(6, "ClaudeEffortHint") -- footer
	-- Labels row (index 4): dim the whole row, then bold the selected span.
	band(4, "ClaudeEffortDim")
	if sel_start then
		vim.api.nvim_buf_set_extmark(modal.buf, ns, 4, sel_start, {
			end_col = sel_end,
			hl_group = "ClaudeEffortSel",
		})
	end
end

--- Close the slider without applying. Refocuses the panel window.
function Effort.close()
	local was_open = Effort.active()
	local win, prev_win, resize_close = modal.win, modal.prev_win, modal.resize_close
	-- Nil the tracked fields BEFORE closing the window (mirrors question.lua's
	-- close_question_card) so the WinClosed fallback autocmd below no-ops when THIS
	-- call is what triggers the close, instead of recursing back into Effort.close().
	modal.win, modal.buf, modal.ns, modal.on_confirm, modal.prev_win, modal.resize_close = nil, nil, nil, nil, nil, nil
	if resize_close then
		pcall(resize_close)
	end
	if win and vim.api.nvim_win_is_valid(win) then
		-- pcall'd: an uncaught throw here would abort close() before the rest of its
		-- teardown runs. confirm() itself is already safe either way (it reads
		-- modal.on_confirm as `cb` before calling this) — this guard is for the Esc/q
		-- cancel path and any future caller that expects close() to always finish.
		pcall(vim.api.nvim_win_close, win, true)
	end
	if prev_win and vim.api.nvim_win_is_valid(prev_win) then
		pcall(vim.api.nvim_set_current_win, prev_win)
	end
	if was_open and clear_bottom_pad then
		clear_bottom_pad()
	end
	if was_open and pet_attach_panel then
		pet_attach_panel()
	end
	-- A question/permission card may be queued behind this slider (see the wire-time
	-- doc above) — only worth trying if the slider was actually open (guards a no-op
	-- Effort.close() call from spuriously stealing a card that's blocking on something
	-- else entirely).
	if was_open and try_resume_decision_queues then
		pcall(try_resume_decision_queues)
	end
end

-- Move the selection (±1), clamped, and redraw.
local function move(delta)
	if not Effort.active() then
		return
	end
	modal.sel = math.min(math.max(modal.sel + delta, 1), #LEVELS)
	render()
end

-- Confirm the highlighted level: close, then hand it to init's apply hook.
local function confirm()
	local level, cb = LEVELS[modal.sel], modal.on_confirm
	Effort.close()
	if cb then
		cb(level)
	end
end

--- Open the slider. `current` is the level to preselect (defaults to medium),
--- `on_confirm(level)` fires when the user presses <CR>.
function Effort.open(current, on_confirm)
	if Effort.active() then
		Effort.close()
	end
	modal.sel = 2 -- medium
	for i, l in ipairs(LEVELS) do
		if l == current then
			modal.sel = i
		end
	end
	modal.on_confirm = on_confirm
	modal.prev_win = vim.api.nvim_get_current_win()
	modal.ns = vim.api.nvim_create_namespace("claude_effort_modal")
	modal.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[modal.buf].bufhidden = "wipe"

	local col, width = panel_float_geom()
	local bottom = widgets.float_bottom_row()
	modal.win = vim.api.nvim_open_win(modal.buf, true, {
		relative = "editor",
		anchor = "SW",
		row = bottom,
		col = col,
		width = width,
		height = 7,
		border = "rounded",
		style = "minimal",
		zindex = 75, -- above the chat bar / slash menu, alongside permission cards
	})
	vim.wo[modal.win].winhighlight = "NormalFloat:ClaudeSlashBg,FloatBorder:ClaudeSlashBorder"
	harden_float_scroll(modal.win)
	-- Reserve the modal's footprint as bottom padding (question.lua's card does the
	-- same) — without this, the fixed height=7 body + 2 rounded-border rows painted
	-- straight over live streaming transcript instead of pushing it above the modal.
	if set_bottom_pad then
		set_bottom_pad(9)
	end
	-- Track the panel column/width on resize and re-render against the new geometry
	-- (question.lua's card does the same) — without this, a resize while the slider
	-- is open left it built at the old width inside a window still at the old size.
	if attach_panel_float_resize then
		modal.resize_close = attach_panel_float_resize(modal.win, "ClaudeEffortFloat", render)
	end
	core.hide_modal_cursor() -- hide the cursor over the slider at open (see core doc)
	if pet_attach_surface then
		pet_attach_surface(modal.win)
	end

	-- Float vanished by some path OTHER than Effort.close() (e.g. an external
	-- nvim_win_close, or previously: no path at all — the teardown sweep didn't call
	-- Effort.close either, see abort_decision_state in render.lua) → run the same
	-- teardown so modal state doesn't strand a live, focusable, keymap-bound window.
	local opened_win = modal.win
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(opened_win),
		once = true,
		callback = function()
			if modal.win == opened_win then
				Effort.close()
			end
		end,
	})

	local function map(lhs, handler, desc)
		vim.keymap.set("n", lhs, handler, { buffer = modal.buf, nowait = true, silent = true, desc = desc })
	end
	map("<Left>", function()
		move(-1)
	end, "Effort slider: lower")
	map("<Right>", function()
		move(1)
	end, "Effort slider: raise")
	map("h", function()
		move(-1)
	end, "Effort slider: lower")
	map("l", function()
		move(1)
	end, "Effort slider: raise")
	map("k", function()
		move(-1)
	end, "Effort slider: lower")
	map("j", function()
		move(1)
	end, "Effort slider: raise")
	map("<CR>", confirm, "Effort slider: confirm")
	map("<Esc>", Effort.close, "Effort slider: cancel")
	map("q", Effort.close, "Effort slider: cancel")
	-- No close-on-focus-loss: init's WinEnter focus-trap keeps the panel from
	-- stealing focus (a click on the panel bounces back here), and <Esc>/q are the
	-- explicit dismiss. Alt+w still reaches the editor — only the panel is trapped.

	render()
end

--- The current effort level for the statusline (defaults to "medium" when unset,
--- matching the CLI's shown default).
function Effort.current()
	return state.effort or "medium"
end

return Effort
