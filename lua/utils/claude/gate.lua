-- lua/utils/claude/gate.lua
--
-- The permission / pre-write gate + diff-review card + the shared SW-anchored
-- panel-float helpers they all lean on. Everything here answers a can_use_tool
-- control_request the CLI can't auto-resolve: the interactive permission card
-- (Bash/WebFetch/out-of-cwd), the Issue-B pre-write diff gate for Edit/Write, and
-- the Accept/Reject diff-review card. Extracted from the former monolithic
-- claude.lua to relieve init's main-chunk 200-local ceiling.
--
-- Dependencies: core.state + core buffer helpers (state/buf_append/hl_lines/
-- panel_width) come from a direct require; five init-owned helpers
-- (start_spinner/stop_spinner/clear_hint, prompt_input as a thunk, and
-- widgets.float_bottom_row) are injected via Gate.wire{} at load time — they
-- couple to init's chat-bar/spinner/float machinery, so injection avoids a require
-- cycle (init and widgets both wire against these helpers). claude_diff is required
-- inline (verbatim from the pre-move code) at the two sites that bridge to it.
--
-- Init re-sources the geometry helpers + send_permission_response back out of here
-- (local X = gate.X) and feeds them into the existing widgets.wire{} / question.wire{}
-- calls — the wire indirection is why those two sibling modules stay untouched by
-- this move. show_permission_card / show_diff_card / try_prewrite_gate are called by
-- init's event dispatcher; on_prewrite_resolve is re-exported on the public surface
-- (claude_diff calls it); the mod._* test hooks are re-exported from init.

local Gate = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
-- widgets/process are leaf-ish modules (widgets requires only core; process requires
-- only core+widgets — neither requires gate or question), so requiring them directly
-- here is cycle-free, unlike the gate<->question hook-injection pattern above.
local widgets = require(require_prefix .. "widgets")
local process = require(require_prefix .. "process")

local state = core.state
local buf_append = core.buf_append
local hl_lines = core.hl_lines
local panel_width = core.panel_width

-- Init-owned helpers, injected by Gate.wire{} at load time (see init.lua).
-- Declared as forward locals so the gate functions below close over them.
local start_spinner
local stop_spinner
local clear_hint
local prompt_input
local float_bottom_row
local set_bottom_pad
local clear_bottom_pad
local set_waiting_hint
-- Clawd pet event sink (init injects pet.emit). nil = pet disabled → no-op.
local pet_emit
local pet_attach_surface
local pet_attach_panel
-- Cross-type drain target: a queued AskUserQuestion event (see show_permission_card's
-- cross-type guard) is dispatched through question.show_question_card, injected here
-- to avoid a gate<->question require cycle (question.lua injects show_permission_card
-- back the same way).
local show_question_card_hook

-- Forward decl: resolve_permission (defined first) drains the queue by re-invoking
-- show_permission_card (defined further down). Assigned, not re-declared, below.
local show_permission_card
-- Forward decl: same reason — resolve_permission/close_question_card drain
-- state.diffcard_queue by re-invoking show_diff_card (defined further down).
local show_diff_card

--- Inject init's spinner/hint/float helpers. Called once from init after they
--- are defined (prompt_input arrives as a thunk since it is defined further down
--- in init; float_bottom_row is widgets' — passed through rather than required
--- here to keep the gate ↔ widgets coupling one-directional via the wire).
function Gate.wire(hooks)
	start_spinner = hooks.start_spinner
	stop_spinner = hooks.stop_spinner
	clear_hint = hooks.clear_hint
	prompt_input = hooks.prompt_input
	float_bottom_row = hooks.float_bottom_row
	set_bottom_pad = hooks.set_bottom_pad
	clear_bottom_pad = hooks.clear_bottom_pad
	set_waiting_hint = hooks.set_waiting_hint
	pet_emit = hooks.pet_emit
	pet_attach_surface = hooks.pet_attach_surface
	pet_attach_panel = hooks.pet_attach_panel
	show_question_card_hook = hooks.show_question_card
end

local function send_permission_response(request_id, decision, o)
	if not state.job_id then
		return
	end
	o = o or {}
	local response
	if decision == "deny" then
		-- The deny reason rides in `message` for BOTH the permission-card "Reject" and
		-- AskUserQuestion's "Chat about this". The TUI bundle's question component sets an
		-- internal `feedback` prop, but the wire serializer maps it straight to `message`
		-- (`{behavior:"deny",message:$.feedback??"User denied permission"}`) — there is NO
		-- `feedback` field on the wire; sending one is silently dropped.
		response = { behavior = "deny", message = o.message or "User rejected" }
	else
		local input = o.input
		if type(input) ~= "table" or next(input) == nil then
			input = vim.empty_dict()
		end
		response = { behavior = "allow", updatedInput = input }
		if o.permissions then
			response.updatedPermissions = o.permissions
		end
	end
	local msg = vim.json.encode({
		type = "control_response",
		response = { subtype = "success", request_id = request_id, response = response },
	})
	-- chansend returns bytes written — 0 = the channel
	-- closed (the CLI died while the card was up). The decision never reached the CLI,
	-- so no result event will ever come and the turn would hang. Tear the working state
	-- down so the panel recovers; on_exit's own sweep still fires when the async exit
	-- lands.
	local ok, written = pcall(vim.fn.chansend, state.job_id, msg .. "\n")
	if not ok or written == 0 then
		state.working = false
		stop_spinner()
		clear_hint()
		vim.notify(
			"Claude: decision not delivered (session closed) — next message starts a fresh session",
			vim.log.levels.WARN
		)
	end
end
Gate.send_permission_response = send_permission_response

-- Every control_request expects a control_response.
-- A subtype the dispatcher doesn't implement, silently dropped, blocks the CLI's
-- turn forever behind the spinner — answer with the protocol's error variant so the
-- CLI fails the request and moves on. WARN once per subtype per session: the same
-- unimplemented subtype tends to repeat every turn (one toast, not a storm).
local unknown_control_warned = {}
local function send_control_error(request_id, subtype)
	if state.job_id then
		local msg = vim.json.encode({
			type = "control_response",
			response = {
				subtype = "error",
				request_id = request_id,
				error = "control_request subtype not supported by the panel: " .. subtype,
			},
		})
		pcall(vim.fn.chansend, state.job_id, msg .. "\n")
	end
	if not unknown_control_warned[subtype] then
		unknown_control_warned[subtype] = true
		vim.notify(
			"Claude panel: unhandled control_request subtype '"
				.. subtype
				.. "' — answered with an error so the CLI is not blocked",
			vim.log.levels.WARN
		)
	end
end
Gate.send_control_error = send_control_error

