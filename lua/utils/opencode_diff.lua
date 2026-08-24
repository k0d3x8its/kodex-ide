-- lua/utils/opencode_diff.lua
-- Goal 3: intercepted FileChangedShell → queued vimdiff per file (findings Q6).
-- Mechanism prototype-validated 2026-06-11 (proto/, 9 hard cases) — the five
-- CORRECTION comments below are load-bearing; removing any of them silently
-- kills the interceptor. See proto/PROTO-NOTES.md.
--
-- v1 limitation (accepted, findings Q6): files NOT open in a buffer — including
-- new files opencode creates — fire no FileChangedShell at all; their changes
-- land on disk silently (gitsigns still shows them). fs_event watcher = backlog.

local M = {}

-- Shared panel state: opencode_active gates the interceptor, diff_queue holds
-- pending file paths. Owned by utils/opencode so reset() can clear both.
local opencode = require("utils.opencode")

M.state = {
	current = nil, -- file currently shown in diff
	scratch = nil, -- scratch buffer id of current diff
	orig_buf = nil, -- original buffer id of current diff
	debug = false, -- when true, events append to .log (port-verification suite only)
	log = {},
}

local function log(msg)
	if M.state.debug then
		table.insert(M.state.log, msg)
	end
end

-- Fetched live, never cached: opencode.reset() replaces the table wholesale
local function queue()
	return opencode.state.diff_queue
end

-- ---------------------------------------------------------------- queue logic

function M.push(path)
	if M.state.current == path then
		log("dedup-current:" .. path)
		return
	end
	for _, p in ipairs(queue()) do
		if p == path then
			log("dedup-queue:" .. path)
			return
		end
	end
	table.insert(queue(), path)
	log("queued:" .. path)
end

-- ---------------------------------------------------------------- diff window

local function close_diff()
	local s = M.state
	if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf) then
		local win = vim.fn.bufwinid(s.orig_buf)
		if win ~= -1 then
			vim.api.nvim_win_call(win, function()
				vim.cmd("diffoff")
			end)
		end
	end
	if s.scratch and vim.api.nvim_buf_is_valid(s.scratch) then
		vim.api.nvim_buf_delete(s.scratch, { force = true }) -- closes its window too
	end
	s.current, s.scratch, s.orig_buf = nil, nil, nil
	vim.schedule(M.process_next)
end

function M.accept_all()
	local s = M.state
	-- The original buffer can be :bd'd while the scratch diff is still open;
	-- writing into an invalid buffer throws. Bail to the next queue item instead.
	if
		not (
			s.scratch
			and vim.api.nvim_buf_is_valid(s.scratch)
			and s.orig_buf
			and vim.api.nvim_buf_is_valid(s.orig_buf)
		)
	then
		log("accept-all-skipped-invalid:" .. tostring(s.current))
		close_diff()
		return
	end
	local lines = vim.api.nvim_buf_get_lines(s.scratch, 0, -1, false)
	vim.api.nvim_buf_set_lines(s.orig_buf, 0, -1, false, lines)
	-- CORRECTION #5: bang required — disk changed since last *read*, and the FCS
	-- event doesn't sync the read-timestamp the overwrite check uses. Plain :w
	-- prompts "changed since reading it!!!" and blocks the UI.
	local name = vim.fn.fnamemodify(s.current or "?", ":t")
	local ok, err = pcall(vim.api.nvim_buf_call, s.orig_buf, function()
		vim.cmd("silent write!")
	end)
	if not ok then
		-- write failed (perms, disk full): the accepted content is in the buffer
		-- but NOT on disk. Warn and keep the diff open so the user can retry,
		-- rather than advancing as if the write succeeded.
		log("accept-all-FAILED:" .. tostring(err))
		vim.schedule(function()
			vim.notify("OpenCode: write FAILED for " .. name .. " — " .. tostring(err), vim.log.levels.ERROR)
		end)
		return
	end
	log("accept-all:" .. s.current)
	close_diff()
end

