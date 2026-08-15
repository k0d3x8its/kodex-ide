-- lua/utils/claude/advisor.lua
--
-- The /advisor picker: a focusable modal float, anchored to the bottom of the
-- panel, that chooses the server-side advisor model (the "advisor strategy": the
-- executor model escalates hard calls to a stronger advisor, then resumes).
-- Mirrors the Claude Code TUI's own /advisor picker (see the reference photo).
--
-- Why a modal (not the slash menu's inline float): the choice has its OWN key
-- handling (↑/↓ move, <CR> confirm, <Esc> cancel), so it takes focus and owns its
-- keymaps rather than riding the chat bar's keystrokes. Same shape as effort.lua,
-- but a VERTICAL list (one row per model) instead of a horizontal slider.
--
-- Unlike --model/--effort, the advisor changes mid-session WITHOUT a respawn: the
-- confirm callback (init's apply_advisor) sends an apply_flag_settings
-- control_request, so the conversation context is preserved.
--
-- Dependencies: core.state, widgets.float_bottom_row (panel-bottom anchor) and two
-- init-owned float helpers injected via Advisor.wire{} (panel_float_geom +
-- harden_float_scroll), same pattern as effort.lua/slash.lua/question.lua.

local Advisor = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")
local state = core.state

-- Ordered options, strongest-first, ending in "No advisor" (id = nil → unset the
-- advisorModel setting). id is the CLI alias passed to --advisor / apply_flag_settings.
local OPTIONS = {
	{ id = "opus", label = "Opus 5" },
	{ id = "sonnet", label = "Sonnet 5" },
	{ id = "fable", label = "Fable 5" },
	{ id = nil, label = "No advisor" },
}

-- One-line blurb + the recommended-setup note, shown above/below the list to
-- mirror the TUI. Kept short so it fits the narrow panel without heavy wrapping.
local BLURB = "When Claude needs stronger judgment it escalates to the advisor "
	.. "model, then resumes. Runs server-side; uses extra tokens."
local RECO = "Recommended: Sonnet as the main model with Opus as the advisor."

-- Init-owned float helpers, injected by Advisor.wire{} at load time.
local panel_float_geom
local harden_float_scroll
local pet_attach_surface -- Clawd hops onto the modal's top border while it's open
local pet_attach_panel -- …and back to the panel corner on close
-- A question/permission card can arrive while this picker is up (see
-- show_question_card/show_permission_card's open-guards) and queue behind it —
-- unlike those cards, the picker has no queue of its own to hand off to on close,
-- so it must explicitly poke init to retry whatever's waiting (mirrors effort.lua).
local try_resume_decision_queues

--- Inject init's float helpers. Called once from init after they are defined.
function Advisor.wire(hooks)
	panel_float_geom = hooks.panel_float_geom
	harden_float_scroll = hooks.harden_float_scroll
	try_resume_decision_queues = hooks.try_resume_decision_queues
	pet_attach_surface = hooks.pet_attach_surface
	pet_attach_panel = hooks.pet_attach_panel
end

-- Live modal state (only ever one at a time). sel = 1-based index into OPTIONS,
-- on_confirm = init's apply(id) callback, prev_win = window to refocus on close.
local modal = { win = nil, buf = nil, ns = nil, sel = 1, on_confirm = nil, prev_win = nil }

--- True while the picker is open.
function Advisor.active()
	return modal.win ~= nil and vim.api.nvim_win_is_valid(modal.win)
end

--- The modal's window (valid handle) while open, else nil. Consumed by init's
--- focus-trap so a panel click bounces focus back here instead of stranding it.
function Advisor.win()
	if Advisor.active() then
		return modal.win
	end
	return nil
end

-- Greedy word-wrap `text` to `width` columns; returns a list of lines. Used for
-- the blurb/recommended notes so they never overflow the panel-width float.
local function wrap(text, width)
	local out, line = {}, ""
	for word in text:gmatch("%S+") do
		if line == "" then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			out[#out + 1] = line
			line = word
		end
	end
	if line ~= "" then
		out[#out + 1] = line
	end
	return out
end

-- Which OPTIONS index matches the currently-active advisor (state.advisor_model),
-- so its row gets the ✔. Compared by id (nil == the "No advisor" row).
local function active_index()
	for i, o in ipairs(OPTIONS) do
		if o.id == state.advisor_model then
			return i
		end
	end
	return nil
end

-- Build the modal buffer + highlights from modal.sel. Returns the rendered line
-- count so open() can size the float to fit.
local function render()
	if not (modal.buf and vim.api.nvim_buf_is_valid(modal.buf)) then
		return 0
	end
	local width = select(2, panel_float_geom())
	local textw = math.max(width - 2, 20) -- 1-col inset each side for the blurb
	local activ = active_index()

	local lines, hls = {}, {} -- hls: { {lnum0, col0, col_end_or_-1, hl}, ... }
	local function add(text, hl, col0, col_end)
		lines[#lines + 1] = text
		if hl then
			hls[#hls + 1] = { #lines - 1, col0 or 0, col_end or -1, hl }
		end
	end

	add(" Advisor (experimental)", "ClaudeEffortTitle")
	add("")
	for _, l in ipairs(wrap(BLURB, textw)) do
		add(" " .. l, "ClaudeSlashDesc")
	end
	add("")

	-- The option rows. "> " cursor on the highlighted row; " ✔" trailing the row
	-- that is the currently-active advisor. Selected label bolded, others dim.
	local opt_first = #lines -- 0-based line index of the first option row
	for i, o in ipairs(OPTIONS) do
		local cursor = (i == modal.sel) and "> " or "  "
		local check = (i == activ) and "  ✔" or ""
		local text = cursor .. i .. ". " .. o.label .. check
		lines[#lines + 1] = text
		local ln = #lines - 1
		-- Whole row dim by default; bold the selected row's label span.
		hls[#hls + 1] = { ln, 0, -1, (i == modal.sel) and "ClaudeEffortSel" or "ClaudeEffortDim" }
		-- Green ✔ for the active advisor regardless of selection.
		if i == activ then
			hls[#hls + 1] = { ln, #text - #"✔", -1, "ClaudeTodoCheck" }
		end
	end
	local _ = opt_first

	add("")
	for _, l in ipairs(wrap(RECO, textw)) do
		add(" " .. l, "ClaudeSlashDesc")
	end
	add("")
	add(" ↑/↓ to move · Enter to confirm · Esc to cancel", "ClaudeEffortHint")

	vim.bo[modal.buf].modifiable = true
	vim.api.nvim_buf_set_lines(modal.buf, 0, -1, false, lines)
	vim.bo[modal.buf].modifiable = false

	local ns = modal.ns
	vim.api.nvim_buf_clear_namespace(modal.buf, ns, 0, -1)
	for _, h in ipairs(hls) do
		-- h[3] == -1 means "highlight to end of line": omit end_col entirely and set
		-- hl_eol (matching effort.lua). Do NOT write `end_col = cond and nil or h[3]`
		-- — Lua's `x and nil or y` always yields y, so that leaks -1 into end_col.
		local opts = { end_row = h[1] + 1, hl_group = h[4] }
		if h[3] == -1 then
			opts.hl_eol = true
		else
			opts.end_col = h[3]
		end
		vim.api.nvim_buf_set_extmark(modal.buf, ns, h[1], h[2], opts)
	end
	return #lines
end

--- Close the picker without applying. Refocuses the panel window.
function Advisor.close()
	local was_open = Advisor.active()
	local win, prev_win = modal.win, modal.prev_win
	-- Nil the tracked fields BEFORE closing the window (mirrors effort.lua/
	-- question.lua's close_question_card) so the WinClosed fallback autocmd below
	-- no-ops when THIS call is what triggers the close, instead of recursing.
	modal.win, modal.buf, modal.ns, modal.on_confirm, modal.prev_win = nil, nil, nil, nil, nil
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if prev_win and vim.api.nvim_win_is_valid(prev_win) then
		pcall(vim.api.nvim_set_current_win, prev_win)
	end
	if was_open and pet_attach_panel then
		pet_attach_panel()
	end
	-- A question/permission card may be queued behind this picker (see the wire-time
	-- doc above) — only worth trying if the picker was actually open.
	if was_open and try_resume_decision_queues then
		pcall(try_resume_decision_queues)
	end
end

-- Move the selection (±1), clamped, and redraw.
local function move(delta)
	if not Advisor.active() then
		return
	end
	modal.sel = math.min(math.max(modal.sel + delta, 1), #OPTIONS)
	render()
end

-- Confirm the highlighted option: close, then hand its id to init's apply hook.
local function confirm()
	local id, cb = OPTIONS[modal.sel].id, modal.on_confirm
	Advisor.close()
	if cb then
		cb(id)
	end
end

--- Open the picker. Preselects the currently-active advisor (or Opus 4.8 when
--- unset), `on_confirm(id)` fires when the user presses <CR> (id nil = No advisor).
function Advisor.open(on_confirm)
	if Advisor.active() then
		Advisor.close()
	end
	modal.sel = active_index() or 1
	modal.on_confirm = on_confirm
	modal.prev_win = vim.api.nvim_get_current_win()
	modal.ns = vim.api.nvim_create_namespace("claude_advisor_modal")
	modal.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[modal.buf].bufhidden = "wipe"

	local col, width = panel_float_geom()
	local bottom = widgets.float_bottom_row()
	-- Open at a provisional height, then re-fit to the rendered line count (the
	-- blurb/recommended wrap depends on the live panel width).
	modal.win = vim.api.nvim_open_win(modal.buf, true, {
		relative = "editor",
		anchor = "SW",
		row = bottom,
		col = col,
		width = width,
		height = 14,
		border = "rounded",
		style = "minimal",
		zindex = 75, -- above the chat bar / slash menu, alongside permission cards
	})
	vim.wo[modal.win].winhighlight = "NormalFloat:ClaudeSlashBg,FloatBorder:ClaudeSlashBorder"
	harden_float_scroll(modal.win)
	core.hide_modal_cursor() -- hide the cursor over the picker at open (see core doc)
	if pet_attach_surface then
		pet_attach_surface(modal.win)
	end

	-- Float vanished by some path OTHER than Advisor.close() → run the same teardown
	-- so modal state doesn't strand a live, focusable, keymap-bound window (mirrors
	-- effort.lua's identical fallback).
	local opened_win = modal.win
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(opened_win),
		once = true,
		callback = function()
			if modal.win == opened_win then
				Advisor.close()
			end
		end,
	})

	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = modal.buf, nowait = true, silent = true })
	end
	map("<Up>", function()
		move(-1)
	end)
	map("<Down>", function()
		move(1)
	end)
	map("k", function()
		move(-1)
	end)
	map("j", function()
		move(1)
	end)
	map("<CR>", confirm)
	map("<Esc>", Advisor.close)
	map("q", Advisor.close)
	-- No close-on-focus-loss: init's WinEnter focus-trap keeps the panel from
	-- stealing focus (a click on the panel bounces back here); <Esc>/q dismiss.

	local n = render()
	if modal.win and vim.api.nvim_win_is_valid(modal.win) then
		vim.api.nvim_win_set_config(modal.win, {
			relative = "editor",
			anchor = "SW",
			row = widgets.float_bottom_row(),
			col = col,
			width = width,
			height = n,
		})
	end
end

--- Friendly label of the currently-active advisor for the statusline, or "off".
function Advisor.current_label()
	local i = active_index()
	return i and OPTIONS[i].label or "off"
end

return Advisor
