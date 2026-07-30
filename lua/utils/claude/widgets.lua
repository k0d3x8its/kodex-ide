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
-- Dependencies: core.state, and the init-owned float/pad helpers injected via
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
local pet_reserved_cols -- columns Clawd occupies; the drill-in tag must not share them

--- Inject init's float/pad helpers. Called once from init after they are defined.
function Widgets.wire(hooks)
	set_bottom_pad = hooks.set_bottom_pad
	panel_float_geom = hooks.panel_float_geom
	harden_float_scroll = hooks.harden_float_scroll
	pet_reserved_cols = hooks.pet_reserved_cols
end

-- Cap on how many display rows the overlay grows to (opts.at mode) before it stops
-- expanding and just scrolls internally — a runaway note must not swallow the panel.
local PROMPT_OVERLAY_MAX_ROWS = 6

-- ─── Shared focused text-prompt float ────────────────────────────────────────
-- A dedicated FOCUSED float in the panel column (NOT vim.ui.input): dressing routes
-- vim.ui.input to a cursor-relative float that opens BEHIND a modal card (the card
-- holds focus + a higher draw position), so the user's typing would land in an
-- invisible window. This float anchors SW at the panel column with a zindex ABOVE
-- any card (70 > 60), focused + in insert mode, so what's typed is always visible.
-- <CR> commits (fires on_commit with the typed text, "" when blank), <Esc> cancels
-- (fires on_commit(nil) — distinct from a blank commit so callers can keep an
-- existing value on cancel). `initial` pre-fills the input so an existing value is
-- edited/repopulated rather than retyped.
--
-- Extracted from question.lua (permission-card Tab-to-annotate feature) so BOTH the
-- question card ("Type something"/"n to add notes") and the permission card (Tab to
-- attach a note to a decision) share one float instead of duplicating the geometry/
-- prompt-buffer/insert-mode plumbing. Callers that only make sense while their own
-- modal is still up pass `opts.guard()` (checked before opening AND before finish
-- fires — the modal may have gone away while the user was typing) and
-- `opts.refocus()` (returns the window to restore focus to on close, or nil).
--
-- Positioning: default anchors "editor"-relative at the shared panel-bottom row
-- (question.lua's original behaviour, unchanged). `opts.at = {win, row}` OVERLAYS
-- the float at a SPECIFIC local row inside another window (win-relative, anchor
-- NW — grows DOWNWARD from that row) instead of stacking beside it: the permission
-- card's note float pins itself directly at the hint line's own buffer row and
-- paints over the command block beneath it as the note grows, per the user's own
-- mockup ("this line turns into the condensed note bar... overlapping the command
-- below") — no reflow, no separate geometry to keep in sync with the card's height
-- at all. In this mode the float ALSO grows with typed content (word-wrap driven,
-- capped at PROMPT_OVERLAY_MAX_ROWS) instead of staying fixed at 1 row — see the
-- TextChangedI autocmd below. (An earlier `opts.above_win` mode — stack ABOVE a
-- window via win-relative anchor SW — was tried first for this same caller,
-- live-tested with too large a gap, and is gone now that `at` replaced it; no
-- caller needs "stack beside" any more, so it wasn't kept as a maybe-useful path.)
function Widgets.open_prompt_float(title, initial, on_commit, opts)
	opts = opts or {}
	if opts.guard and not opts.guard() then
		return
	end
	local float_col, float_w = panel_float_geom()

	local prompt_relative, prompt_win, prompt_row, prompt_col, prompt_anchor, prompt_width =
		"editor", nil, Widgets.float_bottom_row(), float_col, "SW", float_w
	if opts.at and opts.at.win and vim.api.nvim_win_is_valid(opts.at.win) then
		-- Width derived from the ANCHOR window's actual current width
		-- (nvim_win_get_width), not re-derived via a fresh panel_float_geom() call
		-- (an earlier version did that, assuming it always matches the card's real
		-- width — wrong, live-tested).
		--
		-- Margin is DELIBERATELY asymmetric: col=1 (left margin 1) confirmed correct
		-- live (screenshot showed a clean small gap on the left); a SYMMETRIC
		-- `width = anchor_width - 2` (implying an equal 1-col margin on the right
		-- too) still overlapped the card's border on the right in that same
		-- screenshot. Rather than re-derive nvim's `relative="win"` border/width
		-- semantics offline a further time (this exact spot already had two
		-- symmetric-math misses this session), the fix is evidence-driven: keep the
		-- working left margin, subtract one MORE column of width so the right edge
		-- pulls in by one column beyond what the symmetric formula gave it.
		local anchor_width = vim.api.nvim_win_get_width(opts.at.win)
		prompt_relative, prompt_win, prompt_row, prompt_col, prompt_anchor, prompt_width =
			"win", opts.at.win, opts.at.row, 1, "NW", anchor_width - 3
	end

	-- A prompt buffer (not a plain scratch) so it carries the same green "❯" arrow as
	-- the chat bar: prompt_setprompt draws the arrow, matchadd colours it terminal-
	-- green (ClaudeArrow), and <CR> fires prompt_setcallback with the typed text.
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buftype = "prompt"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = prompt_relative,
		win = prompt_win,
		anchor = prompt_anchor,
		row = prompt_row,
		col = prompt_col,
		width = prompt_width,
		height = 1,
		border = "rounded",
		style = "minimal",
		title = title,
		title_pos = "left",
		zindex = 70,
	})
	vim.wo[win].winhighlight = "FloatBorder:ClaudeBarBorder,FloatTitle:ClaudeBarBorder,NormalFloat:ClaudeBarBg"

	-- Overlay mode only: this float is `relative="win"` to the anchor card — if
	-- that card closes by ANY path while the overlay is still open (CLI death/
	-- reset via abort_permission_cards, a concurrent queue-drain, anything other
	-- than this float's own finish()), nvim does not auto-close a dependent float
	-- when its anchor dies; it's left orphaned and can be repositioned against
	-- whatever window/buffer is current, which is how it ends up drawn over
	-- unrelated content (live-reported: stray note box over the editor pane).
	-- A `relative="win"` float must not be able to outlive its anchor — that's a
	-- structural invariant, not conditional on identifying which path triggered
	-- it. Close ONLY this window directly (not via finish()/on_commit — those
	-- assume the card still exists to refocus/resolve against; the card is
	-- already gone by the time this fires). `once` because this float's own
	-- normal close (finish()) already tears it down before the card ever closes
	-- in the ordinary path, so this only fires in the orphan case.
	if opts.at then
		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(opts.at.win),
			once = true,
			callback = function()
				if vim.api.nvim_win_is_valid(win) then
					pcall(vim.api.nvim_win_close, win, true)
				end
			end,
		})
	end

	-- Overlay mode wraps + grows with content (see the TextChangedI autocmd below);
	-- every other mode stays the original fixed-1-row, no-wrap single input line.
	vim.wo[win].wrap = (opts.at ~= nil)

	-- Green "❯ " prompt arrow, matching the chat bar (window-local match, set while
	-- this float is the current window).
	vim.fn.prompt_setprompt(buf, "❯ ")
	vim.fn.matchadd("ClaudeArrow", "^❯")
	-- Show the cursor while typing (the panel hides it globally via guicursor).
	vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

	-- Close the input, refocus the caller's window, then hand the typed text to
	-- on_commit. Guarded so the prompt callback + an <Esc>/WinLeave can't both fire it.
	local done = false
	local function finish(text)
		if done then
			return
		end
		done = true
		vim.o.guicursor = "a:ver1-ClaudeCursorHidden" -- re-hide; focus returns to panel
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if opts.guard and not opts.guard() then
			return
		end -- caller's modal gone while typing
		local refocus_win = opts.refocus and opts.refocus()
		if refocus_win and vim.api.nvim_win_is_valid(refocus_win) then
			pcall(vim.api.nvim_set_current_win, refocus_win)
		end
		-- Closing the prompt float leaves the editor in insert mode; the card's keymaps
		-- are normal-mode, so without this the arrows are dead until the user drops out
		-- of insert manually.
		vim.cmd("stopinsert")
		on_commit(text)
	end

	vim.fn.prompt_setcallback(buf, function(text)
		finish(text)
	end)
	local kopts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("i", "<Esc>", function()
		finish(nil)
	end, kopts)
	vim.keymap.set("n", "<Esc>", function()
		finish(nil)
	end, kopts)

	-- Overlay mode only: grow the float's height as the note wraps to more display
	-- rows (word-wrap, not literal newlines — a prompt buffer's <CR> submits, it
	-- never inserts a line). Capped at PROMPT_OVERLAY_MAX_ROWS so a very long note
	-- scrolls internally instead of swallowing the panel. The autocmd is scoped to
	-- this buffer and dies with it (bufhidden=wipe), so no manual teardown needed.
	if opts.at then
		local function fit_overlay_height()
			if not vim.api.nvim_win_is_valid(win) then
				return
			end
			local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
			local rows =
				math.min(math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / prompt_width)), PROMPT_OVERLAY_MAX_ROWS)
			pcall(vim.api.nvim_win_set_height, win, rows)
		end
		vim.api.nvim_create_autocmd("TextChangedI", {
			buffer = buf,
			callback = fit_overlay_height,
		})
	end

	vim.cmd("startinsert!")
	-- Pre-fill with the existing value so it can be edited/repopulated. Typed AFTER
	-- startinsert! (in insert mode) so it lands in the prompt line past the "❯ " arrow;
	-- "n" = no remap, plain literal text (the note never contains termcodes).
	if initial and initial ~= "" then
		vim.api.nvim_feedkeys(initial, "n", false)
	end
