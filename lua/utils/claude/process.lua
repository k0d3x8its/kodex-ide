-- lua/utils/claude/process.lua
--
-- The persistent-subprocess lifecycle: spawn, stdin send, stdout line-buffer,
-- exit handling, and the type-ahead queue. Extracted from the former monolithic
-- claude.lua to relieve init's main-chunk 200-local ceiling.
--
-- Architecture: ONE long-lived `claude` process per panel session, driven over
-- stdin/stdout as newline-delimited stream-json — the same mode KOS Capture uses
-- (kos-capture/screens/ingest.py). Spawn args:
--   --print --input-format stream-json --output-format stream-json --verbose
-- Each user turn is a stream-json `user` message written to stdin; the process
-- streams events back and STAYS ALIVE for the next turn, holding conversation
-- context natively (no --resume/--session-id juggling).
--
-- Why this and not per-message --print?
--   The old per-message design existed only to dodge a stdout-buffering bug: with
--   plain `--print` + an OPEN stdin pipe, Claude's Node runtime buffers all
--   stdout until stdin EOF, so on_stdout never fires. That bug is specific to
--   --print WITHOUT --input-format stream-json. In stream-json INPUT mode Claude
--   runs a read-eval-stream loop and flushes per message with stdin held open.
--
-- Why jobstart, not vim.system? vim.system is fire-and-forget (one-shot async);
-- jobstart keeps the channel open so every turn writes a fresh message to the
-- same stdin without respawning.
--
-- Dependencies: core.state + core.opts + core.buf_append come from a direct
-- require; widgets (close_todo_widget/reflow_bottom_floats) is required directly.
-- Eleven init-owned helpers couple to init's render/spinner/hint/host-ctx
-- machinery (dispatch, render_*, spinner + hint stay in init because they hold
-- timers / touch the render foundation) and are injected via
-- Process.wire{} at load time. stdout_buf is module-owned here; init's
-- ensure_panel_buf / reset call Process.clear_stdout() to reset it on a fresh
-- panel/session.
--
-- Init re-sources send / enqueue / maybe_send_next / stop_process / uuid4 back
-- out (local X = process.X) for its submit path, teardown paths, and interrupt
-- control_request; the mod._send / mod._maybe_send_next / mod._stop_process test
-- hooks are re-exported from init.

local Process = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")

local state = core.state
local opts = core.opts
local buf_append = core.buf_append

-- Init-owned helpers, injected by Process.wire{} at load time (see init.lua).
-- Declared as forward locals so the process functions below close over them.
local dispatch -- event dispatcher (on_stdout routes events to it)
local render_user -- transcript echo of a new user turn
local render_queue -- shaded virtual-line render of the type-ahead queue
local remove_typing_ph -- clear a lingering typing placeholder before the echo
local start_spinner
local stop_spinner
local clear_hint
local set_hint
local attach_host_context -- first-turn @<file> mention (host-ctx cluster stays in init)
local FLAVOR -- flavour-word table (its DONE twin stays in init)
local claude_bin -- mod.CLAUDE_BIN (the resolved `claude` binary path)
local abort_decision_state -- render's decision/compact teardown sweep (on_exit strands otherwise)

--- Inject init's render/spinner/hint/host-ctx helpers + the FLAVOR table + the
--- claude binary path. Called once from init after those are defined (dispatch,
--- render_*, and attach_host_context all live further down init but are defined
--- before the wire call site).
function Process.wire(hooks)
	dispatch = hooks.dispatch
	render_user = hooks.render_user
	render_queue = hooks.render_queue
	remove_typing_ph = hooks.remove_typing_ph
	start_spinner = hooks.start_spinner
	stop_spinner = hooks.stop_spinner
	clear_hint = hooks.clear_hint
	set_hint = hooks.set_hint
	attach_host_context = hooks.attach_host_context
	FLAVOR = hooks.FLAVOR
	claude_bin = hooks.claude_bin
	abort_decision_state = hooks.abort_decision_state
end

-- Partial-line carry between on_stdout calls (see on_stdout). Module-owned; init
-- resets it via Process.clear_stdout() on a fresh panel buffer / session reset.
local stdout_buf = ""

-- One render-error notice per turn. A renderer
-- throw repeats for every further event in the turn (same broken shape streams
-- again); notifying each one buries the editor in error toasts. Re-armed at
-- dispatch_send so the NEXT broken turn is not silent.
local dispatch_error_notified = false

