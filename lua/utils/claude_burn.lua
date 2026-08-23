-- lua/utils/claude_burn.lua
--
-- KOS Burn Bar reader — renders the account's 5-hour and 7-day rate-limit meters
-- as { text, highlight } chunk tuples for the Claude panel's chat-float footer
-- (nvim_open_win's `footer`, bottom border of the float — see M.chunks below).
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

-- Cache the parsed JSON keyed by the file's mtime+size so the winbar expr
-- (re-evaluated on every redraw) doesn't re-read + re-decode the file each
-- time. On a half-write (decode failure) we keep the last good value rather
-- than blanking the bar.
local cache = { key = nil, data = nil }

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
	-- mtime.sec alone collides on two writes inside the same wall-clock second
	-- and can be pinned by anything that rewrites the file while holding mtime
	-- constant (e.g. `touch -m -t`); size is cheap insurance against both.
	local cache_key = stat.mtime.sec .. ":" .. stat.size
	if cache.data and cache.key == cache_key then
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
	cache.key = cache_key
	cache.data = decoded
	return decoded
end

--- The model display name recorded in the state file (e.g. "Opus 4.8"), or "".
--- Used as a default for the modal statusline before the panel's own system/init
--- reports its model. It's the last interactive session's model, so only a hint.
--- Escaped for `%`: this string reaches a lualine function component, whose
--- return value is NOT passed through lualine's own `stl_escape` (that only
--- covers lualine's built-in components) — an unescaped `%{...}` here would be
--- interpreted as statusline syntax on every redraw.
function M.model()
	local decoded = read_state()
	if type(decoded) ~= "table" or type(decoded.model) ~= "table" or type(decoded.model.display_name) ~= "string" then
		return ""
	end
	return (decoded.model.display_name:gsub("%%", "%%%%"))
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
-- `resets_at` is an untrusted field from a `$HOME` JSON file (see header) — a
-- non-finite value (Inf/-Inf/NaN) passes `type() == "number"` and, unguarded,
-- produces a garbage wraparound string from %d's integer coercion (verified:
-- `math.huge` does NOT raise under this repo's LuaJIT, it silently wraps to
-- -9223372036854775808) rather than a crash — still misinformation, not just
-- a display nit, so bound it here rather than trust the caller.
local function countdown(resets_at)
	if type(resets_at) ~= "number" or not (resets_at < math.huge and resets_at > -math.huge) then
		return ""
	end
	local secs = resets_at - os.time()
	if secs <= 0 then
		return "now"
	end
	local days = math.floor(secs / 86400)
	local hours = math.floor((secs % 86400) / 3600)
	local mins = math.floor((secs % 3600) / 60)
	if days > 0 then
		return string.format("%dd%dh", days, hours)
	end
	if hours > 0 then
		return string.format("%dh%dm", hours, mins)
	end
	return string.format("%dm", mins)
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

-- A file resets_at already in the past means the window it describes has
-- rolled over — the file's used_percentage is from the PREVIOUS window and no
-- longer describes current usage. Wall-clock, not a live-vs-file comparison:
-- live[kind] only updates when THIS session's subprocess gets a fresh
-- rate_limit_event (i.e. after a message has been sent since rollover), so
-- right after a rollover `live` can still hold the pre-rollover resetsAt while
-- the file has ALREADY been refreshed by another session — a live/file
-- mismatch there means live is the stale one, not the file (live 2026-07-30:
-- this produced a false "?" on an already-fresh file). Comparing file_resets_at
-- against os.time() instead is direction-agnostic and catches both the
-- original bug (file stuck ~24h old, window long since rolled) and this one.
local function is_stale(file_resets_at)
	if type(file_resets_at) ~= "number" then
		return true
	end
	return file_resets_at <= os.time()
end