end

-- ─── Search-tool classifier ──────────────────────────────────────────────────
-- Descriptor for a search tool_use, or nil if it isn't a search. Covers the Grep/
-- Glob TOOLS (clean output) and search-shaped Bash COMMANDS (headless reality: the
-- panel's claude has NO Grep/Glob tool, so it searches via Bash). { verb, pattern,
-- files } — `files` (clean path-list output) gates the count-header + `└ file` list.
-- Search-shaped shell commands → the verb they read as.
local SEARCH_CMDS = {
	rg = "Searching",
	grep = "Searching",
	egrep = "Searching",
	fgrep = "Searching",
	["ast-grep"] = "Searching",
	sg = "Searching",
	fd = "Listing",
	fdfind = "Listing",
	find = "Listing",
}
-- Flags that make a search emit a bare FILE LIST rather than match lines.
local function files_mode(base, cmd)
	if base == "fd" or base == "fdfind" or base == "find" then
		return true
	end
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
		if type(cmd) ~= "string" or cmd == "" then
			return nil
		end
		-- Leading command word, past any "cd X &&" prefix; basename if a path.
		local c = (cmd:match("&&%s*(.+)$") or cmd):gsub("^%s+", "")
		local word = c:match("^([%w%-%._/]+)")
		local base = word and (word:match("([^/]+)$") or word)
		local verb = base and SEARCH_CMDS[base]
		if not verb then
			return nil
		end
		-- Pattern: prefer the first quoted string (keeps multi-word patterns whole),
		-- else the first non-flag token. Strip any surrounding quotes either way.
		local pat = c:match('"([^"]*)"') or c:match("'([^']*)'")
		if not pat then
			for tok in c:gmatch("%S+") do
				if tok ~= base and not tok:match("^%-") then
					pat = tok
					break
				end
			end
			if pat then
				pat = pat:gsub("^[\"']", ""):gsub("[\"']$", "")
			end
		end
		return { verb = verb, pattern = pat or c, files = files_mode(base, c) }
	end
	return nil
end

-- ─── Task-plan card widget (bottom-pinned float) ─────────────────────────────