-- Raw-event capture for wire-format discovery. When $KODEX_CLAUDE_EVENTLOG points
-- at a path, every complete stream-json line is appended verbatim BEFORE decode —
-- so even lines that fail JSON parse (ANSI noise, half-known event shapes) land in
-- the log. Off by default (nil env = zero overhead). Recipe: launch Neovim from a
-- GNOME terminal with the var set, drive the panel through /compact or up to a rate
-- limit, then read the JSONL to see the actual event the CLI emits.
--   KODEX_CLAUDE_EVENTLOG=/tmp/claude-events.jsonl nvim
local eventlog_path = vim.env.KODEX_CLAUDE_EVENTLOG
local function eventlog_write(line)
	if not eventlog_path then
		return
	end
	-- lstat (NOT stat) so a pre-planted symlink at eventlog_path is seen as a
	-- symlink, not followed — every line written here is a raw stream-json
	-- turn (full conversation, tool-read file contents, any credential the
	-- session touched); a symlink redirect would append that verbatim into
	-- whatever the link points at. Same guard `mod.caveman_active` (init.lua)
	-- already applies on the read side.
	local st = vim.loop.fs_lstat(eventlog_path)
	if st and st.type ~= "file" then
		return
	end
	local fd = vim.loop.fs_open(eventlog_path, "a", tonumber("600", 8))
	if not fd then
		return
	end
	vim.loop.fs_write(fd, line .. "\n")
	vim.loop.fs_close(fd)
end

--- Reset the stdout line-buffer. Called by init's ensure_panel_buf (new buffer)
--- and reset() (fresh session) so no stale partial line bleeds across sessions.
function Process.clear_stdout()
	stdout_buf = ""
end

-- Generate a RFC-4122 v4 UUID in pure Lua (no shell-out to uuidgen). Used for the
-- interrupt control_request. math.random is seeded once at require.
math.randomseed(os.time() + (vim.loop.hrtime() % 1000000))
local function uuid4()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (
		template:gsub("[xy]", function(c)
			local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
			return string.format("%x", v)
		end)
	)
end
Process.uuid4 = uuid4

-- Encode + write one stream-json {type:"user"} turn message to the live
-- process's stdin. Shared by dispatch_send, steer, and send_followup — all
-- three write the identical envelope; factored so a checked-send fix lands
-- once instead of drifting across three copies (process.lua:433 finding).
-- Returns true only when the write actually landed (chansend returning 0
-- means the channel is closed/closing — the process died between the last
-- check and this write).
local function write_user_message(text)
	local msg = vim.json.encode({
		type = "user",
		message = { role = "user", content = { { type = "text", text = text } } },
	})
	local ok, written = pcall(vim.fn.chansend, state.job_id, msg .. "\n")
	return ok and written ~= 0
end

-- Standing guidance appended to the panel session's system prompt. In headless
-- SDK mode claude has no Grep/Glob tool, so it searches via Bash — steer it to
-- `ast-grep`/`rg` as the LEADING command (not piped through cat/grep) so the
-- Search-block renderer fires and search is structural. `sg` is off-limits: on
-- this machine it resolves to the system group tool, not ast-grep.
local SEARCH_NUDGE = table.concat({
	"For code search, run the `ast-grep` COMMAND-LINE TOOL (the shell binary) for ",
	"structural/AST queries and `rg` (ripgrep) for plain-text search, as the ",
	"leading shell command — never piped through `cat` or `grep`. Do NOT launch ",
	"the `ast-grep` skill for searches; call the `ast-grep` binary directly in ",
	"Bash. Never run `sg`: on this system it is the group-management tool, not ",
	"ast-grep — always spell it `ast-grep`.",
}, "")