function M.reject_all()
	local s = M.state
	if not (s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf)) then
		close_diff()
		return
	end
	-- opencode already wrote the file: closing without writing leaves disk
	-- modified → next checktime re-queues the same file forever. Write original
	-- buffer content back to disk to neutralize (bang: see CORRECTION #5 above).
	local name = vim.fn.fnamemodify(s.current or "?", ":t")
	local ok, err = pcall(vim.api.nvim_buf_call, s.orig_buf, function()
		vim.cmd("silent write!")
	end)
	if not ok then
		-- write failed → opencode's changes are STILL on disk. Silently advancing
		-- here would make the user believe the revert succeeded (data loss). Warn
		-- loudly and keep the diff open so they can fix the cause and retry.
		log("reject-all-FAILED:" .. tostring(err))
		vim.schedule(function()
			vim.notify(
				"OpenCode: revert FAILED for " .. name .. " — changes still on disk: " .. tostring(err),
				vim.log.levels.ERROR
			)
		end)
		return
	end
	log("reject-all:" .. s.current)
	close_diff()
end

local function open_diff(path)
	local s = M.state
	local buf = vim.fn.bufnr(path)
	if buf == -1 then
		log("no-buffer:" .. path) -- v1 limitation, see header comment
		vim.schedule(M.process_next) -- don't strand the rest of the queue
		return
	end
	-- opencode may have DELETED the file (FCS fires for deletion too); readfile
	-- then throws inside this scheduled callback. Skip and drain the queue.
	local ok, disk = pcall(vim.fn.readfile, path)
	if not ok then
		log("readfile-failed:" .. path)
		vim.schedule(M.process_next)
		return
	end

	local scratch = vim.api.nvim_create_buf(false, true) -- nofile scratch
	vim.api.nvim_buf_set_lines(scratch, 0, -1, false, disk)
	vim.api.nvim_buf_set_name(scratch, "[OpenCode proposed] " .. vim.fn.fnamemodify(path, ":t"))

	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		vim.cmd("buffer " .. buf)
	else
		vim.api.nvim_set_current_win(win)
	end
	vim.cmd("diffthis")
	vim.cmd("rightbelow vsplit")
	vim.api.nvim_win_set_buf(0, scratch)
	vim.cmd("diffthis")

	-- Buffer-local on the scratch only (findings Q10) — auto-removed on close
	vim.keymap.set("n", "<leader>oa", M.accept_all, { buffer = scratch, desc = "OpenCode diff: accept all" })
	vim.keymap.set("n", "<leader>ox", M.reject_all, { buffer = scratch, desc = "OpenCode diff: reject all" })

	s.current, s.scratch, s.orig_buf = path, scratch, buf

	vim.notify(
		"OpenCode proposed changes — `do` accept hunk (from original window; :w after)"
			.. " | <leader>oa accept all | <leader>ox reject all",
		vim.log.levels.INFO
	)
	log("diff-open:" .. path)
end

function M.process_next()
	local s = M.state
	if s.current ~= nil or #queue() == 0 then
		return
	end
	open_diff(table.remove(queue(), 1))
end

-- ------------------------------------------------------------------- autocmds

-- CORRECTION #3: bare :checktime fires FileChangedShell only for the CURRENT
-- buffer — hidden buffers never fire and repeat passes don't recover the event.
-- Per-buffer `:checktime {bufnr}` is mandatory for multi-file opencode edits.
function M.checktime_all()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
			pcall(vim.cmd, "checktime " .. b)
		end
	end
end

local autocmds_ready = false

local function ensure_autocmds()
	if autocmds_ready then
		return
	end
	autocmds_ready = true

	local grp = vim.api.nvim_create_augroup("OpencodeDiff", { clear = true })

	vim.api.nvim_create_autocmd("FileChangedShell", {
		group = grp,
		pattern = "*",
		callback = function(ev)
			if not opencode.state.opencode_active then
				return -- default Neovim handling outside opencode sessions
			end
			-- CORRECTION #2: must be set synchronously in this callback, and the
			-- valid "autocmd handles everything" value is "" — "ignore" is invalid
			-- (silently behaves like "", the plan only worked by accident).
			vim.v.fcs_choice = ""
			local modified = vim.bo[ev.buf].modified
			log("fcs-fired:" .. ev.file .. (modified and ":WARN-local-edits" or ""))
			if modified then
				-- scheduled: noice renders notifications in floats, and window ops
				-- are forbidden inside a FileChangedShell callback
				vim.schedule(function()
					vim.notify(
						"OpenCode changed "
							.. vim.fn.fnamemodify(ev.file, ":t")
							.. " but the buffer has unsaved local edits — accept-all will overwrite them",
						vim.log.levels.WARN
					)
				end)
			end
			M.push(vim.api.nvim_buf_get_name(ev.buf))
			-- FileChangedShell forbids buffer/window changes inside the callback
			vim.schedule(M.process_next)
		end,
	})

	-- FileChangedShell never fires on its own for same-process :terminal children
	-- (no FocusGained). Poll via checktime while the panel is active.
	vim.api.nvim_create_autocmd({ "TermLeave", "WinEnter", "CursorHold" }, {
		group = grp,
		-- CORRECTION #4: autocmds don't nest by default — without this, the
		-- FileChangedShell triggered by checktime-inside-this-autocmd is suppressed
		-- and Neovim falls back to the default W11 warning, bypassing the interceptor.
		nested = true,
		callback = function()
			if opencode.state.opencode_active then
				M.checktime_all()
			end
		end,
	})
end

-- ------------------------------------------------------- panel open/close hooks

local saved_autoread = nil

--- Called from the panel's on_open (utils/opencode create_term)
function M.on_panel_open()
	ensure_autocmds()
	-- CORRECTION #1: with autoread set (nvim default ON) and an unmodified
	-- buffer, FileChangedShell is never triggered — Neovim silently reloads and
	-- the whole interceptor is dead code. Off while the panel is open.
	if saved_autoread == nil then
		saved_autoread = vim.o.autoread
	end
	vim.o.autoread = false
end

--- Called from the panel's on_close and from reset(); idempotent
function M.on_panel_close()
	if saved_autoread ~= nil then
		vim.o.autoread = saved_autoread
		saved_autoread = nil
	end
end

return M
