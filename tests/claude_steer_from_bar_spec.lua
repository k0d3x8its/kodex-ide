-- tests/claude_steer_from_bar_spec.lua
-- Regression coverage for the 2026-07-28 fix: Tab/ctrl-i while the "/" slash
-- menu is open must call slash.accept() directly, not feed a <CR> that falls
-- through to the prompt buffer's own <CR> and submits the half-typed command
-- ("/cave"+Tab sent "/cave" as a message, live-reported). No prior test
-- exercised this path — claude_spec.lua's tests stub _open_chat_float entirely
-- (bypassing the real keymap), and claude_slash_spec.lua drives slash.lua
-- directly against a bare scratch buffer, never through init.lua's real
-- steer_from_bar closure. This spec goes through the REAL, unstubbed chat
-- float via the mod._steer_from_bar test hook (gate.lua's own Testing finding,
-- Goal 12 batch 1).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_steer_from_bar_spec.lua"

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
local slash = require("utils.claude.slash")

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)

-- Open the REAL chat bar (unstubbed _open_chat_float — the whole point of this
-- spec) so mod._steer_from_bar is the genuine closure wired to a genuine ibuf.
claude.prompt_input()
vim.wait(30)

H.check("chat bar opened", claude.state.chat_win ~= nil and vim.api.nvim_win_is_valid(claude.state.chat_win))
local ibuf = vim.api.nvim_win_get_buf(claude.state.chat_win)

H.check("steer_from_bar hook exported", type(claude._steer_from_bar) == "function")

-- ── Menu open: Tab must accept the selection, not submit ──────────────────────
slash._test_disk_names = {}
slash.open(ibuf, "", 0, function() end)
H.check("slash menu open", slash.active() == true)

claude.state.steer_pending = false
claude._steer_from_bar()

H.check("menu closed by accept, not left open", slash.active() == false)
H.check("steer_from_bar did NOT arm steer_pending (accept path, not submit path)", claude.state.steer_pending == false)
local last_line = vim.api.nvim_buf_get_lines(ibuf, -2, -1, false)[1] or ""
H.check("accepted command text inserted into the bar ('/' + name)", last_line:match("^❯? ?/%a+ $") ~= nil, last_line)

-- ── Menu closed, no turn running: Tab is a no-op (nothing to steer into) ──────
claude.state.working = false
claude.state.steer_pending = false
claude._steer_from_bar()
H.check("no-op when idle: steer_pending stays false", claude.state.steer_pending == false)

H.summary("claude_steer_from_bar")