-- Directories to guarantee on the panel process's PATH. GNOME launches nvim
-- without sourcing shell rc, so nvm/npm-global/linuxbrew bins (where ast-grep
-- lives) are missing — the Bash search tools would then not resolve. Globbed so
-- a node upgrade doesn't break it; nonexistent dirs are dropped.
local function panel_path()
	local dirs = {}
	local function add(d)
		if d ~= "" and vim.fn.isdirectory(d) == 1 then
			dirs[#dirs + 1] = d
		end
	end
	add(vim.fn.expand("~/.local/bin"))
	add(vim.fn.expand("~/.npm-global/bin"))
	add("/home/linuxbrew/.linuxbrew/bin")
	for _, d in ipairs(vim.fn.glob(vim.fn.expand("~/.nvm/versions/node/*/bin"), true, true)) do
		add(d)
	end
	return table.concat(dirs, ":") .. ":" .. (vim.env.PATH or "")
end

-- Build the argv for the persistent process from current session settings
-- (model + permission mode). Separated out so respawns (model/plan changes)
-- reuse the exact same construction.
local function build_args()
	local args = {
		claude_bin,
		"--print",
		"--input-format",
		"stream-json",
		"--output-format",
		"stream-json",
		"--verbose",
		-- Emit incremental stream_event records (Anthropic SSE: content_block_start/
		-- delta/stop) ON TOP OF the aggregated assistant message. We use only the
		-- thinking block's start/stop to drive a live "Thinking… 2.3s" counter; the
		-- final assistant event still does the actual rendering, so this is additive.
		"--include-partial-messages",
		"--permission-mode",
		state.permission_mode or "default",
		-- Hidden flag (not in --help, but accepted): the literal string "stdio". The
		-- SDK sets this internally when a canUseTool callback is registered. It makes
		-- the CLI emit can_use_tool control_requests over stdout for any tool not
		-- already allowlisted, which we answer over stdin (dispatch + can_use_tool
		-- branch). Without it the CLI silently auto-denies un-allowlisted tools.
		-- Must persist across model/plan respawns (plan-mode only varies
		-- --permission-mode, never drops this flag).
		"--permission-prompt-tool",
		"stdio",
		-- Steer search toward ast-grep/rg so the Search-block renderer fires (headless
		-- claude has no Grep tool). Persists across model/plan respawns.
		"--append-system-prompt",
		SEARCH_NUDGE,
	}
	-- --model accepts an alias (opus/sonnet/haiku) or a full id. nil = CLI default.
	if state.model and state.model ~= "" then
		table.insert(args, "--model")
		table.insert(args, state.model)
	end
	-- --effort sets the session reasoning-effort level (low/medium/high/xhigh/max);
	-- nil leaves it unset so the model default applies. Spawn-time flag, so the
	-- /effort slider respawns the process to change it (same as --model).
	if state.effort and state.effort ~= "" then
		table.insert(args, "--effort")
		table.insert(args, state.effort)
	end
	-- --advisor sets the server-side advisor model at spawn (hidden flag, accepted
	-- but not in --help). nil = No advisor → omit the flag so the CLI leaves it
	-- unset. Mid-session changes go through apply_flag_settings (no respawn), so
	-- this only seeds a FRESH session with the current pick.
	if state.advisor_model and state.advisor_model ~= "" then
		table.insert(args, "--advisor")
		table.insert(args, state.advisor_model)
	end
	return args
end

-- Deep-strip vim.NIL from a decoded event.
-- vim.json.decode maps JSON null → vim.NIL, a TRUTHY userdata, so every
-- `field or fallback` idiom downstream keeps the userdata and crashes in
-- concat/split/ipairs — one null field from the CLI killed the render (worst
-- case: a null display_name meant the permission card never opened and the CLI
-- blocked forever on the unanswered gate). Normalizing ONCE here, at the only
-- decode boundary, lets every renderer's `or` fallback work as written instead
-- of guarding ~30 call sites. Lists are rebuilt without their null slots — a
-- nil punched into the array part would be an ipairs-stopping hole.
local function strip_nulls(node)
	if vim.islist(node) then
		-- An empty table is ambiguous between JSON `[]` and `{}` — vim.islist
		-- treats {} as a (zero-length) list, so an empty object nested in a
		-- decoded event would otherwise silently re-encode as `[]` downstream,
		-- losing its empty_dict identity.
		if next(node) == nil then
			return node
		end
		local compacted = {}
		for _, item in ipairs(node) do
			if item ~= vim.NIL then
				table.insert(compacted, type(item) == "table" and strip_nulls(item) or item)
			end
		end
		return compacted
	end
	for key, field in pairs(node) do
		if field == vim.NIL then
			node[key] = nil
		elseif type(field) == "table" then
			node[key] = strip_nulls(field)
		end
	end
	return node
end

-- Neovim's on_stdout callback. CRITICAL: jobstart splits stdout on "\n" and
-- STRIPS the newlines before calling us — `data` is a list of line fragments,
-- NOT raw bytes. The convention (see :h channel-lines):
--   * data[1] continues the partial line left over from the previous call,
--   * data[#data] is this call's new partial line (often "" when the stream
--     ended exactly on a newline).
-- So we prepend the saved tail to data[1], pop the last element as the new
-- tail, and every remaining element is a complete line. (Concatenating the
-- fragments and re-splitting on "\n" would be wrong: there are no "\n" left,
-- so all events collapse into one invalid-JSON blob and nothing renders.)
local function on_stdout(_, data, _)
	if not data then
		return
	end
	data[1] = stdout_buf .. data[1]
	stdout_buf = table.remove(data) -- new partial tail for the next call

	for _, line in ipairs(data) do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			eventlog_write(trimmed) -- verbatim capture BEFORE decode (see eventlog_path)
			-- pcall: ANSI noise lines that slip through (e.g. cursor movement codes)
			-- are not valid JSON; silently skip rather than surfacing an error.
			local ok, event = pcall(vim.json.decode, trimmed)
			if ok and type(event) == "table" then
				event = strip_nulls(event)
				-- vim.schedule: dispatch modifies the buffer (appends lines, sets
				-- highlights, creates folds). These operations are forbidden inside an
				-- on_stdout callback because libuv callbacks run on the event loop,
				-- not inside the Neovim API safe zone. vim.schedule defers to the next
				-- safe iteration of the event loop.
				vim.schedule(function()
					-- pcall: one malformed event must not kill the stream. Unhandled,
					-- a renderer throw here spams one scheduled-callback error per further
					-- event, and a throw landing between a modifiable=true…false seam
					-- (render_tool_result, render_edit_hunk, expand_result) leaves the
					-- panel buffer editable — so re-lock it before moving on.
					local dispatched, dispatch_err = pcall(dispatch, event)
					if not dispatched then
						if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
							vim.bo[state.panel_buf].modifiable = false
						end
						if not dispatch_error_notified then
							dispatch_error_notified = true
							vim.notify(
								"Claude panel render error — event dropped: " .. tostring(dispatch_err),
								vim.log.levels.ERROR
							)
						end
					end
				end)
			end
		end
	end
end

-- on_exit fires when the persistent process ends — process crash, model/plan
-- respawn (jobstop), reset(), or panel close. Unlike the old per-message arch,
-- a clean exit here is NOT a turn boundary (turns end on the `result` event);
-- it means the whole session is gone. We clear job_id so the next send respawns
-- a fresh process (conversation context is lost — note the warning on crashes).
--   code 0 / 143 (SIGTERM) / -1 = intentional stop or graceful end → quiet
--   anything else               = crash → notify (panel stays; next send respawns)
local function on_exit(_, code, _)
	state.job_id = nil
	state.working = false
	state.system_ready = false
	stdout_buf = ""

	vim.schedule(function()
		-- stop_spinner reaches the buffer (remove_typing_ph → nvim_buf_set_lines)
		-- and must run inside the schedule, not in the raw libuv job callback — a
		-- buffer op there can hit textlock/fast-context errors exactly when the
		-- process dies (the worst moment to throw). The plain state resets above are
		-- safe outside; only this teardown touches the API.
		stop_spinner()
		-- A dead CLI can never answer the decision a card is blocked on — sweep
		-- stranded cards/queues/pre-write holds + the compact zombie timer
		-- before the notify, so the user sees the receipts and the exit reason
		-- together. Scheduled: the sweep closes windows and appends buffer lines.
		if abort_decision_state then
			abort_decision_state("session ended")
		end
		local clean = (code == 0 or code == 143 or code == -1)
		if not clean then
			vim.notify(
				"Claude session exited (code " .. code .. ") — next message starts a fresh session",
				vim.log.levels.WARN
			)
		end
		-- Either way the panel stays open. Restore the reply hint unless a diff is
		-- still pending review.
		if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
			if state.diff_pending then
				set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
			else
				clear_hint()
			end
		end
	end)
end

-- Spawn the persistent process if it isn't already running. Returns the job id,
-- or nil on failure (after notifying). stdin is deliberately LEFT OPEN — every
-- turn writes a new stream-json message to it; closing it would EOF the session.
local function ensure_process()
	if state.job_id then
		return state.job_id
	end
	stdout_buf = ""
	-- Fresh session: the CLI restarts its "Task #N" counter at 1, so drop any prior
	-- task list + our id counter to realign (Task* widget). This is
	-- the genuine once-per-session hook — system/init fires per TURN, not per spawn.
	if state.todos then
		state.todos, state.todo_seq = nil, nil
		widgets.close_todo_widget()
		widgets.reflow_bottom_floats()
	end
	local job = vim.fn.jobstart(build_args(), {
		cwd = state.stored_root or vim.fn.getcwd(),
		-- PATH: prepend nvm/npm-global/linuxbrew/~/.local/bin so the Bash search
		-- tools (ast-grep/rg) resolve — GNOME launches nvim without shell rc, so
		-- those dirs are otherwise absent. CAVEMAN_DEFAULT_MODE disables caveman for
		-- the panel's claude (the plugin's env override) so it speaks normally even
		-- when interactive sessions default to caveman. env EXTENDS the inherited
		-- environment (setting PATH here replaces only PATH in the child).
		env = vim.tbl_extend(
			"force",
			{ PATH = panel_path() },
			opts.caveman_mode and { CAVEMAN_DEFAULT_MODE = opts.caveman_mode } or {}
		),
		on_stdout = on_stdout,
		on_stderr = function() end,
		on_exit = on_exit,
	})
	if job <= 0 then
		vim.notify("Claude: failed to start subprocess", vim.log.levels.ERROR)
		return nil
	end
	state.job_id = job
	return job
