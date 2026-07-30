-- tests/claude_burn_spec.lua
-- Regression coverage for the burn-bar reader's handling of JSON null.
-- vim.json.decode maps JSON `null` → vim.NIL (userdata, truthy), NOT Lua nil.
-- A bare `== nil` / truthiness guard leaks vim.NIL into severity()/countdown()
-- and crashes on a number-vs-userdata compare ("attempt to compare number with
-- userdata"). This spec feeds the module null-laden state and asserts no crash.

local H = dofile("tests/helpers.lua")

-- Point the module at a throwaway state file BEFORE requiring it (STATE is
-- captured at load time from vim.fn.expand).
local STATE = vim.fn.tempname() .. "-burn.json"
local real_expand = vim.fn.expand
vim.fn.expand = function(arg, ...)
	if type(arg) == "string" and arg:find("kos%-burn%-bar%-state") then
		return STATE
	end
	return real_expand(arg, ...)
end

package.loaded["utils.claude_burn"] = nil
local burn = require("utils.claude_burn")

-- Re-require on each write so the module's mtime-keyed cache (1-second
-- granularity) can't serve a prior case's data when two writes share a second.
local function write_state(json)
	vim.fn.writefile({ json }, STATE)
	package.loaded["utils.claude_burn"] = nil
	burn = require("utils.claude_burn")
end

-- 1. Every percentage / sub-object is JSON null. Previously crashed; now no
--    meter should render (nothing has a real number), so chunks() returns nil.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":null},"seven_day":null},"context_window":{"used_percentage":null}}]]
)
local ok, res = pcall(burn.chunks, 80)
H.check("all-null state does not crash", ok, not ok and res)
H.check("all-null state yields no meters", ok and res == nil, res)

-- 2. Mixed: one real meter, the rest null. The real one renders; null ones are
--    silently skipped (not crashed on).
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":null},"seven_day":null},"context_window":{"used_percentage":null}}]]
)
local ok2, res2 = pcall(burn.chunks, 80)
H.check("mixed state does not crash", ok2, not ok2 and res2)
H.check("mixed state renders the real meter", ok2 and type(res2) == "table" and #res2 > 0, res2)
-- 92% is over the 85 Crit threshold — confirms the number actually reached severity().
local has_crit = false
if ok2 and type(res2) == "table" then
	for _, chunk in ipairs(res2) do
		if chunk[2] == "ClaudeBurnCrit" then
			has_crit = true
		end
	end
end
H.check("92% meter tagged Crit", has_crit, res2)

-- 3. Live rate_limit_event telemetry (note_live) disagrees with the file's
--    resets_at for the same window → the window rolled over since the file was
--    last written, so the file's used_percentage is stale. Renders "?" tagged
--    ClaudeBurnStale instead of the misleadingly-precise "92%"/Crit.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":1000},"seven_day":null},"context_window":{"used_percentage":null}}]]
)
burn.note_live({ rateLimitType = "five_hour", resetsAt = 5000 })
local ok3, res3 = pcall(burn.chunks, 80)
H.check("stale window does not crash", ok3, not ok3 and res3)
local has_stale, has_crit3, has_question = false, false, false
if ok3 and type(res3) == "table" then
	for _, chunk in ipairs(res3) do
		if chunk[2] == "ClaudeBurnStale" then
			has_stale = true
		end
		if chunk[2] == "ClaudeBurnCrit" then
			has_crit3 = true
		end
		if chunk[1] == "?" then
			has_question = true
		end
	end
end
H.check("stale window tagged ClaudeBurnStale, not Crit", has_stale and not has_crit3, res3)
H.check("stale window renders '?' not the stale percentage", has_question, res3)

-- 4. Live resetsAt agrees with the file's (same window, well within tolerance) →
--    not stale, the real percentage still renders.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":1000},"seven_day":null},"context_window":{"used_percentage":null}}]]
)
burn.note_live({ rateLimitType = "five_hour", resetsAt = 1000 })
local ok4, res4 = pcall(burn.chunks, 80)
local has_crit4 = false
if ok4 and type(res4) == "table" then
	for _, chunk in ipairs(res4) do
		if chunk[2] == "ClaudeBurnCrit" then
			has_crit4 = true
		end
	end
end
H.check("agreeing live resetsAt keeps the real percentage (Crit)", has_crit4, res4)

vim.fn.delete(STATE)
H.summary("claude_burn")
