-- tests/claude_reopen_bar_interleave_spec.lua
-- Advisor-requested verification (2026-08-14, second consult on Goal 12 batch 1
-- triage): the reopen-bar race fix (gate.lua's resolve_permission, mirrored in
-- question.lua/init.lua) now consumes state.decision_reopen_bar INSIDE the
-- scheduled callback instead of before scheduling, so a second decision card
-- arriving in the gap can inherit the still-true flag rather than finding it
-- already spent. This proves the inverse risk didn't get introduced: exactly
-- ONE bar-reopen must happen when card A resolves, card B arrives before card
-- A's scheduled callback runs, and card B resolves — not zero (stranded) and
-- not two (double-open).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_reopen_bar_interleave_spec.lua"

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
local gate = require("utils.claude.gate")

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)

-- Open the REAL chat bar so state.chat_win is genuinely valid (the guard the
-- race depends on: show_permission_card only arms decision_reopen_bar when a
-- real bar is open to dismiss).
claude.prompt_input()
vim.wait(30)
H.check(
	"chat bar open before the sequence",
	claude.state.chat_win ~= nil and vim.api.nvim_win_is_valid(claude.state.chat_win)
)

local open_count = 0
local real_open = claude._open_chat_float
claude._open_chat_float = function(...)
	open_count = open_count + 1
	return real_open(...)
end

local function mk_event(id)
	return {
		request_id = id,
		request = { subtype = "can_use_tool", tool_name = "Bash", input = { command = "ls" } },
	}
end

-- Card A arrives and is resolved SYNCHRONOUSLY (no vim.wait yet, so its
-- vim.schedule callback has not run) — dismisses the bar, arms
-- decision_reopen_bar, schedules the reopen.
gate.show_permission_card(mk_event("A"))
H.check("card A open", claude.state.perm ~= nil and claude.state.perm.request_id == "A")
gate.resolve_permission("deny")
H.check("card A resolved, decision_reopen_bar still armed pre-schedule", claude.state.decision_reopen_bar == true)

-- Card B arrives BEFORE card A's scheduled callback has run (we haven't
-- yielded to the event loop). state.chat_win is still invalid (never
-- reopened), so show_permission_card must NOT re-touch decision_reopen_bar —
-- it should stay true, inherited from card A.
gate.show_permission_card(mk_event("B"))
H.check("card B open, no bar to dismiss so flag untouched", claude.state.decision_reopen_bar == true)
H.check("card B did not touch chat bar", open_count == 0)

-- NOW yield: card A's scheduled callback fires. It must see card B still
-- gating (state.perm == B) and bail WITHOUT consuming the flag.
vim.wait(60)
H.check(
	"card A's callback deferred (gating card B still up)",
	claude.state.perm ~= nil and claude.state.perm.request_id == "B"
)
H.check("flag preserved across the deferred callback", claude.state.decision_reopen_bar == true)
H.check("still no reopen yet", open_count == 0)

-- Resolve card B — nothing else gating now, so ITS scheduled callback should
-- consume the flag and reopen exactly once.
gate.resolve_permission("deny")
vim.wait(60)

H.check("exactly one reopen — no strand, no double-open", open_count == 1, "open_count=" .. open_count)
H.check("flag consumed", claude.state.decision_reopen_bar == false)

claude._open_chat_float = real_open

H.summary("claude_reopen_bar_interleave")