end

-- Stop the persistent process (panel close / reset / model+plan respawn).
-- jobstop sends SIGTERM; on_exit fires asynchronously and clears job_id, so we
-- null it here too to make an immediate respawn safe.
local function stop_process()
	if state.job_id then
		pcall(vim.fn.jobstop, state.job_id)
		state.job_id = nil
	end
	stop_spinner()
	state.working = false
end
Process.stop_process = stop_process

-- Write a stream-json user message to the live process and arm the working
-- state + spinner. Spawns the process on first use. Does NOT echo — callers that
-- want the transcript echo call render_user first (see send).
local function dispatch_send(text)
	if not ensure_process() then
		clear_hint()
		return false
	end
	state.system_ready = false
	state.working = true
	dispatch_error_notified = false -- fresh turn: next render error notifies again
	state.turn_t0 = vim.loop.now() -- cumulative turn timer (every spinner phase + churn line)
	state.turn_paused_ms = 0 -- fresh turn: no accumulated modal-wait pause yet
	state.pause_t0 = nil -- not currently paused on a decision modal
	state.activity_t0 = vim.loop.now() -- baseline for the first thinking block's timer
	state.think_dur = nil -- no stale duration from a prior turn
	state.think_tokens = 0 -- live in-flight estimate for the current message
	state.think_base = 0 -- prior thinking block(s)' total within the current message
	state.turn_output_tokens = 0 -- committed total across every message_delta this turn
	state.tool_run = nil
	-- One flavour word per REQUEST, fixed for the whole turn (like the official
	-- TUI) — picked here, NOT rotated mid-turn while thinking/working. Store the
	-- INDEX (not just the word) so render_result's done line can reuse it and the
	-- past-tense "✻ Proofed for 4m" rhymes with the live "Proofing…" the user saw.
	state.flavor_idx = math.random(#FLAVOR)
	state.flavor_word = FLAVOR[state.flavor_idx]
	start_spinner()
	-- One stream-json `user` message per turn. The process reads it from stdin,
	-- streams events back, and waits for the next message. A failed write (the
	-- process died between ensure_process and here, before on_exit fired) used
	-- to leave state.working=true + the spinner climbing forever with no result
	-- event ever coming — treat it as process death: tear down the working
	-- state so the panel doesn't hang. on_exit still runs its own sweep when
	-- the async exit lands.
	if not write_user_message(text) then
		state.working = false
		stop_spinner()
		clear_hint()
		vim.notify(
			"Claude: message not delivered (session closed) — next message starts a fresh session",
			vim.log.levels.WARN
		)
		return false
	end
	return true
end

-- Send a brand-new turn: echo the message into the transcript (normal colour),
-- a blank line so the spinner gets its own line, then dispatch it.
-- `dispatch_override` (optional): echo `text` in the transcript as usual but send a
-- DIFFERENT string to the CLI. Used for a mid-sentence slash command — the user sees
-- their full prose, while only the extracted "/command" is dispatched so the CLI
-- actually runs it (it won't parse a command buried in a sentence). nil = normal turn.
local function send(text, dispatch_override)
	-- Clear any lingering placeholder BEFORE the user echo. render_user runs before
	-- dispatch_send's start_spinner, so a placeholder still on the last line (a turn
	-- that ended without a result event, or a rapid re-send) would otherwise get the
	-- echo appended below it — and then stop_spinner's "delete last line" would eat
	-- the echo instead of the placeholder.
	remove_typing_ph()
	-- Resolve the open-buffer @-mention BEFORE the echo so render_user can show the
	-- dim "· with @file" note (v2c). wire carries the mention; note = the display
	-- path when an attach fired this turn (nil = nothing attached, no note).
	local wire, note = attach_host_context(text)
	render_user(text, note)
	buf_append({ "" })
	dispatch_send(dispatch_override or wire)
end
Process.send = send

-- Queue a message typed while a turn is in flight. It shows as a shaded virtual
-- line at the panel bottom (render_queue) and is drained when the turn ends.
local function enqueue(text)
	state.queue[#state.queue + 1] = text
	render_queue()
end
Process.enqueue = enqueue

-- After a turn ends, send the next queued message (if any). The queued item then
-- echoes in the normal user colour via send() — i.e. it "registers" with Claude.
local function maybe_send_next()
	if state.working or #state.queue == 0 then
		return
	end
	local text = table.remove(state.queue, 1)
	render_queue()
	send(text)
end
Process.maybe_send_next = maybe_send_next

-- Steer: push pending messages INTO the running turn instead of waiting for it to
-- end. Proven 2026-07-15 (FINDINGS § Q-STEER) — a {type:"user"} written to the live
-- stdin mid-turn is absorbed by the model at its next step: same turn, no interrupt.
-- Flushes any already-queued messages AND the just-typed `text`, so ctrl+Enter pushes
-- everything pending in at once. Deliberately does NOT touch turn state (working /
-- timers / spinner / flavor) — dispatch_send's turn-setup is for STARTING a turn; this
-- rides the one already in flight. No-op (returns false) when idle so the caller can
-- fall back to a normal send.
local function steer(text)
	if not (state.job_id and state.working) then
		return false
	end
	local msgs = {}
	for _, q in ipairs(state.queue) do
		msgs[#msgs + 1] = q
	end
	state.queue = {}
	if text and text ~= "" then
		msgs[#msgs + 1] = text
	end
	if #msgs == 0 then
		render_queue()
		return false
	end
	-- Drop the mid-turn "typing" placeholder BEFORE echoing (every content-appending
	-- branch does this — see init's PH_FRAMES note). Without it the echo lands AFTER the
	-- placeholder's two tail lines, and the next stream event's remove_typing_ph deletes
	-- the LAST two lines — eating the steered prompt and leaving only the orange turn
	-- separator (user-reported 2026-07-15). The next stream event re-adds the placeholder
	-- below the echo.
	remove_typing_ph()
	for index, m in ipairs(msgs) do
		render_user(m, nil, true) -- echo as a steered user line (mid-transcript)
		-- write_user_message can fail mid-loop (process died between messages).
		-- Sibling senders (dispatch_send, send_followup) already guard this
		-- exact write; steer was the one holdout — a dropped write here quietly
		-- lost the user's queued + just-typed messages while the transcript
		-- still showed them as delivered. Restore whatever didn't make it back
		-- onto the queue rather than discarding it.
		if not write_user_message(m) then
			for restore = index, #msgs do
				state.queue[#state.queue + 1] = msgs[restore]
			end
			render_queue()
			vim.notify(
				"Claude: message not delivered (session closed) — next message starts a fresh session",
				vim.log.levels.WARN
			)
			return true
		end
	end
	render_queue() -- queue drained → clear the amber queued lines
	return true
end
Process.steer = steer

-- Send exactly ONE follow-up line into the live turn, WITHOUT touching state.queue.
-- Same wire mechanic as steer() (a mid-turn {type:"user"} stream-json line, same
-- "↳ steered" echo via render_user) but deliberately does NOT drain the queue —
-- steer's queue-flush is right for its own caller (ctrl+i: "push everything pending
-- in now"), but wrong for an unrelated caller that just wants to deliver one specific
-- string. Reusing steer() wholesale for that would silently inject whatever the user
-- had queued for AFTER the turn (a message they expected to send once idle) into the
-- turn early, as a side effect of an unrelated action. Used by gate.lua's permission-
-- card Tab-to-annotate: the note is scoped to the decision being annotated, nothing
-- else. No-op (returns false) when idle, same contract as steer().
local function send_followup(text)
	if not (state.job_id and state.working) then
		return false
	end
	if not text or text == "" then
		return false
	end
	remove_typing_ph()
	render_user(text, nil, true)
	return write_user_message(text)
end
Process.send_followup = send_followup

return Process
