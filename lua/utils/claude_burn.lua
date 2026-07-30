-- lua/utils/claude_burn.lua
--
-- KOS Burn Bar reader — renders the account's 5-hour and 7-day rate-limit meters
-- as a statusline-syntax string for the Claude panel's winbar.
--
-- Data source: ~/.claude/kos-burn-bar-state.json
--   Written every turn by the StatusLine-hook tap. The tap script is VENDORED in
--   this repo at scripts/neoclaude-token-tap.sh (install steps in its header) so
--   the plugin owns it rather than depending on a script that only lives in the
--   user's ~/.claude. See TODOS "self-contained burn bar" for the auto-install +
--   state-file rename cutover.
--   Claude Code's server-authoritative 5h/weekly usage
--   (rate_limits.{five_hour,seven_day}.used_percentage + resets_at) arrives ONLY
--   on the StatusLine hook's stdin and is never persisted by CC itself — the tap
--   captures that stdin to this file so we can read it. The numbers are
--   account-global (not per-session), so reading whatever the user's interactive
--   sessions last wrote is correct for the rate-limit meters. (The panel's own
--   `--print` subprocess does NOT fire the StatusLine hook, so cost/context in the
--   same file may be from another session — we only consume the rate limits here.)
--   Staleness: if no OTHER interactive CC session has run recently, the file can be
--   arbitrarily old while its window has already reset (live 2026-07-30: numbers
--   stuck ~24h). The panel's own subprocess DOES get rate_limit_event telemetry
--   every turn (unlike the StatusLine hook), so M.note_live feeds that in as an
--   account-authoritative resets_at to detect when the file's window has rolled
--   over — see is_stale/add_meter below.

local M = {}

local STATE = vim.fn.expand("~/.claude/kos-burn-bar-state.json")

-- Cache the parsed JSON keyed by the file's mtime so the winbar expr (re-evaluated
-- on every redraw) doesn't re-read + re-decode the file each time. On a half-write
-- (decode failure) we keep the last good value rather than blanking the bar.
local cache = { mtime = -1, data = nil }

