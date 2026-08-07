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
--    silently skipped (not crashed on). resets_at is a real future timestamp
--    (not null) so this case isn't ALSO exercising staleness (see cases 3/4) —
--    an unknown/null resets_at can't be verified fresh and is its own case.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":9999999999},"seven_day":null},"context_window":{"used_percentage":null}}]]
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

-- 3. The file's resets_at is already in the past (wall-clock, not a live-vs-
--    file comparison — see claude_burn.lua's is_stale comment for why: a live
--    resetsAt lagging the file right after a rollover would otherwise read as
--    "file is stale" when the file is actually the fresh one, live 2026-07-30
--    false-"?" bug). A past resets_at means the window it describes has
--    rolled over, so the file's used_percentage is stale. Renders "?" tagged
--    ClaudeBurnStale instead of the misleadingly-precise "92%"/Crit. note_live
--    is deliberately NOT called here — staleness no longer depends on it.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":1000},"seven_day":null},"context_window":{"used_percentage":null}}]]
)
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

-- 4. The file's resets_at is in the future (window still active) → not stale,
--    the real percentage still renders, REGARDLESS of what a stale live cache
--    says — this is the exact false-"?" regression case: live still holds an
--    old (already-past) resetsAt from before a rollover this session hasn't
--    sent a message since, while the file has already been refreshed for the
--    new window. The file's own future resets_at must win.
write_state(
	[[{"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":9999999999},"seven_day":null},"context_window":{"used_percentage":null}}]]
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
H.check("future file resets_at keeps the real percentage even with a stale live cache", has_crit4, res4)

-- 5. Regression: a live rate_limit_event for five_hour must not leak a countdown
--    into a tier that was picked specifically to drop countdowns for width (the
--    2026-08-06 bug — live.five_hour populated inflated the "bars, no countdown"
--    tier past maxwidth, so chunks() fell through to the no-bar tier and the
--    burn bar vanished even though the richer "bars, no countdown" tier would
--    have fit). Three real meters (5h/7d/ctx, matching the reported repro) at a
--    maxwidth that fits the bar-only tier but not the bar+countdown tier: the
--    bar tier must render bars AND must not carry a "↻" chunk.
write_state(
	string.format(
		[[{"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":%d},"seven_day":{"used_percentage":23,"resets_at":%d}},"context_window":{"used_percentage":17}}]],
		os.time() + 13740,
		os.time() + 165600
	)
)
burn.note_live({ rateLimitType = "five_hour", resetsAt = os.time() + 13740 })
local ok5, res5 = pcall(burn.chunks, 61)
H.check("live five_hour telemetry does not crash the width fit", ok5, not ok5 and res5)
local has_bar, has_countdown = false, false
if ok5 and type(res5) == "table" then
	for _, chunk in ipairs(res5) do
		if chunk[1]:find("▕") then
			has_bar = true
		end
		if chunk[1]:find("↻") then
			has_countdown = true
		end
	end
end
H.check("bar-only tier still shows bars at maxwidth=61", has_bar, res5)
H.check("bar-only tier drops the countdown instead of falling back to no-bar", not has_countdown, res5)

vim.fn.delete(STATE)
H.summary("claude_burn")
