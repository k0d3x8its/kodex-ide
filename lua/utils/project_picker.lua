-- lua/utils/project_picker.lua
-- Shown on dock launch (KODEX_IDE=1). Lets the user pick a project or resume the
-- last session, THEN choose which AI panel to open, before it launches.
-- Panel choice is a runtime prompt (Goal 11 redesign 2026-06-28), no longer the
-- KODEX_CLAUDE launch env var — a single launcher, one chooser. Both sites that
-- open the panel read the stored choice (chosen_panel) to route correctly.

local mod = {}

-- Scan the auto-session storage dir and return the unescaped project path
-- with the highest mtime, but only considering sessions that correspond to a
-- known ~/dev/* project. This prevents stray sessions (e.g. ~/dev itself, or
-- a tmp dir opened once) from being picked up by "Resume last session".
-- Returns nil when no qualifying session exists yet.
local function latest_project_session(session_dir, projects)
	local best = { name = nil, mtime = 0 }
	local Lib = require("auto-session.lib")

	for _, proj in ipairs(projects) do
		-- auto-session percent-encodes the path as the filename, e.g.
		-- /home/k0d3x/dev/kodex-ide → %2Fhome%2Fk0d3x%2Fdev%2Fkodex-ide.vim
		local filename = Lib.escape_session_name(proj) .. ".vim"
		local mtime = vim.fn.getftime(session_dir .. filename)
		-- getftime returns -1 when the file doesn't exist
		if mtime > best.mtime then
			best.mtime = mtime
			best.name = proj
		end
	end

	return best.name
end

-- Which AI panel the user picked for this launch: "claude" or "opencode".
-- Set by pick_panel() (fired from finish()) BEFORE open_workspace opens anything;
-- read at both open_workspace launch sites via open_panel(). Replaces the old
-- KODEX_CLAUDE launch-env branch (Goal 11 redesign 2026-06-28).
local chosen_panel = "opencode"

-- Resolves the vim.ui.select panel-choice callback's `selection` arg into a
-- chosen_panel value. Dismiss (Esc) passes nil here, same as any selection
-- other than "Claude Code" — both fall through to "opencode", the historical
-- dock default (least surprising for anyone who just hits Enter/Esc).
local function resolve_chosen_panel(selection)
	return (selection == "Claude Code") and "claude" or "opencode"
end

-- Open the AI panel the user chose, seeded with the project root.
-- Single routing point for both open_workspace sites (resumed + fresh-file).
local function open_panel(proj)
	if chosen_panel == "claude" then
		require("utils.claude").open(proj)
	else
		require("utils.opencode").open()
	end
end

-- After the project root is resolved, open the file-tree sidebar and arrange
-- for the AI panel to launch when the user opens their first file.
-- User decision (2026-06-13): the AI panel starts AFTER a file is chosen,
-- seeded with that file, rather than immediately on project pick.
-- Which panel opens is the user's runtime choice (chosen_panel) at both sites.
local function open_workspace(proj)
	-- Resumed session: a real file window is already open. Launch OpenCode now,
	-- seeded with that file. Do NOT open the sidebar — the tree is only wanted on
	-- a fresh session (user decision 2026-06-13).
	local file_win
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(win)
		if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
			file_win = win
			break
		end
	end

	if file_win then
		vim.api.nvim_set_current_win(file_win)
		open_panel(proj)
		return
	end

	-- Fresh project: open the sidebar rooted at the project. OpenCode launches
	-- when the user opens their first file (one-shot BufWinEnter), seeded with it.
	-- After it launches, focus returns to the sidebar so the user is NOT dropped
	-- into OpenCode's insert prompt — they close the tree manually when ready.
	-- KodexAIFirstFile: shared augroup name for both OpenCode and Claude dock
	-- flows — either launcher fires this one-shot BufWinEnter (MG 9.3).
	local group = vim.api.nvim_create_augroup("KodexAIFirstFile", { clear = true })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = function(args)
			-- only real file buffers — skip terminals, [No Name], dashboard, tree
			if vim.bo[args.buf].buftype ~= "" then
				return
			end
			if vim.api.nvim_buf_get_name(args.buf) == "" then
				return
			end
			local ft = vim.bo[args.buf].filetype
			if ft == "alpha" or ft == "NvimTree" then
				return
			end
			vim.api.nvim_del_augroup_by_id(group)
			-- Same routing as the resumed-session path above (MG 9.3 site 2).
			open_panel(proj)
			-- Return focus to the sidebar instead of the AI panel's insert prompt.
			-- Deferred so it runs after toggleterm finishes opening + entering insert.
			vim.schedule(function()
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "NvimTree" then
						vim.api.nvim_set_current_win(win)
						vim.cmd("stopinsert") -- belt-and-suspenders: leave terminal insert
						break
					end
				end
			end)
		end,
	})

	-- Open the file-tree rooted at the project so the user can pick a file.
	-- change_root is explicit because tree.open reuses its initial root (the
	-- startup cwd, e.g. ~/dev) instead of the project the picker cd'd into.
	local tree_api = require("nvim-tree.api")
	tree_api.tree.open()
	tree_api.tree.change_root(proj)
end

-- Ask which AI panel to open — AFTER the repo + session decisions, BEFORE the
-- panel launches. The choice is stored in chosen_panel, read at both
-- open_workspace sites. Then defer 200 ms so any restore_session() source()
-- call finishes opening buffers before open_workspace inspects the window
-- layout.
local function finish(proj)
	vim.ui.select({ "OpenCode", "Claude Code" }, {
		prompt = "Open which AI panel?",
	}, function(panel)
		chosen_panel = resolve_chosen_panel(panel)
		vim.defer_fn(function()
			open_workspace(proj)
		end, 200)
	end)
end

function mod.pick()
	-- auto-session public API: restore_session(name) and get_root_dir()
	local AutoSession = require("auto-session")

	-- Glob ~/dev/*/ to get all immediate project subdirs.
	-- Trailing slash stripped so fnameescape + cd work cleanly.
	local dev_path = vim.fn.expand("~/dev/")
	local raw = vim.fn.glob(dev_path .. "*/", true, true)
	local projects = {}
	for _, dir in ipairs(raw) do
		table.insert(projects, (dir:gsub("/$", "")))
	end

	-- "Resume last session" always appears first; projects follow in glob order.
	local RESUME = "Resume last session"
	local items = { RESUME }
	vim.list_extend(items, projects)

	-- dressing.nvim intercepts vim.ui.select and renders a telescope/fzf picker
	-- automatically — no extra setup needed here.
	vim.ui.select(items, {
		prompt = "Kodex IDE — open project:",
		-- Show only the directory basename; full path is shown in the picker footer
		-- by dressing if the user inspects the raw item.
		format_item = function(item)
			if item == RESUME then
				return item
			end
			return vim.fn.fnamemodify(item, ":t")
		end,
	}, function(choice)
		-- nil means the user dismissed the picker — do nothing.
		if not choice then
			return
		end

		if choice == RESUME then
			-- get_root_dir() returns the session-storage dir on disk, not a project root.
			-- We search only sessions matching known ~/dev/* projects so that sessions
			-- for parent dirs (~/dev, ~/, etc.) are never accidentally resumed.
			local session_dir = AutoSession.get_root_dir()
			local latest = latest_project_session(session_dir, projects)
			if not latest then
				vim.notify("No project sessions found — pick a project to start one", vim.log.levels.INFO)
				return
			end
			-- restore_session(name) re-escapes the path to locate the session file,
			-- then sources it — which cds and reopens the saved buffers.
			AutoSession.restore_session(latest)
			finish(latest)
			return
		end

		-- Project chosen. cd first so a fresh start roots correctly and so
		-- restore_session() (called with no args) resolves this project's session file.
		vim.cmd("cd " .. vim.fn.fnameescape(choice))

		-- Detect an existing saved session for this project (getftime → -1 if absent).
		local Lib = require("auto-session.lib")
		local session_file = AutoSession.get_root_dir() .. Lib.escape_session_name(choice) .. ".vim"
		local has_session = vim.fn.getftime(session_file) ~= -1

		if not has_session then
			-- No session yet → straight to fresh: open_workspace opens the sidebar and
			-- defers OpenCode until the first file is picked. No prompt.
			finish(choice)
			return
		end

		-- Existing session → let the user choose restore vs fresh instead of silently
		-- auto-restoring (user decision 2026-06-13).
		vim.ui.select({ "Restore session", "New session" }, {
			prompt = "Session found for " .. vim.fn.fnamemodify(choice, ":t") .. ":",
		}, function(action)
			-- Dismiss (Esc) defaults to Restore — preserves the old silent-restore
			-- behavior the user is accustomed to, least surprising.
			if not action or action == "Restore session" then
				AutoSession.restore_session()
			end
			-- "New session": skip restore entirely. The stale session file is left in
			-- place and gets overwritten by auto-session's autosave on next exit
			-- (user decision 2026-06-13 — no explicit delete, lower risk than rm).
			finish(choice)
		end)
	end)
end

-- Test-only hooks: the panel-choice routing (chosen_panel, open_panel,
-- finish) is the core branch point this module adds, but all three were
-- module-local with no seam to drive from a spec. Exposed narrowly rather
-- than restructuring pick() itself.
mod._open_panel = open_panel
mod._resolve_chosen_panel = resolve_chosen_panel
mod._finish = finish
mod._set_chosen_panel = function(value)
	chosen_panel = value
end

return mod