-- Edit-family tools at the can_use_tool gate. GATED ones (Issue-B prototype:
-- Write/Edit) hold the request open and show a PRE-write diff reconstructed from
-- the tool input — accept releases "allow" (the CLI then writes + narrates,
-- post-approval), reject releases "deny" (nothing touches disk). The rest
-- (MultiEdit/NotebookEdit) keep the old contract: auto-allow, then the post-write
-- FileChangedShell+vimdiff flow owns the review.
local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }
local GATED_EDIT_TOOLS = { Edit = true, Write = true }
Gate.EDIT_TOOLS = EDIT_TOOLS
Gate.GATED_EDIT_TOOLS = GATED_EDIT_TOOLS

-- Reconstruct the post-edit file content for an Edit tool input WITHOUT the CLI
-- having written anything: read the (still pristine) file from disk and mirror the
-- CLI's plain-text old_string→new_string replacement, honouring replace_all.
-- Returns a lines list, or nil when reconstruction isn't possible (file missing,
-- old_string absent/empty) — the caller falls back to auto-allow + post-write.
-- Disk, not buffer: the CLI edits the on-disk content, so unsaved buffer edits
-- must not leak into the "proposed" side.
local function reconstruct_edit(path, input)
	local old_s, new_s = input.old_string, input.new_string
	if type(old_s) ~= "string" or old_s == "" or type(new_s) ~= "string" then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	local text = table.concat(lines, "\n")
	local out
	if input.replace_all then
		-- split(plain)+concat replaces every occurrence with no pattern-escaping
		-- pitfalls (old_s/new_s are literal strings, not Lua patterns).
		local pieces = vim.split(text, old_s, { plain = true })
		if #pieces < 2 then
			return nil
		end -- old_string not found
		out = table.concat(pieces, new_s)
	else
		local s, e = string.find(text, old_s, 1, true)
		if not s then
			return nil
		end
		out = text:sub(1, s - 1) .. new_s .. text:sub(e + 1)
	end
	return vim.split(out, "\n", { plain = true })
end
Gate.reconstruct_edit = reconstruct_edit

-- Try to hold a gated edit's can_use_tool request behind a pre-write diff.
-- Returns true when the diff is up (request stays open until the user decides);
-- false → caller must auto-allow (old post-write flow) so the CLI never hangs.
local function try_prewrite_gate(request_id, tool, input)
	local path = input.file_path
	if type(path) ~= "string" or path == "" then
		return false
	end
	local proposed
	if tool == "Write" then
		proposed = vim.split(input.content or "", "\n", { plain = true })
	else -- Edit
		proposed = reconstruct_edit(path, input)
	end
	if not proposed then
		return false
	end
	-- Arm the held request BEFORE opening the diff: the review card can resolve
	-- synchronously in headless tests, and on_prewrite_resolve needs it set.
	state.prewrite = { request_id = request_id, input = input }
	local ok, opened = pcall(require("utils.claude_diff").open_prewrite, path, proposed)
	if not (ok and opened) then
		state.prewrite = nil
		return false
	end
	return true
end
Gate.try_prewrite_gate = try_prewrite_gate

-- Release the held pre-write request: allow (CLI writes the file, then narrates —
-- now post-approval) or deny (CLI never writes; the deny message tells it why).
-- Called by claude_diff.accept_all/reject_all in prewrite mode, which also close
-- the diff windows; the spinner restart mirrors resolve_permission (the turn is
-- still in flight — the CLI was blocked on us).
function Gate.on_prewrite_resolve(accepted)
	local p = state.prewrite
	if not p then
		return
	end
	state.prewrite = nil
	if pet_emit then
		pet_emit("diff_resolve", { accepted = accepted })
	end -- Clawd
	if accepted then
		send_permission_response(p.request_id, "allow", { input = p.input })
	else
		send_permission_response(p.request_id, "deny", { message = "User rejected the proposed change in review" })
	end
	core.resume_turn() -- fold the review wait out of the turn timer (mirrors the tick)
	if state.working then
		state.activity_t0 = vim.loop.now()
		start_spinner()
	end

	-- Cross-type: a perm/question card may have queued behind this held prewrite
	-- request via show_permission_card's/show_question_card's state.prewrite guard —
	-- the diff CARD itself may already be gone (Esc-dismissed), leaving only the held
	-- request as the thing actually blocking. Drain here, the moment it clears. Only
	-- one of perm_queue/qask_queue can be non-empty (show_permission_card/
	-- show_question_card both queue into their OWN queue, never cross-populate on this
	-- guard). Carry the diff card's reopen-bar flag across only when actually handing
	-- off — if nothing queued, on_diff_close (which close_diff() below still triggers)
	-- consumes it normally. (Gate-3 finding, advisor 2026-07-22 discriminating probe T17f.)
	if state.perm_queue and #state.perm_queue > 0 then
		local nxt = table.remove(state.perm_queue, 1)
		if state.diff_card_reopen_bar then
			state.diff_card_reopen_bar = false
			state.decision_reopen_bar = true
		end
		show_permission_card(nxt)
	elseif state.qask_queue and #state.qask_queue > 0 and show_question_card_hook then
		local nxt = table.remove(state.qask_queue, 1)
		if state.diff_card_reopen_bar then
			state.diff_card_reopen_bar = false
			state.decision_reopen_bar = true
		end
		show_question_card_hook(nxt)
	end
end

-- ─── Permission card (step 4) ─────────────────────────────────────────────────
-- Interactive bordered FLOAT for a non-edit can_use_tool request (Bash, WebFetch,
-- out-of-cwd file access, …) the CLI can't auto-resolve. Opens a rounded box in
-- the panel column titled "⚠ Permission required" (inline on the top border, like
-- the chat bar) but styled distinctly (ClaudePermBorder amber), FOCUSED so the
-- keyboard drives it immediately: ←/→ or h/l move, <CR>/number confirm, <Esc>/q
-- reject. On resolve it replies (send_permission_response), closes the float, and
-- drops a one-line receipt into the transcript so the scrollback records the
-- decision. One card at a time (the CLI blocks the turn awaiting our
-- control_response). Edits never reach here (auto-allowed → vimdiff). Mirrors
-- OpenCode's card.

