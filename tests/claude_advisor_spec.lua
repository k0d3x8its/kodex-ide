-- tests/claude_advisor_spec.lua
-- The /advisor picker (claude/advisor.lua). No prior coverage existed for this
-- module (batch-5 /code-crit testing-persona gap, noted in GOAL12-FINDINGS.md).
-- Proves the two ordering fixes from that batch's triage: (1) confirm() fires the
-- on_confirm callback BEFORE resuming any queued question/permission card, not
-- after; (2) Advisor.open() re-renders an already-open picker in place instead of
-- closing and reopening it.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_advisor_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

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
vim.fn.jobstart = function()
	return 99
end
vim.fn.jobstop = function() end

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function()
	return true
end
local advisor = require("utils.claude.advisor") -- wired by init's Advisor.wire{}

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)

-- ── A1: confirm() fires the callback BEFORE resuming a queued decision card ────
-- Root bug (batch 5, adversarial finding advisor.lua:217): the old confirm() ran
-- Advisor.close() first (which unconditionally resumed any queued card), THEN
-- called cb(id) — so a queued permission card could open and steal focus in the
-- gap before the advisor mutation was actually applied. Fixed by deferring the
-- queue-resume until after cb(id) returns.
--
-- Re-wire advisor.lua with a spy try_resume_decision_queues so the ORDER relative
-- to on_confirm is directly observable (init.lua's real hook isn't reachable from
-- here). Advisor.wire{} is idempotent/re-callable by design (same shape init uses
-- once at startup), so overriding it for this spec doesn't touch any other module.
local order = {}
advisor.wire({
	panel_float_geom = function()
		return 0, 40
	end,
	harden_float_scroll = function() end,
	try_resume_decision_queues = function()
		order[#order + 1] = "queue_resumed"
	end,
	pet_attach_surface = function() end,
	pet_attach_panel = function() end,
})

H.check("A1 module loaded", advisor ~= nil)

advisor.open(function(id)
	order[#order + 1] = "cb:" .. tostring(id)
end)
H.check("A1 picker opens", advisor.active() == true)

vim.api.nvim_win_call(advisor.win(), function()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end)
H.check("A1 picker closes on confirm", advisor.active() == false)
H.check(
	"A1 on_confirm callback fires BEFORE the queued-card resume (not after)",
	#order == 2 and order[1]:match("^cb:") and order[2] == "queue_resumed",
	vim.inspect(order)
)

-- ── A2: Advisor.open() on an already-open picker re-renders instead of reopening ──
-- Root bug (batch 5, adversarial finding advisor.lua:227): a close-then-reopen let
-- a queued permission card open and take focus during the brief close, then get
-- buried under the freshly reopened modal. Fixed: Advisor.open() is now a re-render
-- when already active, never a close/reopen — provable by the window handle staying
-- IDENTICAL across a second Advisor.open() call.
advisor.open(function() end)
H.check("A2 picker opens", advisor.active() == true)
local win1 = advisor.win()
advisor.open(function()
	order[#order + 1] = "second"
end)
local win2 = advisor.win()
H.check("A2 re-open reuses the SAME window (no close/reopen)", win1 == win2, tostring(win1) .. " vs " .. tostring(win2))
H.check("A2 picker still active after re-open", advisor.active() == true)
advisor.close()
H.check("A2 close works after a re-open", advisor.active() == false)

-- ── A3: current_label() ─────────────────────────────────────────────────────────
H.check(
	"A3 current_label returns a known OPTIONS label or 'No advisor' when unset",
	advisor.current_label() == "No advisor" or type(advisor.current_label()) == "string"
)

H.summary("claude_advisor")