-- Render the task list to (lines, hls): a dim "N tasks (X done, Y in progress,
-- Z open)" header, then one row per task (✔ done strikethrough / ▦ in-progress
-- orange / □ pending), capped at CAP with a "… +N more" tail. hls[i] is a list of
-- {b0, b1, group} spans. Pure — unit-tested directly.
local CAP = 8
local GLYPH = { completed = "✔", in_progress = "▦", pending = "□" }
local TEXTHL = {
	completed = "ClaudeTodoDone",
	in_progress = "ClaudeTodoActive",
	pending = "ClaudeTodoPending",
}
-- Count tasks by status. Anything not completed/in_progress counts as open.
local function counts(todos)
	local done, active, open = 0, 0, 0
	for _, t in ipairs(todos) do
		local s = t.status
		if s == "completed" then
			done = done + 1
		elseif s == "in_progress" then
			active = active + 1
		else
			open = open + 1
		end
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
	local header =
		string.format("%d task%s (%d done, %d in progress, %d open)", n, n == 1 and "" or "s", done, active, open)
	local lines, hls = { PAD .. header }, { { { 0, -1, "ClaudeTodoHeader" } } }

	local shown, more = n, 0
	if n > CAP then
		shown, more = CAP - 1, n - (CAP - 1)
	end
	for i = 1, shown do
		local t = todos[i]
		local status = t.status or "pending"
		local glyph = GLYPH[status] or GLYPH.pending
		-- In-progress tasks read better in their gerund activeForm ("Applying …").
		local text = (status == "in_progress" and t.activeForm and t.activeForm ~= "") and t.activeForm
			or (t.content or "")
		lines[#lines + 1] = PAD .. glyph .. " " .. text
		local glyph_hl = status == "completed" and "ClaudeTodoCheck" or (TEXTHL[status] or "ClaudeTodoPending")
		hls[#hls + 1] = {
			{ #PAD, #PAD + #glyph, glyph_hl }, -- status glyph
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
-- chat pad add this so they stack ABOVE the task list.
function Widgets.todo_height()
	return (state.todos and #state.todos > 0) and (state.todo_h or 0) or 0
end

-- Rows the subagent switcher bar occupies (0 when hidden). Bottom floats + the
-- Task-plan card add this so they stack ABOVE the switcher (bottommost card).
function Widgets.subagent_height()
	return (state.subagents and #state.subagents > 0) and (state.subagent_h or 0) or 0
end

-- Absolute SW `row` that sits a float flush against the panel's bottom edge, taken
-- from the PANEL WINDOW's own geometry. The old `vim.o.lines - 2` assumed exactly one
-- statusline plus one cmdline row, so at cmdheight=0 every bottom float drifted a row
-- (see subagent_bar_position). Falls back to the old expression only when the panel
-- is gone, where there is no better answer.
local function panel_bottom_row()
	if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
		return vim.api.nvim_win_get_position(state.panel_win)[1] + vim.api.nvim_win_get_height(state.panel_win)
	end
	return vim.o.lines - 2
end

-- SW `row` for a bottom float (chat bar / permission / question / diff): the
-- panel bottom, lifted above the Task-plan card AND the subagent switcher when
-- either is visible. Single source so every float + the resize handler stack
-- consistently. Bottom-to-top: subagent switcher, Task-plan card, then floats.
function Widgets.float_bottom_row()
	return panel_bottom_row() - Widgets.subagent_height() - Widgets.todo_height()
end

-- Close the task-list widget float (kept buffer is reused on next open).
function Widgets.close_todo_widget()
	if state.todo_resize_teardown then
		state.todo_resize_teardown()
		state.todo_resize_teardown = nil
	end
	if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
		pcall(vim.api.nvim_win_close, state.todo_win, true)
	end
	state.todo_win = nil
	state.todo_h = 0
	state.todo_done_pending = false
end

-- Position fields for the subagent switcher bar, anchored to the PANEL WINDOW rather
-- than an absolute `vim.o.lines - 2` row. That expression assumes exactly one
-- statusline plus one cmdline row: at cmdheight=0 the bar rendered one row too high
-- and its top border -- which carries the " ◇ Subagents " title -- was painted over by
-- the drill-in view's bottom border; at cmdheight=2 it left a blank gap row instead.
-- Letting nvim resolve the anchor against the panel is correct for every
-- cmdheight/laststatus/tabline combination (36/36 on the rendered-frame sweep).
--
-- NOTE: no `make test` spec can catch a regression here -- it is a paint fact, and the
-- geometry APIs report pre-clamp values (see global KNOWLEDGE.md). The proof lives in
-- tests/screen/; the spec assertion only guards the config SHAPE.
local function subagent_bar_position()
	return {
		relative = "win",
		win = state.panel_win,
		anchor = "SW",
		row = vim.api.nvim_win_get_height(state.panel_win),
		col = 0,
	}
end

-- Lift every currently-open bottom float above the task widget and re-reserve
-- transcript space. Called when the widget appears / changes height while floats
-- are already open (their open-time row is otherwise stale).
function Widgets.reflow_bottom_floats()
	-- Re-place the bottom-pinned cards first so their offsets are current: the
	-- subagent switcher pins to the very bottom, the Task-plan card lifts above it.
	-- (Both otherwise keep their open-time row, stale once the other appears.)
	if
		state.subagent_win
		and vim.api.nvim_win_is_valid(state.subagent_win)
		and state.panel_win
		and vim.api.nvim_win_is_valid(state.panel_win)
	then
		local c = vim.api.nvim_win_get_config(state.subagent_win)
		local position = subagent_bar_position()
		c.relative, c.win, c.row, c.col = position.relative, position.win, position.row, position.col
		pcall(vim.api.nvim_win_set_config, state.subagent_win, c)
	end
	if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
		local c = vim.api.nvim_win_get_config(state.todo_win)
		c.row = panel_bottom_row() - Widgets.subagent_height()
		pcall(vim.api.nvim_win_set_config, state.todo_win, c)
	end
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
	set_bottom_pad(state.chat_pad or 0) -- recompute total (chat base + widget)
end

-- True only when the plan is non-empty AND every task is completed. Pure — the
-- auto-dismiss decision is tested through this, not the timer.
function Widgets.plan_complete(todos)
	if not (todos and #todos > 0) then
		return false
	end
	for _, t in ipairs(todos) do
		if t.status ~= "completed" then
			return false
		end
	end
	return true
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
function Widgets.apply_task_tool(name, input)
	input = input or {}
	if name == "TaskCreate" then
		state.todos = state.todos or {}
		state.todo_seq = (state.todo_seq or 0) + 1
		state.todos[#state.todos + 1] = {
			id = state.todo_seq,
			content = input.subject or "",
			activeForm = input.activeForm,
			status = "pending",
		}
	elseif name == "TaskUpdate" then
		local id = tonumber(input.taskId)
		local todos = state.todos or {}
		if input.status == "deleted" then
			for i, t in ipairs(todos) do
				if t.id == id then
					table.remove(todos, i)
					break
				end
			end
		else
			for _, t in ipairs(todos) do
				if t.id == id then
					t.status = input.status or t.status
					break
				end
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
	if (state.todo_h or 0) ~= old_h then
		Widgets.reflow_bottom_floats()
	end

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
	if not (todos and #todos > 0) then
		Widgets.close_todo_widget()
		return
	end
	if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then
		return
	end

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
		relative = "editor",
		anchor = "SW",
		-- Lift above the subagent switcher (bottommost card) when it is visible.
		row = panel_bottom_row() - Widgets.subagent_height(),
		col = col,
		width = math.max(w - 2, 1),
		height = #lines,
		style = "minimal",
		focusable = false,
		zindex = 30, -- below modals (default 50)
		border = "rounded",
		title = " ✻ Task Plan ",
		title_pos = "left",
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
					return true -- gone → self-remove
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

-- ─── Subagent switcher bar (Goal 17.2) ────────────────────────────────────────

-- Token count in the reference switcher's compact form (74.5k, 1.2M, 980).
local function fmt_tokens(n)
	if type(n) ~= "number" then
		return nil
	end
	if n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	end
	if n >= 1e3 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(math.floor(n))
end

-- Duration (ms) in the reference form (2m 41s, 32s).
local function fmt_dur(ms)
	if type(ms) ~= "number" then
		return nil
	end
	local s = math.floor(ms / 1000)
	if s >= 60 then
		return string.format("%dm %ds", math.floor(s / 60), s % 60)
	end
	return s .. "s"
end

-- Live geometry instrumentation for the subagent drill-in/switcher-bar z-order bug
-- (CLAUDE-PANEL-TODOS.md #7 — two static zindex/geometry reads have already been
-- contradicted by live evidence: the math says no overlap, it visibly happens).
-- Mirrors init.lua's KODEX_CLAUDE_FOCUSLOG pattern. When $KODEX_CLAUDE_SUBAGENTLOG
-- points at a path, every switcher-bar render and drill-in geometry event appends one
-- line with the REAL on-screen row/height of both floats (read back via
-- nvim_win_get_config, not the just-computed values — so a stale-vs-actual mismatch
-- would show up here) plus pad_rows/subagent_h, so a live repro can be diffed against
-- what each side's geometry actually was at that instant. Off by default (nil env =
-- zero overhead). Recipe:
--   KODEX_CLAUDE_SUBAGENTLOG=/tmp/claude-subagent.log nvim
-- then reproduce the overlap and read the log.
-- MUST stay above every caller in this file (update_subagent_bar/fit_subagent_view/
-- open_subagent_view) — a `local function` is only visible to code lexically AFTER
-- its declaration; placing this block further down silently turned every call from
-- an earlier function into a call to an undeclared GLOBAL, which threw
-- "attempt to call global 'subagentlog' (a nil value)" — caught live via the user's
-- running --listen socket, 2026-07-24 (see .work/GATES.md, bug #7 investigation).
local subagentlog_path = vim.env.KODEX_CLAUDE_SUBAGENTLOG
local function subagentlog(tag)
	if not subagentlog_path then
		return
	end
	local ph = state.panel_win
		and vim.api.nvim_win_is_valid(state.panel_win)
		and vim.api.nvim_win_get_height(state.panel_win)
	local bar_row, bar_h
	if state.subagent_win and vim.api.nvim_win_is_valid(state.subagent_win) then
		local c = vim.api.nvim_win_get_config(state.subagent_win)
		bar_row, bar_h = c.row, c.height
	end
	local view_row, view_h
	if state.subagent_view_win and vim.api.nvim_win_is_valid(state.subagent_view_win) then
		local c = vim.api.nvim_win_get_config(state.subagent_view_win)
		view_row, view_h = c.row, c.height
	end
	local line = string.format(
		"%d %-20s ph=%-4s pad_rows=%-4s subagent_h=%-4s bar(row=%s h=%s) view(row=%s h=%s)",
		vim.loop.now(),
		tag,
		tostring(ph),
		tostring(state.pad_rows),
		tostring(state.subagent_h),
		tostring(bar_row),
		tostring(bar_h),
		tostring(view_row),
		tostring(view_h)
	)
	local fh = io.open(subagentlog_path, "a")
	if fh then
		fh:write(line, "\n")
		fh:close()
	end
end

-- Truncate a string to at most `cols` display columns (multibyte-safe), adding a
-- single "…" when it overflows. Used so a long subagent description can't push the
-- status/token meta off the right edge of the card (the live "@@@" overflow bug).
local function trunc_display(s, cols)
	if cols <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(s) <= cols then
		return s
	end
	local out = vim.fn.strcharpart(s, 0, math.max(cols - 1, 0))
	while vim.fn.strdisplaywidth(out) > cols - 1 and #out > 0 do
		out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
	end
	return out .. "…"
end

-- Split `s` at the last word boundary that still fits `w` display columns,
-- falling back to a hard character break when a single token is wider than
-- `w` on its own. Returns (first_chunk, remainder-or-nil). Used to wrap a
-- switcher-row label onto one continuation line instead of cutting it with
-- "…" mid-word (CLAUDE-PANEL-TODOS.md linebreak bug).
local function split_at_width(s, w)
	if vim.fn.strdisplaywidth(s) <= w then
		return s, nil
	end
	local best_space = nil
	for pos in s:gmatch("() ") do
		if vim.fn.strdisplaywidth(s:sub(1, pos - 1)) <= w then
			best_space = pos
		else
			break
		end
	end
	if best_space then
		-- The model/desc separator is TWO spaces ("neoclaude" .. "  " .. desc):
		-- trim so neither a trailing space on line 1 nor a leading one on the
		-- continuation shifts that row's indent by a column.
		local head = s:sub(1, best_space - 1):gsub("%s+$", "")
		local rest = s:sub(best_space + 1):gsub("^%s+", "")
		return head, (rest ~= "" and rest or nil)
	end
	local head = vim.fn.strcharpart(s, 0, w)
	while vim.fn.strdisplaywidth(head) > w and #head > 0 do
		head = vim.fn.strcharpart(head, 0, vim.fn.strchars(head) - 1)
	end
	local rest = s:sub(#head + 1)
	return head, (rest ~= "" and rest or nil)
end

-- Build the switcher rows + per-row highlight spans. Row 1 is the "main"
-- pseudo-entry (selecting it returns to the main transcript); rows 2..N+1 are the
-- captured subagents in order. The selected row (state.subagent_sel, 1-based)
-- gets a green filled ● (ClaudeAdvisor); the rest a dim hollow ○ (ClaudeDim) —
-- reference-faithful. Byte spans are ASCII-safe up to the glyph; the ● / ○ / ↓
-- are multibyte, so meta spans are measured off the built string, not char counts.
-- A label that overflows the card wraps onto ONE indented continuation line
-- (the (dim) meta always stays on line 1); if the continuation is STILL too
-- long it gets the old ellipsis truncation as a backstop against an unbounded
-- bar height.
function Widgets.render_subagent_lines()
	local subs = state.subagents or {}
	local sel = state.subagent_sel or 1
	local lines, hls = {}, {}

	-- Inner text budget = card width (panel column minus its 2 border cells).
	local _, w = panel_float_geom()
	local budget = math.max((w or 40) - 2, 12)

	local function add_row(idx, label, meta)
		local glyph = (idx == sel) and "●" or "○"
		local ghl = (idx == sel) and "ClaudeAdvisor" or "ClaudeDim"
		local prefix = " " .. glyph .. " "
		local prefix_w = vim.fn.strdisplaywidth(prefix)
		-- Reserve room for the glyph + spaces + meta segment, then fit the label;
		-- overflow wraps onto a continuation line instead of truncating in place.
		local seg = (meta and meta ~= "") and ("   " .. meta) or ""
		local seg_w = vim.fn.strdisplaywidth(seg)
		local first_budget = math.max(budget - prefix_w - seg_w, 4)
		local first_line_label, rest = split_at_width(label, first_budget)

		local text = prefix .. first_line_label
		local spans = { { 1, 1 + #glyph, ghl } } -- colour just the selection glyph
		if seg ~= "" then
			spans[#spans + 1] = { #text, #text + #seg, "ClaudeDim" }
			text = text .. seg
		end
		lines[#lines + 1] = text
		hls[#hls + 1] = spans

		if rest then
			local cont_budget = math.max(budget - prefix_w, 4)
			lines[#lines + 1] = string.rep(" ", prefix_w) .. trunc_display(rest, cont_budget)
			hls[#hls + 1] = {}
		end
	end

	add_row(1, "main", nil)
	for i, s in ipairs(subs) do
		-- Name column = the subagent's model once known (else the neoclaude brand).
		local label = (s.model or "neoclaude") .. "  " .. (s.desc or "")
		local meta
		if s.status == "completed" and type(s.usage) == "table" then
			-- Final numbers from system/task_notification.usage (FINDINGS § Q-SUBAGENT-STREAM).
			local du, tk = fmt_dur(s.usage.duration_ms), fmt_tokens(s.usage.total_tokens)
			meta = "✓ " .. (du and (du .. " · ") or "") .. (tk and ("↓ " .. tk .. " tokens") or "")
		else
			-- No live token count until the subagent completes; show its status word.
			meta = s.status or "running"
		end
		add_row(i + 1, label, meta)
	end
	return lines, hls
end

-- Close the switcher float (kept buffer is reused on next open).
function Widgets.close_subagent_bar()
	if state.subagent_resize_teardown then
		state.subagent_resize_teardown()
		state.subagent_resize_teardown = nil
	end
	if state.subagent_win and vim.api.nvim_win_is_valid(state.subagent_win) then
		pcall(vim.api.nvim_win_close, state.subagent_win, true)
	end
	state.subagent_win = nil
	state.subagent_h = 0
end

-- Open or update the bottom-pinned subagent switcher from state.subagents. Same
-- bordered-card styling as the Task-plan widget (rounded, amber outline, titled,
-- non-focusable), but pinned to the VERY bottom of the panel column — the Task
-- card + chat bar + modals stack above it via subagent_height(). Hidden (closed)
-- when no subagents exist. The caller reflows the other floats after.
function Widgets.update_subagent_bar()
	local subs = state.subagents
	if not (subs and #subs > 0) then
		Widgets.close_subagent_bar()
		return
	end
	if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then
		return
	end

	-- A row's height is no longer fixed at 1 line per subagent — a status/meta
	-- change (e.g. "running" → "✓ 3s · ↓ 29.4k tokens") can push a label into
	-- wrap, growing the bar without the subagent COUNT changing. Callers that
	-- only expected a count-driven height change (task_updated/task_notification
	-- meta refreshes, mod.interrupt()) don't reflow after calling this — so
	-- reflow here, once, whenever the actual footprint changes, instead of
	-- auditing every call site. Cheap and idempotent (mirrors the VimResized
	-- autocmd below, which already reflows on every resize unconditionally).
	local prev_h = state.subagent_h

	local lines, hls = Widgets.render_subagent_lines()
	local buf = state.subagent_buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = vim.api.nvim_create_buf(false, true)
		state.subagent_buf = buf
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	state.subagent_ns = state.subagent_ns or vim.api.nvim_create_namespace("claude_subagent")
	vim.api.nvim_buf_clear_namespace(buf, state.subagent_ns, 0, -1)
	for i, spans in ipairs(hls) do
		for _, h in ipairs(spans) do
			vim.api.nvim_buf_add_highlight(buf, state.subagent_ns, h[3], i - 1, h[1], h[2])
		end
	end
	-- Footprint = content rows + 2 border, so subagent_height / float_bottom_row
	-- reserve the full bordered height and everything stacks above the top border.
	state.subagent_h = #lines + 2

	local _, w = panel_float_geom()
	local position = subagent_bar_position()
	local cfg = {
		relative = position.relative,
		win = position.win,
		anchor = position.anchor,
		row = position.row,
		col = position.col,
		width = math.max(w - 2, 1),
		height = #lines,
		style = "minimal",
		focusable = false,
		zindex = 30, -- below modals (default 50)
		border = "rounded",
		title = " ◇ Subagents (↑/↓ · Enter) ",
		title_pos = "left",
	}
	if state.subagent_win and vim.api.nvim_win_is_valid(state.subagent_win) then
		pcall(vim.api.nvim_win_set_config, state.subagent_win, cfg)
	else
		state.subagent_win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[state.subagent_win].winhl =
			"Normal:ClaudeNormal,NormalNC:ClaudeNormal,FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder"
		harden_float_scroll(state.subagent_win)
		-- Pins to the panel bottom (like the Task card), so it needs its own resize
		-- path: re-render at lines-2 + re-fit width, then reflow the cards/floats above.
		vim.api.nvim_create_augroup("ClaudeSubagentResize", { clear = true })
		vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
			group = "ClaudeSubagentResize",
			callback = function()
				if not (state.subagent_win and vim.api.nvim_win_is_valid(state.subagent_win)) then
					return true -- gone → self-remove
				end
				Widgets.update_subagent_bar()
				Widgets.reflow_bottom_floats()
			end,
		})
		state.subagent_resize_teardown = function()
			pcall(vim.api.nvim_del_augroup_by_name, "ClaudeSubagentResize")
		end
	end

	if state.subagent_h ~= prev_h then
		Widgets.reflow_bottom_floats()
	end
	subagentlog("update_subagent_bar")
end

-- Terminal (non-running) subagent statuses. task_updated/task_notification set
-- "completed"; keep the others so a failed/cancelled run still counts as "done"
-- for the auto-dismiss (else the bar would hang forever).
local TERMINAL_STATUS = { completed = true, failed = true, cancelled = true, error = true }

-- True only when there is ≥1 subagent AND every one has reached a terminal status.
function Widgets.subagents_all_done()
	local subs = state.subagents
	if not (subs and #subs > 0) then
		return false
	end
	for _, s in ipairs(subs) do
		if not TERMINAL_STATUS[s.status] then
			return false
		end
	end
	return true
end

-- Auto-dismiss the switcher once every subagent has finished — the real CC-TUI
-- hides it when nothing is live (user-confirmed 2026-07-06). Mirrors the Task-Plan
-- card: arm a single deferred close, re-check at fire time so a subagent spawned
-- within the window cancels it. Clears state so a later spawn starts a fresh list;
-- the finished subagents' output already rendered inline in main.
function Widgets.maybe_dismiss_subagents()
	if not Widgets.subagents_all_done() then
		state.subagent_dismiss_pending = false
		return
	end
	if state.subagent_dismiss_pending then
		return
	end
	state.subagent_dismiss_pending = true
	vim.defer_fn(function()
		state.subagent_dismiss_pending = false
		if Widgets.subagents_all_done() then
			Widgets.close_subagent_view()
			Widgets.close_subagent_bar()
			Widgets.wipe_subagent_buffers()
			state.subagents = nil
			state.subagent_sel = 1
			Widgets.reflow_bottom_floats()
		end
	end, 2500)
end

-- Move the switcher selection (state.subagent_sel, 1 = main). Returns false when
-- the bar isn't showing so the panel keymap can fall through to normal ↑/↓.
function Widgets.subagent_nav(delta)
	local subs = state.subagents
	if not (subs and #subs > 0) then
		return false
	end
	local n = #subs + 1
	local sel = (state.subagent_sel or 1) + delta
	if sel < 1 then
		sel = 1
	elseif sel > n then
		sel = n
	end
	state.subagent_sel = sel
	Widgets.update_subagent_bar()
	return true
end

-- Enter on the selected switcher row: main (sel 1) closes the drill-in view;
-- a subagent row opens/swaps to its transcript view. Returns false when no bar.
function Widgets.subagent_enter()
	local subs = state.subagents
	if not (subs and #subs > 0) then
		return false
	end
	if (state.subagent_sel or 1) <= 1 then
		-- Main row selected: normally just closes an (already-closed) drill-in view,
		-- a harmless no-op that still swallows the keypress. If a subagent was killed
		-- by an interrupt and nothing is running anymore, that no-op is actively
		-- unhelpful — there's no live subagent activity to shield the chat bar from,
		-- so let <CR> fall through to open_input() instead. A purely-completed
		-- session (no interrupts) keeps the existing drill-in-via-Enter behavior;
		-- this only fires once an abort has actually happened.
		local has_interrupted, any_running = false, false
		for _, s in ipairs(subs) do
			if s.status == "interrupted" then
				has_interrupted = true
			elseif s.status == "running" then
				any_running = true
			end
		end
		local view_open = state.subagent_view_win and vim.api.nvim_win_is_valid(state.subagent_view_win)
		if has_interrupted and not any_running and not view_open then
			return false
		end
		Widgets.close_subagent_view()
	else
		Widgets.open_subagent_view((state.subagent_sel or 1) - 1)
	end
	return true
end

-- ctrl+b: cycle the selection main → sub1 → … → subN → main AND open/close the
-- matching view in one keystroke (like ctrl+o expands). Returns false when no bar
-- so the panel keymap can fall through to the default <C-b> (page up).
function Widgets.subagent_cycle()
	local subs = state.subagents
	if not (subs and #subs > 0) then
		return false
	end
	local n = #subs + 1
	state.subagent_sel = ((state.subagent_sel or 1) % n) + 1 -- 1→2→…→n→1
	Widgets.update_subagent_bar()
	if (state.subagent_sel or 1) <= 1 then
		Widgets.close_subagent_view()
	else
		Widgets.open_subagent_view(state.subagent_sel - 1)
	end
	return true
end

-- Display lines (+ per-line hl spans) for ONE streamed subagent event. Compact
-- peek: text prose, tool headers, thinking markers, one-line tool-result corners.
-- Shared by the live appender and the full re-render.
-- Simple one-line-per-block fallback formatter for a subagent inner event. Kept
-- as the fallback for subagent_event_lines when the rich render.subagent_lines
-- formatter isn't reachable (it shouldn't happen at runtime — render is loaded by
-- dispatch time — but keeps widgets self-sufficient if called in isolation).
local function subagent_event_lines_basic(ev)
	local lines, hls = {}, {}
	local function push(text, hl)
		lines[#lines + 1] = text
		hls[#lines] = hl and { { 0, -1, hl } } or {}
	end
	if ev.type == "assistant" then
		for _, b in ipairs((ev.message or {}).content or {}) do
			if b.type == "text" and type(b.text) == "string" and b.text ~= "" then
				for _, ln in ipairs(vim.split(b.text, "\n", { plain = true })) do
					push("  " .. ln, nil)
				end
			elseif b.type == "thinking" then
				push("  ▸ Thinking", "ClaudeDim")
			elseif b.type == "tool_use" then
				local a = b.input or {}
				local arg = a.command or a.pattern or a.file_path or a.description or a.path or ""
				push("  ● " .. (b.name or "tool") .. "(" .. trunc_display(tostring(arg), 60) .. ")", nil)
			end
		end
	elseif ev.type == "user" then
		for _, b in ipairs((ev.message or {}).content or {}) do
			if b.type == "tool_result" then
				local body = b.content
				if type(body) == "table" then
					local parts = {}
					for _, c in ipairs(body) do
						parts[#parts + 1] = c.text or ""
					end
					body = table.concat(parts, " ")
				end
				body = tostring(body or ""):gsub("%s+", " ")
				push("    └ " .. trunc_display(body, 70), "ClaudeDim")
			end
		end
	end
	return lines, hls
end

-- Format one subagent inner event into (lines, hls) for its drill-in buffer.
-- Prefers render.subagent_lines (the RICH formatter — full thinking bodies,
-- cornered ●/└ tool blocks, wrapped coloured results) so the drill-in matches the
-- main panel. Pulled by LAZY require to dodge the top-level require cycle (render
-- requires widgets, so widgets can't require render at load); render is already
-- cached by the time any event streams, so this is a table lookup at runtime.
-- Falls back to the basic one-liner formatter if render is somehow unreachable.
local function subagent_event_lines(ev)
	local ok, render = pcall(require, require_prefix .. "render")
	if ok and render and render.subagent_lines then
		return render.subagent_lines(ev)
	end
	return subagent_event_lines_basic(ev)
end

-- Full re-render of a subagent's accumulated .events (used to seed/rebuild a view).
function Widgets.render_subagent_events(sub)
	local lines, hls = {}, {}
	for _, ev in ipairs(sub.events or {}) do
		local l, h = subagent_event_lines(ev)
		for k = 1, #l do
			lines[#lines + 1] = l[k]
			hls[#lines] = h[k]
		end
	end
	if #lines == 0 then
		lines = { "  (no inner activity captured yet)" }
		hls = { { { 0, -1, "ClaudeDim" } } }
	end
	return lines, hls
end

-- Append ONE streamed event to the subagent's OWN live buffer (created lazily). The
-- drill-in view shows this buffer directly, so it updates live while open — and is
-- already populated when opened later. Live-scrolls the view if it's showing this sub.
function Widgets.append_subagent_event(sub, ev)
	local lines, hls = subagent_event_lines(ev)
	if #lines == 0 then
		return
	end
	local buf = sub.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = vim.api.nvim_create_buf(false, true)
		sub.buf = buf
		sub.buf_ns = vim.api.nvim_create_namespace("claude_sub_" .. tostring(buf))
	end
	-- A fresh scratch buffer holds one empty line — overwrite it on the first append.
	local start = vim.api.nvim_buf_line_count(buf)
	if start == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == "" then
		start = 0
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
	vim.bo[buf].modifiable = false
	for r, spans in ipairs(hls) do
		for _, h in ipairs(spans) do
			vim.api.nvim_buf_add_highlight(buf, sub.buf_ns, h[3], start + r - 1, h[1], h[2])
		end
	end
	-- Live-follow if the drill-in is currently showing THIS subagent.
	if
		state.subagent_view
		and state.subagents
		and state.subagents[state.subagent_view] == sub
		and state.subagent_view_win
		and vim.api.nvim_win_is_valid(state.subagent_view_win)
	then
		pcall(vim.api.nvim_win_set_cursor, state.subagent_view_win, { vim.api.nvim_buf_line_count(buf), 0 })
	end
end

-- Delete the per-subagent live buffers (called before the session list is cleared).
function Widgets.wipe_subagent_buffers()
	for _, s in ipairs(state.subagents or {}) do
		if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
			pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
		end
		s.buf = nil
	end
end

-- Close the drill-in view + its title tag.
function Widgets.close_subagent_view()
	if state.subagent_tag_win and vim.api.nvim_win_is_valid(state.subagent_tag_win) then
		pcall(vim.api.nvim_win_close, state.subagent_tag_win, true)
	end
	state.subagent_tag_win = nil
	if state.subagent_view_win and vim.api.nvim_win_is_valid(state.subagent_view_win) then
		pcall(vim.api.nvim_win_close, state.subagent_view_win, true)
	end
	state.subagent_view_win = nil
	state.subagent_view = nil
	state.subagent_view_h = nil
end

-- Pin the green title tag to the BOTTOM-right corner of the drill-in view (just
-- above the agent modal). A tiny non-focusable float ` <desc> ` right-aligned on the
-- given border row (zindex above the view). Caller passes the view's bottom border row.
local function open_subagent_tag(sub, view_row, view_col, view_w)
	-- The tag shows the subagent TITLE (its description), matching the CC-TUI.
	local title = sub.desc or sub.kind or "subagent"
	-- Stop short of Clawd rather than running under him. He stands on this same
	-- bottom-border row, and his carrier is winblend=100 — nvim blends it against the
	-- BASE window, not this float, so any cell they share has its glyphs ERASED, not
	-- covered (live-reported as "the sprite's grey background hides the title"; it is
	-- erasure, so no highlight change can fix it). Reserving his columns keeps the
	-- whole title readable with him sitting immediately to its right.
	local reserved_cols = (pet_reserved_cols and pet_reserved_cols()) or 0
	local label = " " .. trunc_display(title, math.max(view_w - 4 - reserved_cols, 8)) .. " "
	local buf = state.subagent_tag_buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = vim.api.nvim_create_buf(false, true)
		state.subagent_tag_buf = buf
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label })
	vim.bo[buf].modifiable = false
	local tw = math.min(vim.fn.strdisplaywidth(label), math.max(view_w - 2 - reserved_cols, 4))
	local cfg = {
		relative = "editor",
		anchor = "NE",
		row = view_row,
		col = view_col + view_w - reserved_cols,
		width = tw,
		height = 1,
		style = "minimal",
		focusable = false,
		zindex = 60,
	}
	if state.subagent_tag_win and vim.api.nvim_win_is_valid(state.subagent_tag_win) then
		pcall(vim.api.nvim_win_set_config, state.subagent_tag_win, cfg)
	else
		state.subagent_tag_win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[state.subagent_tag_win].winhl = "Normal:ClaudeSubagentTag,NormalNC:ClaudeSubagentTag"
	end
end

-- Geometry for the drill-in view: a GREEN rounded-border float spanning the panel
-- column from its top row down to just ABOVE the bottom-float stack (agent modal /
-- permission modal / switcher), which occupies state.pad_rows rows. Sizing to leave
-- that band means those modals sit cleanly BELOW the view instead of a higher-zindex
-- float punching through its middle — Option A: the view is pushed UP as the
-- permission modal squeezes in between it and the agent modal. Returns
-- (cfg, prow, total_h, col, w); total_h is the on-screen height INCLUDING the border,
-- so the bottom border row is prow + total_h - 1 (where the tag pins).
local function subagent_view_geom()
	local col, w = panel_float_geom()
	local prow = vim.api.nvim_win_get_position(state.panel_win)[1]
	local ph = vim.api.nvim_win_get_height(state.panel_win)
	local total_h = math.max(ph - (state.pad_rows or 0), 5)
	local cfg = {
		relative = "editor",
		anchor = "NW",
		row = prow,
		col = col,
		width = math.max(w, 1),
		height = total_h - 2, -- -2 = border
		style = "minimal",
		zindex = 40,
		border = "rounded",
	}
	return cfg, prow, total_h, col, math.max(w, 1)
end

-- Re-fit the open drill-in view + its tag to the current bottom reserve. Hooked into
-- set_bottom_pad (the single choke point where the reserve changes — chat bar,
-- permission modal, widgets), so the view shrinks/grows to keep those modals below it.
-- Guarded on total_h so a streaming main transcript (which re-pads on every append)
-- doesn't churn the window config when nothing about the reserve actually changed.
function Widgets.fit_subagent_view()
	if not (state.subagent_view_win and vim.api.nvim_win_is_valid(state.subagent_view_win)) then
		return
	end
	if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then
		return
	end
	local cfg, prow, total_h, col, w = subagent_view_geom()
	if state.subagent_view_h == total_h then
		return
	end
	state.subagent_view_h = total_h
	pcall(vim.api.nvim_win_set_config, state.subagent_view_win, cfg)
	local sub = state.subagents and state.subagents[state.subagent_view]
	if sub then
		open_subagent_tag(sub, prow + total_h - 1, col, w)
	end
	subagentlog("fit_subagent_view")
end

-- Open (or swap) the drill-in view: a green-bordered float over the panel transcript
-- area, sitting ABOVE the bottom modals (agent modal + permission), so it reads like a
-- separate agent "session" showing just this subagent — with a green title tag pinned
-- to its BOTTOM-right border corner. Focusable + entered so q/<Esc> close it to main.
function Widgets.open_subagent_view(i)
	local subs = state.subagents
	local sub = subs and subs[i]
	if not sub then
		return
	end
	if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then
		return
	end

	-- Show the subagent's OWN live buffer (append_subagent_event streams into it), so
	-- the view updates live while open. Seed an empty one with a placeholder if the
	-- subagent hasn't emitted anything yet.
	local buf = sub.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = vim.api.nvim_create_buf(false, true)
		sub.buf = buf
		sub.buf_ns = vim.api.nvim_create_namespace("claude_sub_" .. tostring(buf))
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  (waiting for subagent activity…)" })
		vim.bo[buf].modifiable = false
	end

	local cfg, prow, total_h, col, w = subagent_view_geom()
	state.subagent_view_h = total_h
	if state.subagent_view_win and vim.api.nvim_win_is_valid(state.subagent_view_win) then
		pcall(vim.api.nvim_win_set_config, state.subagent_view_win, cfg)
		pcall(vim.api.nvim_win_set_buf, state.subagent_view_win, buf) -- swap to this sub
	else
		-- Open NON-entered, assign state, THEN focus. Entering inside nvim_open_win
		-- fires WinEnter DURING the call — before the return value is assigned — so the
		-- cursor backstop saw state.subagent_view_win == nil (active_modal_win), left the
		-- cursor visible, and only hid it when a later modal cycle re-fired WinEnter
		-- (live-reported 2026-07-15). Assigning first makes the backstop hide on first
		-- drill-in.
		state.subagent_view_win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[state.subagent_view_win].winhl =
			"Normal:ClaudeNormal,NormalNC:ClaudeNormal,FloatBorder:ClaudeSubagentBorder"
		vim.api.nvim_set_current_win(state.subagent_view_win) -- enter → q/Esc + cursor-hide
	end
	subagentlog("open_subagent_view")
	-- q/<Esc> close the view (set per shown buffer, idempotent).
	for _, k in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", k, function()
			Widgets.close_subagent_view()
		end, { buffer = buf, noremap = true, silent = true, desc = "Claude: close subagent view" })
	end
	-- ctrl+b keeps cycling while the view is focused (main → subs → main).
	vim.keymap.set("n", "<C-b>", function()
		Widgets.subagent_cycle()
	end, { buffer = buf, noremap = true, silent = true, desc = "Claude: cycle subagent views" })
	open_subagent_tag(sub, prow + total_h - 1, col, w) -- bottom-right border corner
	state.subagent_view = i
	-- Clawd deliberately STAYS visible over the drill-in view (user call, 2026-07-29).
	-- The old pet_hide()/pet_show() pair is gone: it never worked — teardown() leaves
	-- `ready` true, so the next pet.emit from the still-running subagent rebuilt him
	-- anyway, and rebuilding wiped current_asset/hold_cycle/pending_state, which is why
	-- the subagent activity animation stopped showing on drill-in. Collision with the
	-- title tag is handled by open_subagent_tag reserving his columns instead.
	-- Land at the bottom (latest activity), like a live transcript.
	pcall(vim.api.nvim_win_set_cursor, state.subagent_view_win, { vim.api.nvim_buf_line_count(buf), 0 })
end

return Widgets