-- Repaint the float's button row (p.row, 0-indexed last content line) in place:
-- the active option pops (ClaudeQuestion), the rest dim (ClaudeDim). Called on
-- open and on every left/right move.
local function render_perm_choice_row()
	local p = state.perm
	if not (p and p.buf and vim.api.nvim_buf_is_valid(p.buf)) then
		return
	end
	state.perm_ns = state.perm_ns or vim.api.nvim_create_namespace("ClaudePermRow")
	local segs, line = {}, "  "
	for i, opt in ipairs(p.options) do
		if i > 1 then
			line = line .. "    "
		end
		local label = ((i == p.choice) and "❯ " or "  ") .. opt.label
		local b0 = #line
		line = line .. label
		segs[#segs + 1] = { b0 = b0, b1 = #line, active = (i == p.choice) }
	end
	vim.bo[p.buf].modifiable = true
	vim.api.nvim_buf_set_lines(p.buf, p.row, p.row + 1, false, { line })
	vim.bo[p.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(p.buf, state.perm_ns, p.row, p.row + 1)
	for _, s in ipairs(segs) do
		vim.api.nvim_buf_add_highlight(
			p.buf,
			state.perm_ns,
			s.active and "ClaudeQuestion" or "ClaudeDim",
			p.row,
			s.b0,
			s.b1
		)
	end
end

-- Move the selection left/right (wraps).
local function move_perm_choice(delta)
	local p = state.perm
	if not p then
		return
	end
	p.choice = (p.choice - 1 + delta) % #p.options + 1
	render_perm_choice_row()
end
Gate.move_perm_choice = move_perm_choice

-- Send the chosen decision, close the float, append a transcript receipt, and
-- resume the spinner if the turn is still in flight (an allow lets Claude
-- continue; a deny only denies this tool — the turn may proceed; the eventual
-- `result` event flips working off + clears the hint).
--
-- `note` (optional): free text attached via Tab-to-annotate (prompt_perm_note). The
-- deny path has a documented wire channel for it (message field, same one
-- AskUserQuestion's "Chat about this" already uses — see send_permission_response).
-- The allow path has NO documented annotation field on can_use_tool's response (only
-- updatedInput/updatedPermissions) — the fallback is `process.send_followup(note)`,
-- which pushes one `{type:"user"}` stream-json line into the still-live turn (same
-- wire mechanic as the proven `process.steer` primitive, FINDINGS § Q-STEER) and
-- echoes it in the transcript. Deliberately NOT `process.steer` itself: steer also
-- drains state.queue, which would silently inject an unrelated message the user had
-- queued for AFTER the turn (e.g. typed + Enter while Claude was working) into the
-- turn early, as a side effect of annotating a permission decision — send_followup
-- sends only the note, queue untouched. That echo is deliberately the ONLY place an
-- allow-note is shown: appending it to the receipt line too would double-render it,
-- and its presence/absence is already the attempted-delivery signal (send_followup
-- no-ops silently if the turn already ended — the one case where that can happen
-- this soon is send_permission_response's own dead-channel branch below, which
-- already warns the user).
local function resolve_permission(kind, note)
	local p = state.perm
	if not p then
		return
	end
	if note == "" then
		note = nil
	end
	if kind == "deny" then
		send_permission_response(p.request_id, "deny", { message = note or "User rejected" })
	elseif kind == "always" then
		send_permission_response(p.request_id, "allow", { input = p.input, permissions = p.suggestions })
	else
		send_permission_response(p.request_id, "allow", { input = p.input })
	end

	-- Clear state BEFORE closing so the float's WinClosed guard no-ops (it only
	-- fires a fallback deny when the window vanishes with state.perm still set).
	state.perm = nil
	if p.resize_close then
		pcall(p.resize_close)
	end -- drop the resize-track augroup
	if p.win and vim.api.nvim_win_is_valid(p.win) then
		pcall(vim.api.nvim_win_close, p.win, true)
	end
	if pet_attach_panel then
		pet_attach_panel()
	end

	-- One-line receipt in the transcript so the scrollback shows what was decided.
	-- Deny's note rides here too (its only echo channel); allow's note is echoed
	-- separately by steer() below, not duplicated here.
	local mark = (kind == "deny") and "✗" or "✓"
	local verb = ({ once = "Allowed once", always = "Allowed always", deny = "Rejected" })[kind] or "Allowed"
	local receipt = mark .. " " .. p.display .. " — " .. verb
	if kind == "deny" and note then
		receipt = receipt .. '  "' .. note .. '"'
	end
	if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
		local recl = vim.api.nvim_buf_line_count(state.panel_buf)
		buf_append({ receipt })
		hl_lines(recl, recl, kind == "deny" and "ClaudeDim" or "ClaudeQuestion")
	end

	-- Allow-path note fallback (see the function doc above for why this can't ride
	-- in the control_response itself, and why send_followup not steer). MUST sit
	-- here — after the receipt (so the "↳ steered" echo reads below the "✓ Allowed"
	-- line, not above it) and before the three queue-drain early-returns just below
	-- (so a note isn't silently dropped when a second card was queued behind this
	-- one).
	if kind ~= "deny" and note then
		process.send_followup(note)
	end

	-- Concurrent requests: Claude can emit parallel tool_use blocks in one turn, so
	-- a second can_use_tool can arrive while this card is up (it was QUEUED, not shown
	-- — see show_permission_card). Drain the next one NOW instead of resuming the turn
	-- / reopening the chat bar: that next card owns the spinner+bar lifecycle, and the
	-- turn is still paused (pause_turn is idempotent, so no double-pause). This is what
	-- keeps the second modal from orphaning behind the first (the frozen-ghost bug).
	if state.perm_queue and #state.perm_queue > 0 then
		local nxt = table.remove(state.perm_queue, 1)
		show_permission_card(nxt)
		return
	end
	-- Cross-type: a question card was queued behind this one (show_question_card's
	-- cross-type guard) instead of drawing over it. Hand off the same way.
	if state.qask_queue and #state.qask_queue > 0 and show_question_card_hook then
		local nxt = table.remove(state.qask_queue, 1)
		show_question_card_hook(nxt)
		return
	end
	-- Cross-type: a diff card was queued behind this one (show_diff_card's cross-type
	-- guard). Unlike perm<->qask, the diff card doesn't pause/resume the turn clock
	-- itself and tracks its own reopen flag — resume here and carry the reopen intent
	-- across before handing off (Gate-3 finding, advisor 2026-07-22: draining via a bare
	-- early-return like the two blocks above would leave the turn clock stuck paused and
	-- strand a dismissed chat bar's reopen).
	if state.diffcard_queue and #state.diffcard_queue > 0 then
		local nxt = table.remove(state.diffcard_queue, 1)
		core.resume_turn()
		if state.decision_reopen_bar then
			state.decision_reopen_bar = false
			state.diff_card_reopen_bar = true
		end
		show_diff_card(nxt.path, nxt.kind)
		return
	end

	-- Clawd: no more queued cards → the modal is truly gone. Clear the building/notify
	-- state so the work/idle state underneath resurfaces. (A drained card above returned
	-- early after re-emitting active, so this only fires on the LAST resolve.)
	if pet_emit then
		pet_emit("permission", { active = false })
	end

	-- Resume the turn clock: fold the decision wait into the paused total so the
	-- cumulative turn timer + "✻ …for Ns" done line exclude it (mirrors the tick).
	core.resume_turn()

	-- A blank line below the receipt so the resumed spinner anchors to its OWN line
	-- (set_hint pins EOL virt_text to the last buffer line) instead of trailing the
	-- "✓ Allowed …" receipt text on the same row. Re-baseline the thinking timer so
	-- the user's decision time doesn't count toward the next block's "Thought · …".
	if state.working then
		state.activity_t0 = vim.loop.now()
		buf_append({ "" })
		start_spinner()
	else
		clear_hint()
	end

	-- Reopen the chat bar we dismissed to show the card, so the user lands back in
	-- the input (draft restored) and can keep the conversation going. Scheduled so
	-- the card's window is fully torn down first. state.perm is already nil here, so
	-- prompt_input() won't bail on the permission guard.
	if state.decision_reopen_bar then
		state.decision_reopen_bar = false
		vim.schedule(function()
			prompt_input()
		end)
	elseif state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
		-- No chat bar to reopen: closing the float otherwise drops focus to whatever
		-- window preceded it (usually the editor). Land back in the Claude panel so a
		-- decision keeps the user inside the panel, not kicked out to the code buffer.
		vim.schedule(function()
			if vim.api.nvim_win_is_valid(state.panel_win) then
				pcall(vim.api.nvim_set_current_win, state.panel_win)
			end
		end)
	end
end
Gate.resolve_permission = resolve_permission

-- Abandon every pending permission decision —
-- live card, queued requests, held pre-write gate — because the session is gone
-- (CLI death or reset). Unlike resolve_permission this must NOT drain the queue
-- into a fresh card: there is no session left to answer. The deny responses are
-- best-effort — send_permission_response no-ops on a nil job_id (CLI death) and
-- actually answers on a reset-while-alive, where the CLI is still blocked.
local function abort_permission_cards(receipt)
	-- Queue first, so closing the live card below can't race a drain.
	local queued = state.perm_queue
	state.perm_queue = nil
	for _, queued_event in ipairs(queued or {}) do
		send_permission_response(queued_event.request_id, "deny", { message = receipt })
	end

	local p = state.perm
	if p then
		state.perm = nil -- before close → the float's WinClosed fallback-deny no-ops
		send_permission_response(p.request_id, "deny", { message = receipt })
		if p.resize_close then
			pcall(p.resize_close)
		end
		if p.win and vim.api.nvim_win_is_valid(p.win) then
			pcall(vim.api.nvim_win_close, p.win, true) -- WinClosed autocmd drops the pad
		end
		state.decision_reopen_bar = false -- no chat bar to hand back to a dead session
		if pet_emit then
			pet_emit("permission", { active = false })
		end
		if pet_attach_panel then
			pet_attach_panel()
		end
		if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
			local receipt_row = vim.api.nvim_buf_line_count(state.panel_buf)
			buf_append({ "✗ " .. p.display .. " — " .. receipt })
			hl_lines(receipt_row, receipt_row, "ClaudeDim")
		end
	end

	-- Held pre-write request: reject through claude_diff so the diff windows close
	-- with it. Guarded on claude_diff's OWN prewrite flag — reject_all in any other
	-- mode acts on a post-write review instead (its "new file" branch deletes the
	-- file from disk). The nil below is a belt over a reject_all that failed
	-- part-way: the held request must never stay armed on a dead session.
	if state.prewrite then
		local claude_diff = require("utils.claude_diff")
		if claude_diff.state and claude_diff.state.prewrite then
			pcall(claude_diff.reject_all)
		end
		state.prewrite = nil
	end

	core.resume_turn() -- the decision wait is over, whatever ended it
end
Gate.abort_permission_cards = abort_permission_cards

-- Find path-like tokens in a PLAIN card line (the desc / Patterns rows are not
-- markdown, so parse_inline never touches them). Any run containing a "/" is a
-- path: trailing-slash → directory (ClaudeDir blue + folder feel), else a file
-- path (ClaudePath green) — matching how the transcript colours paths everywhere
-- else. Returns { {byte0, byte_end, group}, … }.
local function perm_path_ranges(line)
	local out = {}
	for s, tok in line:gmatch("()([~%w%._%-/]*/[~%w%._%-/]*)") do
		local b0 = s - 1
		out[#out + 1] = { b0, b0 + #tok, (tok:sub(-1) == "/") and "ClaudeDir" or "ClaudePath" }
	end
	return out
end

-- The concrete command / parameters the tool will run, so the user can verify
-- EXACTLY what executes before allowing (the display + description summarise intent
-- but hide the real command, e.g. "Display directory tree" never showed the
-- `tree -L 3 …` that runs). Unlike tool_target (truncated to one transcript line),
-- the card wraps + spans rows, so show the full value split on newlines
-- (nvim_buf_set_lines rejects embedded \n). Picks the most meaningful input field.
local function perm_input_lines(input)
	if type(input) ~= "table" then
		return {}
	end
	local val = input.command or input.url or input.query or input.pattern or input.file_path or input.path
	if not val or val == "" then
		return {}
	end
	local out = {}
	for ln in (tostring(val) .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = ln
	end
	return out
end

-- ─── Shared SW-anchored panel-float helpers ──────────────────────────────────
-- The permission card, question card, and chat bar are all bordered floats anchored
-- bottom-left to the Claude panel's column. They must behave IDENTICALLY on three
-- axes, so each routes through these helpers instead of re-deriving the math:
--   (a) glue to the panel's REAL screen column regardless of window layout,
--   (b) never over-scroll their content into empty space, and
--   (c) track the panel's width/column when the terminal or windows resize.

-- Col + inner width for an SW float spanning the panel column. Anchors to the panel
-- window's actual screen position; (columns - panel_w) only lands right when the
-- panel is the RIGHTMOST window — with a split beside it (or the panel on the left)
-- that math drifts the float into the neighbour. Falls back to the subtraction only
-- when the panel window isn't available.
local function panel_float_geom()
	local panel_w = panel_width()
	local float_col = vim.o.columns - panel_w
	if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
		panel_w = vim.api.nvim_win_get_width(state.panel_win)
		float_col = vim.api.nvim_win_get_position(state.panel_win)[2]
	end
	return float_col, math.max(panel_w - 2, 1)
end
Gate.panel_float_geom = panel_float_geom

-- Stop a float from scrolling its content off into blank space. A non-zero global
-- 'scrolloff' leaks into floats: at the last line vim keeps `scrolloff` rows below
-- the cursor, but there are none, so it over-scrolls the tail upward past EOF (the
-- permission card's command-tail over-shoot). Zero it (plus sidescrolloff) per-window
-- so j/k stop with the last line resting at the bottom.
local function harden_float_scroll(win)
	vim.wo[win].scrolloff = 0
	vim.wo[win].sidescrolloff = 0
end
Gate.harden_float_scroll = harden_float_scroll

-- Track the panel column/width on resize for an SW float. The fixed-width panel's
-- left edge shifts as the editor grows, so a float fixed at open-time col/width
-- drifts out of the column and clips. Recomputes col/row/width every resize; the
-- optional on_resize(win, col, width) lets the caller re-fit height / re-render to
-- the new width AFTER the reposition. The augroup self-removes when the window dies
-- (autocmd returns true); also returns a teardown fn for explicit close.
local function attach_panel_float_resize(win, group_name, on_resize)
	vim.api.nvim_create_augroup(group_name, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group_name,
		callback = function()
			if not vim.api.nvim_win_is_valid(win) then
				return true
			end -- gone → self-remove
			local col, w = panel_float_geom()
			local c = vim.api.nvim_win_get_config(win)
			c.col, c.row, c.width = col, float_bottom_row(), w
			pcall(vim.api.nvim_win_set_config, win, c)
			if on_resize then
				on_resize(win, col, w)
			end
		end,
	})
	return function()
		pcall(vim.api.nvim_del_augroup_by_name, group_name)
	end
end
Gate.attach_panel_float_resize = attach_panel_float_resize

-- Tab-to-annotate: opens the shared prompt float (widgets.open_prompt_float) titled
-- with the currently-highlighted choice, then resolves that SAME choice carrying
-- whatever was typed. <Esc> in the prompt (on_commit(nil)) cancels — no decision is
-- made and the card just gets focus back, mirroring question.lua's "n to add notes"
-- Esc semantics (a dismiss never forces a choice). A blank <CR> (on_commit("")) still
-- resolves the highlighted option, just with no note — Tab-then-immediately-confirm
-- is a valid way to back out of annotating without backing out of the decision.
local function prompt_perm_note()
	local p = state.perm
	if not p then
		return
	end
	local opt = p.options[p.choice]
	-- Local row inside p.win for the overlay to pin at: p.hint_row is a fixed
	-- BUFFER line number, but the card can be scrolled (j/k, long commands) —
	-- convert to a row relative to whatever's currently at the top of the visible
	-- window so the overlay lands ON the hint line, not wherever it would've been
	-- had the card never scrolled.
	local topline = vim.api.nvim_win_call(p.win, function()
		return vim.fn.line("w0")
	end)
	-- -1 extra: a `relative="win"` float's `row` positions its BORDER's row, not its
	-- content's — content starts one row below `row` (same border-row fact this
	-- session's own pet_render.lua comment already established: "a bordered float's
	-- win_get_position() row IS its border row"). Without the -1, content landed one
	-- row BELOW "Tab to amend" (live-tested — user wanted it to replace that row,
	-- not sit under it), because border-at-hint_row means content-at-hint_row+1.
	local local_row = p.hint_row - (topline - 1) - 1
	-- No pet on_open/reattach here (unlike the old stack-above design): the overlay
	-- now lives INSIDE the card's own footprint (pinned at its hint row), not as a
	-- separate float beside it. Clawd is already attached to p.win from
	-- show_permission_card and that stays correct for the overlay's whole lifetime
	-- — moving him onto the tiny overlay window itself would perch him over the
	-- MIDDLE of the card (pet_render's surface mode sits above the anchor window's
	-- own top border), not his usual top-right spot. Advisor-flagged before this
	-- shipped (round-4 review) rather than caught live.
	widgets.open_prompt_float(" ✎ Note for " .. opt.label .. " ", nil, function(text)
		if text == nil then
			return
		end
		resolve_permission(opt.kind, text)
	end, {
		guard = function()
			return state.perm ~= nil
		end,
		refocus = function()
			return state.perm and state.perm.win
		end,
		at = { win = p.win, row = local_row }, -- overlay pinned AT the "Tab to amend" line
	})
end

-- Build + open the focused, bordered permission float and bind its keymaps. The
-- buffer is dedicated and wiped on close, so the keymaps need no teardown.
local function open_permission_float(p)
	-- Body lines (display / desc / command / patterns), a spacer, the button-row
	-- placeholder, and a dim nav-hint line that wraps inside the box.
	local lines, body_hl = {}, {}
	-- EVERY body insert goes through push(): any CLI-supplied string (display,
	-- description, rules — not just Write file content) can carry embedded "\n",
	-- and nvim_buf_set_lines throws on a newline in any item, killing the whole
	-- card (request invisible until a redraw retries it — live 2026-07-11 with a
	-- multi-line tool description; the round-4 fix had only covered the command).
	local function push(text, hl)
		for _, sub in ipairs(vim.split(text, "\n", { plain = true })) do
			lines[#lines + 1] = sub
			if hl then
				body_hl[#body_hl + 1] = { #lines - 1, hl }
			end
		end
	end
	push("  " .. p.display, "ClaudeProse")
	if p.desc ~= "" and p.desc ~= p.display then
		push("  " .. p.desc, "ClaudeProse")
	end
	-- Button row + nav hint go ABOVE the command, not below it. The float height is
	-- capped (see geometry) so a long command can't fill the screen; keeping the
	-- choices at the top means they stay visible while the command scrolls in the
	-- region beneath them, instead of being pushed off the bottom edge.
	lines[#lines + 1] = "" -- spacer
	lines[#lines + 1] = "" -- button-row placeholder
	p.row = #lines - 1 -- 0-indexed button row
	lines[#lines + 1] = "  ←/→ select h/l · ⏎ confirm · esc reject · ↑/↓ scroll j/k"
	body_hl[#body_hl + 1] = { #lines - 1, "ClaudeDim" }
	lines[#lines + 1] = "" -- spacer (symmetric with the one below "Tab to amend")
	-- Own line, not squeezed onto the row above (that wrapped/overlapped "j/k" at
	-- normal panel widths). This exact row is what prompt_perm_note's overlay pins
	-- itself to and visually replaces when Tab is pressed — captured AFTER the
	-- append, not before, so it points at this line and not the button row above it.
	lines[#lines + 1] = "  Tab to amend"
	p.hint_row = #lines - 1
	-- Light orange (not the dim gray every other hint line uses) so this one option
	-- pops as discoverable rather than reading as just another muted keybind hint.
	body_hl[#body_hl + 1] = { #lines - 1, "ClaudeBurnWarn" }
	lines[#lines + 1] = "" -- spacer
	-- The actual command/parameters, rendered as a code block (▎ gutter + cyan) so
	-- the user sees what will run, not just a paraphrase of it. Rendered LAST so it
	-- is the scrollable tail of the float.
	for _, cl in ipairs(perm_input_lines(p.input)) do
		-- A multi-line value (e.g. a Write's file content) arrives as ONE string with
		-- embedded "\n" — push() splits it into buffer lines (see above). The gutter
		-- prefixes every produced row so wrapped content keeps the code-block look.
		for _, sub in ipairs(vim.split(cl, "\n", { plain = true })) do
			push("  ▎ " .. sub, "ClaudeCode")
		end
	end
	if p.rules and #p.rules > 0 then
		push("  Patterns: " .. table.concat(p.rules, ", "), "ClaudeDim")
	end

	-- Geometry: full panel-column width minus borders, anchored to the panel's real
	-- screen column (shared helper — same anchoring the question/chat floats use).
	local float_col, float_w = panel_float_geom()

	-- Height must count WRAPPED display rows, not logical lines: with wrap on, a long
	-- description (e.g. a Skill blurb) spans several screen rows. Sum ceil(width/float_w)
	-- per line, then cap at HALF the editor height: a giant command must not swallow
	-- the screen — the chat above stays visible and the command scrolls (j/k) inside
	-- the float. Buttons sit at the top (see line order) so they stay visible while
	-- scrolling, killing the old "I can't see what I'm choosing" bug. Factored into a
	-- closure so the resize handler can re-fit when the panel width changes.
	local function perm_height(w)
		local disp_rows = 0
		for _, l in ipairs(lines) do
			disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / w))
		end
		return math.min(disp_rows, math.max(math.floor(vim.o.lines / 2), 3))
	end
	local float_h = perm_height(float_w)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	p.buf = buf

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		anchor = "SW",
		row = float_bottom_row(),
		col = float_col,
		width = float_w,
		height = float_h,
		border = "rounded",
		style = "minimal",
		title = " ⚠ Permission required ",
		title_pos = "left",
		zindex = 60,
	})
	p.win = win
	core.hide_modal_cursor() -- hide the cursor over the card at open (see core doc)
	if pet_attach_surface then
		pet_attach_surface(win)
	end
	-- Amber outline so the card is clearly NOT the clay chat bar; interior shares
	-- ClaudeBarBg so the box reads flush, only the outline pops.
	vim.wo[win].winhighlight = "FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder,NormalFloat:ClaudeBarBg"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true -- wrap at word boundaries, not mid-word
	vim.wo[win].breakindent = true -- align wrapped continuation under the line's indent
	vim.wo[win].cursorline = false
	harden_float_scroll(win) -- BUG A: no over-scroll past the command tail
	-- Reserve the card's footprint as bottom padding so live output + the "Waiting…"
	-- hint push ABOVE the card instead of peeking below it (float_h interior + 2
	-- border rows + 1 separator — same contract the question card uses).
	if set_bottom_pad then
		set_bottom_pad(float_h + 3)
	end
	-- BUG B: track the panel column/width on resize, re-fitting the wrapped height.
	p.resize_close = attach_panel_float_resize(win, "ClaudePermFloat", function(_, _, w)
		local h = perm_height(w)
		pcall(vim.api.nvim_win_set_height, win, h)
		if set_bottom_pad then
			set_bottom_pad(h + 3)
		end
	end)

	for _, h in ipairs(body_hl) do
		-- Base group over the whole line, then layer path/dir colours on top so the
		-- directories + file paths in the desc/Patterns rows pop (later add_highlight
		-- wins on the overlapping cells).
		vim.api.nvim_buf_add_highlight(buf, -1, h[2], h[1], 0, -1)
		for _, r in ipairs(perm_path_ranges(lines[h[1] + 1] or "")) do
			vim.api.nvim_buf_add_highlight(buf, -1, r[3], h[1], r[1], r[2])
		end
	end
	vim.bo[buf].modifiable = false

	local function map(k, fn)
		vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
	end
	map("<Left>", function()
		move_perm_choice(-1)
	end)
	map("h", function()
		move_perm_choice(-1)
	end)
	map("<Right>", function()
		move_perm_choice(1)
	end)
	map("l", function()
		move_perm_choice(1)
	end)
	map("<Up>", function()
		vim.cmd("normal! k")
	end)
	map("<Down>", function()
		vim.cmd("normal! j")
	end)
	map("<Tab>", prompt_perm_note)
	map("<CR>", function()
		local q = state.perm
		if q then
			resolve_permission(q.options[q.choice].kind)
		end
	end)
	map("<Esc>", function()
		resolve_permission("deny")
	end)
	map("q", function()
		resolve_permission("deny")
	end)
	for i = 1, 3 do
		map(tostring(i), function()
			local q = state.perm
			if q and q.options[i] then
				q.choice = i
				resolve_permission(q.options[i].kind)
			end
		end)
	end

	-- If the float vanishes by any path OTHER than resolve_permission (which nils
	-- state.perm first), fall back to a reject so the CLI isn't left waiting.
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if clear_bottom_pad then
				clear_bottom_pad()
			end -- drop the card's reserve on any close path
			if state.perm and state.perm.win == win then
				resolve_permission("deny")
			end
		end,
	})
end

-- Render a permission card from an inbound can_use_tool control_request and arm
-- the lock. Pauses the spinner (Claude is genuinely blocked on us, so a spinner
-- would lie); resolve_permission restarts it.
show_permission_card = function(event)
	-- One DECISION card at a time, perm or question. Guarding only on state.perm
	-- let a question card (state.qask) open on top of a still-live perm card — same
	-- anchor="SW"/zindex=60 as open_question_float, so it silently draws over the
	-- perm float instead of colliding/erroring. The perm float never got closed or
	-- tracked as queued, so it reappeared, unresolved, once the question card closed
	-- (see docs/post-mortems/concurrent-permission-modal-ghost.md, cross-type follow-up).
	-- Queue on EITHER type being up; resolve_permission/close_question_card both drain
	-- both queues so whichever card is blocking hands off correctly. A live diff_card
	-- shares the same float geometry too — guard against it the same way; close_diff_card
	-- drains perm_queue on resolve/dismiss. state.prewrite ALSO needs its own check, not
	-- just diff_card: Esc/q dismisses the diff CARD but leaves the held prewrite request
	-- (and its vimdiff windows) open — a new perm/qask request arriving in that window
	-- would open right over the still-unresolved prewrite with no card up to guard
	-- against it. on_prewrite_resolve drains perm_queue when the held request finally
	-- clears (Gate-3 finding, advisor 2026-07-22 discriminating probe T17f — the guard
	-- only covered show_diff_card's forward direction, not this reverse one).
	if state.perm or state.qask or state.diff_card or state.prewrite then
		state.perm_queue = state.perm_queue or {}
		state.perm_queue[#state.perm_queue + 1] = event
		return
	end

	local req = event.request or {}
	local p = {
		request_id = event.request_id,
		tool = req.tool_name or "",
		display = req.display_name or req.tool_name or "tool",
		desc = req.description or "",
		input = req.input,
		suggestions = req.permission_suggestions,
		choice = 1,
	}
	-- Collect rule strings (suggestions[].rules[].ruleContent) for the Patterns
	-- line and to decide whether "Allow always" is offered — only when the CLI gave
	-- us rules to persist.
	local rules = {}
	for _, sug in ipairs(p.suggestions or {}) do
		for _, r in ipairs(sug.rules or {}) do
			if r.ruleContent then
				rules[#rules + 1] = r.ruleContent
			end
		end
	end
	p.rules = rules
	p.options = { { label = "Allow once", kind = "once" } }
	if #rules > 0 then
		p.options[#p.options + 1] = { label = "Allow always", kind = "always" }
	end
	p.options[#p.options + 1] = { label = "Reject", kind = "deny" }

	stop_spinner()
	core.pause_turn() -- freeze the turn clock: the CLI is blocked on the user's choice
	clear_hint() -- drop any stale "Working…" hint so nothing peeks behind the float

	-- Dismiss any open chat bar BEFORE opening the card. The bar anchors SW at the
	-- same panel column as the card, so leaving it open overlaps the card and steals
	-- focus/draw order — the card then can't be driven and falls through to a reject.
	-- Closing via the bar's own close() saves the draft; we reopen it on resolve.
	-- NB: don't blindly reset decision_reopen_bar here — when this card is drained
	-- from the queue after a prior card (same-type, or a cross-type hand-off from a
	-- resolved question card), the bar was already dismissed (chat_win is gone) and
	-- the pending-reopen intent from the first card must survive to the last one.
	-- Only set it when there's actually an open bar to dismiss now. Shared flag with
	-- question.lua's show_question_card — see core.lua's decision_reopen_bar comment.
	if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
		state.decision_reopen_bar = true
		if state.chat_close then
			pcall(state.chat_close)
		end
	end

	state.perm = p
	-- Clawd: a permission modal is up. Edit/Write file requests → building sprite;
	-- every other tool → notification sprite (see pet.lua `permission` event).
	if pet_emit then
		local build = p.tool == "Edit" or p.tool == "Write" or p.tool == "MultiEdit" or p.tool == "NotebookEdit"
		pet_emit("permission", { active = true, build = build })
	end
	open_permission_float(p)
	render_perm_choice_row()
	-- The spinner is stopped for the perm card, so paint the frozen "Waiting…" hint
	-- ourselves (the tick-driven gates show it from the running spinner). Sits above
	-- the card thanks to the reserved bottom pad (open_permission_float).
	if set_waiting_hint then
		set_waiting_hint()
	end
end
Gate.show_permission_card = show_permission_card

-- ─── Diff-review card (Goal 14.3) ─────────────────────────────────────────────
-- Reuses the permission card's floating-panel mechanism (SW geometry, scroll
-- hardening, resize tracking, choice-row highlight paint) for the Accept/Reject
-- decision on a proposed file diff, so resolving an edit feels like every other
-- panel decision instead of requiring a jump to the diff window's winbar. The
-- winbar + <leader>ca/cx keymaps (claude_diff.lua) stay wired as a fallback —
-- this card is additive, not a replacement path for either.

local function render_diff_card_choice_row()
	local d = state.diff_card
	if not (d and d.buf and vim.api.nvim_buf_is_valid(d.buf)) then
		return
	end
	state.diff_card_ns = state.diff_card_ns or vim.api.nvim_create_namespace("ClaudeDiffCardRow")
	local segs, line = {}, "  "
	for i, opt in ipairs(d.options) do
		if i > 1 then
			line = line .. "    "
		end
		local label = ((i == d.choice) and "❯ " or "  ") .. opt.label
		local b0 = #line
		line = line .. label
		segs[#segs + 1] = { b0 = b0, b1 = #line, active = (i == d.choice) }
	end
	vim.bo[d.buf].modifiable = true
	vim.api.nvim_buf_set_lines(d.buf, d.row, d.row + 1, false, { line })
	vim.bo[d.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(d.buf, state.diff_card_ns, d.row, d.row + 1)
	for _, s in ipairs(segs) do
		vim.api.nvim_buf_add_highlight(
			d.buf,
			state.diff_card_ns,
			s.active and "ClaudeQuestion" or "ClaudeDim",
			d.row,
			s.b0,
			s.b1
		)
	end
end

local function move_diff_card_choice(delta)
	local d = state.diff_card
	if not d then
		return
	end
	d.choice = (d.choice - 1 + delta) % #d.options + 1
	render_diff_card_choice_row()
end

-- Close the card float WITHOUT touching the diff itself. Used both when a
-- choice resolves it and when the diff resolves some other way (the winbar
-- <leader>ca/cx fallback, or the diff window simply being closed) and the
-- now-stale card needs to go away.
-- Returns true when a queued perm/question card was handed off (caller should skip
-- any tail work it would otherwise run — that card owns the lifecycle now).
local function close_diff_card()
	local d = state.diff_card
	if not d then
		return false
	end
	state.diff_card = nil
	if d.resize_close then
		pcall(d.resize_close)
	end
	if d.win and vim.api.nvim_win_is_valid(d.win) then
		pcall(vim.api.nvim_win_close, d.win, true)
	end
	if pet_attach_panel then
		pet_attach_panel()
	end

	-- Cross-type: a perm/question card was queued behind this diff card
	-- (show_permission_card's/show_question_card's cross-type guard) instead of
	-- drawing over it. Drain MUST live here, not just in on_diff_close: Esc/q
	-- (below) and the WinClosed fallback both tear the card down via this function
	-- directly, without going through on_diff_close — a queued control_request left
	-- undrained on either of those paths would strand the CLI waiting forever
	-- (Gate-3 finding, advisor 2026-07-22). Carry whichever reopen-bar flag was set
	-- across, since perm/qask and diff cards each track their own — only when actually
	-- handing off, so an empty-queue dismiss doesn't strand decision_reopen_bar=true
	-- with no card in flight to consume it (on_diff_close's own tail handles the
	-- no-handoff case).
	if state.perm_queue and #state.perm_queue > 0 then
		local nxt = table.remove(state.perm_queue, 1)
		if state.diff_card_reopen_bar then
			state.diff_card_reopen_bar = false
			state.decision_reopen_bar = true
		end
		show_permission_card(nxt)
		return true
	end
	if state.qask_queue and #state.qask_queue > 0 and show_question_card_hook then
		local nxt = table.remove(state.qask_queue, 1)
		if state.diff_card_reopen_bar then
			state.diff_card_reopen_bar = false
			state.decision_reopen_bar = true
		end
		show_question_card_hook(nxt)
		return true
	end
	return false
end
Gate.close_diff_card = close_diff_card

-- kind is "accept" | "reject" — routes straight into claude_diff's existing
-- accept_all/reject_all (same functions the winbar keymaps call), so a new-file
-- reject still deletes the file and a write failure still warns + keeps the
-- diff open exactly as it does via the fallback path.
local function resolve_diff_card(kind)
	local d = state.diff_card
	if not d then
		return
	end
	close_diff_card()
	-- Clawd: post-write diff resolved via the card. (Prewrite Edit/Write resolve
	-- through on_prewrite_resolve above; the winbar <leader>ca/cx fallback for a
	-- post-write diff bypasses this and misses only the brief approved/rejected
	-- flash — the pet is hidden by gated() during the diff regardless.)
	if pet_emit then
		pet_emit("diff_resolve", { accepted = kind == "accept" })
	end
	local diff = require("utils.claude_diff")
	if kind == "accept" then
		diff.accept_all()
	else
		diff.reject_all()
	end
end
Gate.resolve_diff_card = resolve_diff_card

local function open_diff_card_float(d)
	local lines, body_hl = {}, {}
	lines[#lines + 1] = "  " .. d.display
	body_hl[#body_hl + 1] = { #lines - 1, "ClaudeProse" }
	lines[#lines + 1] = "" -- spacer
	lines[#lines + 1] = "" -- button-row placeholder
	d.row = #lines - 1 -- 0-indexed button row
	lines[#lines + 1] = "  ←/→ select · ⏎ confirm · a accept · x reject"
	body_hl[#body_hl + 1] = { #lines - 1, "ClaudeDim" }

	-- Shared geometry/scroll/resize helpers (panel_float_geom, harden_float_scroll,
	-- attach_panel_float_resize) — same ones the permission/question/chat floats use.
	local float_col, float_w = panel_float_geom()
	local function card_height(w)
		local disp_rows = 0
		for _, l in ipairs(lines) do
			disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / w))
		end
		return math.min(disp_rows, math.max(math.floor(vim.o.lines / 2), 3))
	end
	local float_h = card_height(float_w)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	d.buf = buf

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		anchor = "SW",
		row = float_bottom_row(),
		col = float_col,
		width = float_w,
		height = float_h,
		border = "rounded",
		style = "minimal",
		title = " ⚠ Review changes ",
		title_pos = "left",
		zindex = 60,
	})
	d.win = win
	core.hide_modal_cursor() -- hide the cursor over the card at open (see core doc)
	if pet_attach_surface then
		pet_attach_surface(win)
	end
	-- Same amber outline as the permission card — both are "your decision needed"
	-- cards; a distinct colour per card type would read as two different systems.
	vim.wo[win].winhighlight = "FloatBorder:ClaudePermBorder,FloatTitle:ClaudePermBorder,NormalFloat:ClaudeBarBg"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	vim.wo[win].cursorline = false
	harden_float_scroll(win)
	-- Reserve the card's footprint so live output + the "Waiting…" hint push ABOVE
	-- the card instead of peeking below it (interior + 2 border + 1 separator).
	if set_bottom_pad then
		set_bottom_pad(float_h + 3)
	end
	d.resize_close = attach_panel_float_resize(win, "ClaudeDiffCardFloat", function(_, _, w)
		local h = card_height(w)
		pcall(vim.api.nvim_win_set_height, win, h)
		if set_bottom_pad then
			set_bottom_pad(h + 3)
		end
	end)

	for _, h in ipairs(body_hl) do
		vim.api.nvim_buf_add_highlight(buf, -1, h[2], h[1], 0, -1)
	end
	vim.bo[buf].modifiable = false

	local function map(k, fn)
		vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
	end
	map("<Left>", function()
		move_diff_card_choice(-1)
	end)
	map("h", function()
		move_diff_card_choice(-1)
	end)
	map("<Right>", function()
		move_diff_card_choice(1)
	end)
	map("l", function()
		move_diff_card_choice(1)
	end)
	map("<Up>", function()
		vim.cmd("normal! k")
	end)
	map("<Down>", function()
		vim.cmd("normal! j")
	end)
	map("<CR>", function()
		local q = state.diff_card
		if q then
			resolve_diff_card(q.options[q.choice].kind)
		end
	end)
	map("a", function()
		resolve_diff_card("accept")
	end)
	map("x", function()
		resolve_diff_card("reject")
	end)
	-- Unlike the permission card, Esc/q only DISMISS the card — the diff itself is
	-- not blocking a waiting CLI, so there's no reason to force a decision. The
	-- winbar keymaps remain live on the diff window as the fallback.
	map("<Esc>", close_diff_card)
	map("q", close_diff_card)

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if clear_bottom_pad then
				clear_bottom_pad()
			end -- drop the card's reserve on any close path
			if state.diff_card and state.diff_card.win == win then
				-- Dismissed some other way; not a decision — route through close_diff_card
				-- (not a direct nil) so a queued perm/qask card still drains (Gate-3 finding,
				-- advisor 2026-07-22; the window is already gone here, so close_diff_card's
				-- own win-close pcall is a safe no-op).
				close_diff_card()
			end
		end,
	})
end

show_diff_card = function(path, kind)
	-- Cross-type: one DECISION card at a time, same as perm/question. A diff card up
	-- alongside a live perm or question card shares the SW-anchor/zindex=60 float — it
	-- would silently draw over whichever is up instead of queuing (same class as the
	-- perm/question cross-type guard above). Queue on EITHER being up; resolve_permission
	-- / close_question_card drain diffcard_queue the same way they drain each other.
	if state.perm or state.qask then
		state.diffcard_queue = state.diffcard_queue or {}
		state.diffcard_queue[#state.diffcard_queue + 1] = { path = path, kind = kind }
		return
	end
	local d = {
		display = (kind == "new") and ("New file: " .. vim.fn.fnamemodify(path, ":t"))
			or ("Modified: " .. vim.fn.fnamemodify(path, ":t")),
		choice = 1,
		options = { { label = "Accept", kind = "accept" }, { label = "Reject", kind = "reject" } },
	}

	-- Dismiss any open chat bar BEFORE opening the card — same SW-column overlap
	-- the permission card guards against (both anchor to the same panel column).
	state.diff_card_reopen_bar = false
	if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
		state.diff_card_reopen_bar = true
		if state.chat_close then
			pcall(state.chat_close)
		end
	end

	state.diff_card = d
	open_diff_card_float(d)
	render_diff_card_choice_row()
end
Gate.show_diff_card = show_diff_card

return Gate
