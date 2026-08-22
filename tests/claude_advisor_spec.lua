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

-- ── A4: move() — Up/Down/j/k selection change + clamp at both ends (batch-5
-- testing finding: A1/A2 only ever drive the picker via <CR>, never feed a
-- movement key, so move()'s own logic had no direct coverage). No public getter
-- for modal.sel exists, so drive selection via the real keymaps and observe which
-- id lands via the on_confirm callback — the same public surface a real user
-- interaction goes through.
local function feed_key(lhs)
	vim.api.nvim_win_call(advisor.win(), function()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
	end)
end

-- Pin the starting selection explicitly rather than relying on core.lua's default
-- (advisor_model = "opus", OPTIONS[1]) — active_index() seeds modal.sel from this,
-- so an implicit default would make these assertions silently depend on ambient
-- state the spec never states.
claude.state.advisor_model = "opus"

local confirmed_id
advisor.open(function(id)
	confirmed_id = id
end)
feed_key("<CR>") -- no movement: proves the starting selection is really OPTIONS[1]
H.check(
	"A4 the picker opens preselecting state.advisor_model's option (opus)",
	confirmed_id == "opus",
	tostring(confirmed_id)
)

claude.state.advisor_model = "opus"
advisor.open(function(id)
	confirmed_id = id
end)
feed_key("<Down>")
feed_key("<Down>") -- opus -> sonnet -> fable
feed_key("<CR>")
H.check(
	"A4 <Down><Down> then confirm lands on the third option (fable)",
	confirmed_id == "fable",
	tostring(confirmed_id)
)

claude.state.advisor_model = "opus"
advisor.open(function(id)
	confirmed_id = id
end)
feed_key("<Up>") -- already at row 1 (opus): must clamp, not wrap
feed_key("<CR>")
H.check("A4 <Up> from the top row clamps instead of wrapping", confirmed_id == "opus", tostring(confirmed_id))

claude.state.advisor_model = "opus"
advisor.open(function(id)
	confirmed_id = id
end)
feed_key("j") -- j/k are the same move(±1) as Down/Up
feed_key("<CR>")
H.check("A4 'j' advances the selection like <Down>", confirmed_id == "sonnet", tostring(confirmed_id))

claude.state.advisor_model = "opus"
advisor.open(function(id)
	confirmed_id = id
end)
feed_key("j")
feed_key("k") -- back to the top
feed_key("<CR>")
H.check("A4 'k' reverses the selection like <Up>", confirmed_id == "opus", tostring(confirmed_id))

-- ── A5: the WinClosed fallback teardown (mirrors effort.lua's fallback for a float
-- closed by some path OTHER than Advisor.close(), e.g. `:q`) — batch-5 testing
-- finding: no prior spec closed the picker window directly, so this autocmd path
-- was unproven. Re-wire with a pet_attach_panel spy to prove Advisor.close()'s
-- side effects still ran even though this call never went through Advisor.close().
local panel_reattached = false
advisor.wire({
	panel_float_geom = function()
		return 0, 40
	end,
	harden_float_scroll = function() end,
	try_resume_decision_queues = function() end,
	pet_attach_surface = function() end,
	pet_attach_panel = function()
		panel_reattached = true
	end,
})
advisor.open(function() end)
H.check("A5 picker opens", advisor.active() == true)
local win_to_close = advisor.win()
panel_reattached = false
vim.api.nvim_win_close(win_to_close, true) -- bypass Advisor.close() entirely
H.check("A5 modal state clears when the window closes via a non-Advisor.close path", advisor.active() == false)
H.check("A5 the WinClosed fallback still ran Advisor.close()'s side effects", panel_reattached == true)

-- ── A6: the pcall(try_resume_decision_queues) failure branches — batch-5 testing
-- finding: neither spec ever made the injected hook throw, so the WARN-and-continue
-- path (both in Advisor.close and confirm) was unproven. A throwing hook must not
-- take the picker down with it — it should still close/confirm and just warn.
local warned = nil
local real_notify = vim.notify
vim.notify = function(msg, level)
	warned = { msg = msg, level = level }
end
advisor.wire({
	panel_float_geom = function()
		return 0, 40
	end,
	harden_float_scroll = function() end,
	try_resume_decision_queues = function()
		error("boom: queue hook exploded")
	end,
	pet_attach_surface = function() end,
	pet_attach_panel = function() end,
})
local confirm_cb_ran = false
advisor.open(function()
	confirm_cb_ran = true
end)
feed_key("<CR>")
vim.notify = real_notify
H.check("A6 confirm() still completes when the resume hook throws", advisor.active() == false)
H.check("A6 the on_confirm callback still fired despite the throwing hook", confirm_cb_ran == true)
H.check(
	"A6 the swallowed error is reported via vim.notify WARN, not silently dropped",
	warned ~= nil and warned.level == vim.log.levels.WARN,
	vim.inspect(warned)
)

H.summary("claude_advisor")