-- Append one meter to `out` as a list of { text, highlight } tuples — the form
-- nvim_open_win's `footer` accepts. Rendered on the chat float's bottom border
-- (directly under the input, above the statusline). `resets_at` is nil for the
-- context meter (a session fill level, not a resetting rate window). `show_bar`
-- false → just "<glyph> <label> NN%". `stale` → the file's pct predates the
-- current window (see is_stale); render "?" instead of a number that would read
-- as current but isn't. The countdown prefers the file's `resets_at` (it's
-- wall-clock-verified fresh whenever `stale` is false) and falls back to
-- `live_resets_at` only when stale or the file has none — `live` can itself
-- lag the file right after a rollover (see is_stale's comment), so it is NOT
-- unconditionally preferred. `show_reset` gates the live fallback too: when the
-- caller picked a leaner tier specifically to drop the countdown for width, the
-- live fallback must not silently reintroduce it (regression: a live-populated
-- five_hour window inflated the "bars, no countdown" tier past maxwidth, so
-- chunks() fell through to the no-bar tier — see claude_burn_spec.lua).
local function add_meter(out, glyph, label, pct, resets_at, show_bar, stale, live_resets_at, show_reset)
	-- vim.json.decode maps JSON null → vim.NIL (userdata, truthy), not Lua nil, so a
	-- bare `== nil` check leaks it through to severity()/math.floor and crashes on a
	-- number-vs-userdata compare. Reject anything that isn't a real, finite number —
	-- Inf/-Inf/NaN pass type()=="number" and bar_parts'/severity's math would produce
	-- garbage rather than a clean 0-100 clamp.
	if type(pct) ~= "number" or not (pct < math.huge and pct > -math.huge) then
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
	local reset_source
	if not stale and type(resets_at) == "number" then
		reset_source = resets_at
	elseif stale and show_reset then
		reset_source = (type(live_resets_at) == "number") and live_resets_at or resets_at
	end
	if type(reset_source) == "number" then
		out[#out + 1] = { " ↻" .. countdown(reset_source), "ClaudeBurnReset" }
	end
end

-- Build the three meters at a given detail level (bars? countdowns?).
local function build(rate_limits, context_window, show_bar, show_reset)
	local out = {}
	local function gap()
		if #out > 0 then
			out[#out + 1] = { "  ", "ClaudeBurnLabel" }
		end
	end
	-- Use type()==table, not truthiness: a JSON null sub-object decodes to vim.NIL
	-- (userdata, truthy) and indexing it (.used_percentage) would raise.
	if type(rate_limits.five_hour) == "table" then
		add_meter(
			out,
			GLYPH.five,
			"5h",
			rate_limits.five_hour.used_percentage,
			show_reset and rate_limits.five_hour.resets_at or nil,
			show_bar,
			is_stale(rate_limits.five_hour.resets_at),
			live.five_hour,
			show_reset
		)
	end
	-- Also gate on used_percentage being a real number here, not just
	-- rate_limits.seven_day being a table — otherwise gap() fires and add_meter()
	-- immediately no-ops on its own pct guard, leaving an orphan separator
	-- that inflates chunks_width with no visible content behind it.
	if type(rate_limits.seven_day) == "table" and type(rate_limits.seven_day.used_percentage) == "number" then
		gap()
		add_meter(
			out,
			GLYPH.seven,
			"7d",
			rate_limits.seven_day.used_percentage,
			show_reset and rate_limits.seven_day.resets_at or nil,
			show_bar,
			is_stale(rate_limits.seven_day.resets_at),
			live.seven_day,
			show_reset
		)
	end
	-- Context is always %-only (a hint, least critical) so it survives truncation.
	if type(context_window.used_percentage) == "number" then
		gap()
		add_meter(out, GLYPH.ctx, "ctx", context_window.used_percentage, nil, false)
	end
	return out
end

local function chunks_width(chunks)
	local width = 0
	for _, chunk in ipairs(chunks) do
		width = width + vim.fn.strdisplaywidth(chunk[1])
	end
	return width
end

--- Footer chunks for the chat bar, fitted to `maxwidth` (the float's inner width).
--- Picks the richest layout that fits: full (bars + countdowns) → bars only →
--- labels + % only. Guarantees the context % stays visible on a narrow panel
--- rather than being truncated to just its glyph. Returns nil when no data.
--- Note: the context % comes from whichever interactive CC session last wrote the
--- state file, not the panel's own subprocess — see the header.
function M.chunks(maxwidth)
	local decoded = read_state()
	if not decoded then
		return nil
	end
	-- Same vim.NIL trap as the per-field checks below: a JSON null decodes to
	-- truthy userdata, so `or {}` alone wouldn't fire.
	local rate_limits = (type(decoded.rate_limits) == "table") and decoded.rate_limits or {}
	local context_window = (type(decoded.context_window) == "table") and decoded.context_window or {}
	maxwidth = maxwidth or 999

	-- richest → leanest
	for _, lvl in ipairs({ { true, true }, { true, false }, { false, false } }) do
		local out = build(rate_limits, context_window, lvl[1], lvl[2])
		if #out == 0 then
			return nil
		end
		if chunks_width(out) <= maxwidth then
			return out
		end
	end
	-- Even the leanest overflows a tiny panel; return it (footer truncates ctx last).
	local out = build(rate_limits, context_window, false, false)
	return (#out > 0) and out or nil
end

return M