-- Live rate_limit_event telemetry (render.lua's dispatch, one call per turn),
-- keyed by rateLimitType. Unlike the state file this is account-authoritative and
-- arrives on the panel's OWN subprocess, so it's the ground truth for whether the
-- file's used_percentage for that window is still current: if the file's resets_at
-- doesn't match the live resetsAt, the window has rolled over since the file was
-- last written and the file's percentage is stale (see M.note_live / M.chunks).
local live = { five_hour = nil, seven_day = nil }

--- Record the latest live resets_at for a rate-limit window, from render.lua's
--- rate_limit_event dispatch. `info` is the event's `rate_limit_info` table.
function M.note_live(info)
	if type(info) ~= "table" then
		return
	end
	local kind = info.rateLimitType
	if kind ~= "five_hour" and kind ~= "seven_day" then
		return
	end
	if type(info.resetsAt) == "number" then
		live[kind] = info.resetsAt
	end
end

local function read_state()
	local stat = vim.loop.fs_stat(STATE)
	if not stat then
		return nil
	end
	local mtime = stat.mtime.sec
	if cache.data and cache.mtime == mtime then
		return cache.data
	end
	local fd = io.open(STATE, "r")
	if not fd then
		return cache.data
	end
	local raw = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return cache.data
	end
	cache.mtime = mtime
	cache.data = decoded
	return decoded
end

--- True when the burn-bar state file exists (so callers can decide whether to
--- show the meters at all).
function M.available()
	return vim.loop.fs_stat(STATE) ~= nil
end

--- The model display name recorded in the state file (e.g. "Opus 4.8"), or "".
--- Used as a default for the modal statusline before the panel's own system/init
--- reports its model. It's the last interactive session's model, so only a hint.
function M.model()
	local d = read_state()
	return (d and d.model and d.model.display_name) or ""
end

-- Number of block segments in a meter bar.
local SEG = 8

-- Split a percentage into the filled-block run and the empty-track run, with a
-- half-block for the fractional segment (matches the Claude Code TUI's finer
-- granularity). Returns filled_str, track_str (each renderable on its own hl).
local function bar_parts(pct)
	pct = math.max(0, math.min(100, pct or 0))
	local units = pct / 100 * SEG
	local full = math.floor(units)
	local filled = string.rep("█", full)
	local used = full
	if (units - full) >= 0.5 and full < SEG then
		filled = filled .. "▌"
		used = used + 1
	end
	return filled, string.rep("░", SEG - used)
end

-- Humanise seconds-until-reset into a compact "2d3h" / "4h12m" / "9m" form.
local function countdown(resets_at)
	if type(resets_at) ~= "number" then
		return ""
	end
	local secs = resets_at - os.time()
	if secs <= 0 then
		return "now"
	end
	local d = math.floor(secs / 86400)
	local h = math.floor((secs % 86400) / 3600)
	local m = math.floor((secs % 3600) / 60)
	if d > 0 then
		return string.format("%dd%dh", d, h)
	end
	if h > 0 then
		return string.format("%dh%dm", h, m)
	end
	return string.format("%dm", m)
end

-- Severity highlight suffix by fill: green under 60%, amber 60–85, red above.
local function severity(pct)
	if pct >= 85 then
		return "Crit"
	end
	if pct >= 60 then
		return "Warn"
	end
	return "Ok"
end

-- Per-meter nerd-font glyph. 5h → clock, weekly → calendar, context → microchip
-- (memory/context). If a font lacks these they degrade to a missing-glyph box, so
-- the label text ("5h"/"7d"/"context") still reads.
-- Encoded as explicit UTF-8 bytes (LuaJIT has no \u{} escape, and the raw PUA
-- glyphs don't survive editing): U+F017 clock, U+F073 calendar, U+F2DB microchip.
local GLYPH = {
	five = "\239\128\151", -- U+F017 nf-fa-clock_o   (5-hour block)
	seven = "\239\129\179", -- U+F073 nf-fa-calendar  (weekly limit)
	ctx = "\239\139\155", -- U+F2DB nf-fa-microchip (context window ≈ memory)
}

-- A window's live resetsAt (from note_live) more than a minute off the file's
-- resets_at for the same window means the window has rolled over since the file
-- was last written — the file's used_percentage is from the PREVIOUS window and
-- no longer describes current usage. No live signal yet this session (nil) means
-- nothing contradicts the file, so it's trusted as-is.
local function is_stale(kind, file_resets_at)
	local live_resets_at = live[kind]
	if type(live_resets_at) ~= "number" then
		return false
	end
	if type(file_resets_at) ~= "number" then
		return true
	end
	return math.abs(live_resets_at - file_resets_at) > 60
end

-- Append one meter to `out` as a list of { text, highlight } tuples — the form
-- nvim_open_win's `footer` accepts. Rendered on the chat float's bottom border
-- (directly under the input, above the statusline). `resets_at` is nil for the
-- context meter (a session fill level, not a resetting rate window). `show_bar`
-- false → just "<glyph> <label> NN%". `stale` → the file's pct predates the
-- current window (see is_stale); render "?" instead of a number that would read
-- as current but isn't, and prefer `live_resets_at` for the countdown since it's
-- always current even when the file's percentage isn't.
local function add_meter(out, glyph, label, pct, resets_at, show_bar, stale, live_resets_at)
	-- vim.json.decode maps JSON null → vim.NIL (userdata, truthy), not Lua nil, so a
	-- bare `== nil` check leaks it through to severity()/math.floor and crashes on a
	-- number-vs-userdata compare. Reject anything that isn't a real number here.
	if type(pct) ~= "number" then
		return
	end
	local sev = stale and "ClaudeBurnStale" or ("ClaudeBurn" .. severity(pct))
	out[#out + 1] = { " " .. glyph .. " " .. label .. " ", "ClaudeBurnLabel" }
	if show_bar and not stale then
		local filled, track = bar_parts(pct)
		out[#out + 1] = { "▕", "ClaudeBurnTrack" }
		out[#out + 1] = { filled, sev }
		out[#out + 1] = { track .. "▏ ", "ClaudeBurnTrack" }
	end
	out[#out + 1] = { stale and "?" or (tostring(math.floor(pct + 0.5)) .. "%"), sev }
	local reset_source = (type(live_resets_at) == "number") and live_resets_at or resets_at
	if type(reset_source) == "number" then
		out[#out + 1] = { " ↻" .. countdown(reset_source), "ClaudeBurnReset" }
	end
end

-- Build the three meters at a given detail level (bars? countdowns?).
local function build(rl, cw, show_bar, show_reset)
	local out = {}
	local function gap()
		if #out > 0 then
			out[#out + 1] = { "  ", "ClaudeBurnLabel" }
		end
	end
	-- Use type()==table, not truthiness: a JSON null sub-object decodes to vim.NIL
	-- (userdata, truthy) and indexing it (.used_percentage) would raise.
	if type(rl.five_hour) == "table" then
		add_meter(
			out,
			GLYPH.five,
			"5h",
			rl.five_hour.used_percentage,
			show_reset and rl.five_hour.resets_at or nil,
			show_bar,
			is_stale("five_hour", rl.five_hour.resets_at),
			live.five_hour
		)
	end
	if type(rl.seven_day) == "table" then
		gap()
		add_meter(
			out,
			GLYPH.seven,
			"7d",
			rl.seven_day.used_percentage,
			show_reset and rl.seven_day.resets_at or nil,
			show_bar,
			is_stale("seven_day", rl.seven_day.resets_at),
			live.seven_day
		)
	end
	-- Context is always %-only (a hint, least critical) so it survives truncation.
	if type(cw.used_percentage) == "number" then
		gap()
		add_meter(out, GLYPH.ctx, "ctx", cw.used_percentage, nil, false)
	end
	return out
end

local function chunks_width(chunks)
	local w = 0
	for _, t in ipairs(chunks) do
		w = w + vim.fn.strdisplaywidth(t[1])
	end
	return w
end

--- Footer chunks for the chat bar, fitted to `maxwidth` (the float's inner width).
--- Picks the richest layout that fits: full (bars + countdowns) → bars only →
--- labels + % only. Guarantees the context % stays visible on a narrow panel
--- rather than being truncated to just its glyph. Returns nil when no data.
--- Note: the context % comes from whichever interactive CC session last wrote the
--- state file, not the panel's own subprocess — see the header.
function M.chunks(maxwidth)
	local d = read_state()
	if not d then
		return nil
	end
	local rl = d.rate_limits or {}
	local cw = d.context_window or {}
	maxwidth = maxwidth or 999

	-- richest → leanest
	for _, lvl in ipairs({ { true, true }, { true, false }, { false, false } }) do
		local out = build(rl, cw, lvl[1], lvl[2])
		if #out == 0 then
			return nil
		end
		if chunks_width(out) <= maxwidth then
			return out
		end
	end
	-- Even the leanest overflows a tiny panel; return it (footer truncates ctx last).
	local out = build(rl, cw, false, false)
	return (#out > 0) and out or nil
end

return M
