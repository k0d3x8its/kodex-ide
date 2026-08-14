-- tests/claude_prompt_input_gated_spec.lua
-- Coverage for the extended mod.prompt_input() guard (Goal 12 batch 1 Low
-- finding, init.lua:2525): the chat bar previously blocked only on
-- state.perm/state.diff_pending — a live state.qask (AskUserQuestion card) or
-- state.prewrite (held pre-write gate) could still be up while prompt_input()
-- opened the chat float over it, the same focus-steal/overlap failure gate.lua
-- guards against everywhere else. The fix reuses gate.lua's own gated()
-- helper (mod._gated) rather than re-deriving the field list.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_prompt_input_gated_spec.lua"

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

local opened = false
claude._open_chat_float = function(_title, cb)
	opened = true
	cb(nil) -- cancel immediately, don't need a real send for this spec
end

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)

-- ── Baseline: nothing gating → chat bar opens normally ────────────────────────
opened = false
claude.prompt_input()
H.check("no gate → chat bar opens", opened == true)

-- ── state.qask alone (no state.perm) used to slip through the OLD guard ───────
opened = false
claude.state.qask = { request_id = "q1", win = nil }
claude.prompt_input()
H.check("live qask blocks the chat bar", opened == false)
claude.state.qask = nil

-- ── state.prewrite alone (no state.perm) used to slip through the OLD guard ───
opened = false
claude.state.prewrite = { request_id = "pw1" }
claude.prompt_input()
H.check("live prewrite blocks the chat bar", opened == false)
claude.state.prewrite = nil

-- ── state.diff_card alone ──────────────────────────────────────────────────────
opened = false
claude.state.diff_card = { win = nil }
claude.prompt_input()
H.check("live diff_card blocks the chat bar", opened == false)
claude.state.diff_card = nil

-- ── Clearing the gate un-strands the bar — proves this is a wait, not a strand ─
opened = false
claude.prompt_input()
H.check("gate cleared → chat bar opens again (no permanent strand)", opened == true)

H.summary("claude_prompt_input_gated")
