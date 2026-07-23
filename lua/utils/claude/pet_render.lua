-- lua/utils/claude/pet_render.lua
-- Clawd pet RENDERER — the only image/window code in the overlay (the pure state
-- machine lives in pet.lua). This is the "untestable" half the spec deliberately
-- isolates: it needs kitty graphics + a real terminal, so pet.lua stays headless
-- and drives this through the injected `pet.render(state, prev)` seam.
--
-- Mechanism (locked by the L1–L3 spikes, docs/clawd-overlay-spec.md § Rendering):
--   • Placement = image.nvim (kitty backend, magick_cli processor). It renders a
--     STATIC png in a floating window — it does NOT animate GIFs (takes frame [0]
--     only) — so WE animate by swapping pre-extracted png frames on a vim.loop
--     timer.
--   • Anti-flicker rule: render the NEXT frame BEFORE clearing the previous one
--     (image.nvim clear() wipes the transmit cache, so a clear-first swap flashes).
--     The opaque bar_bg carrier masks the residual retransmit gap. A placement-only
--     delete (Kitty d=p) was tried and REJECTED: live Ghostty accumulated static
--     placements (multiple frozen Clawds) even though the payload was valid.
--   • Z-order: kitty images composite ABOVE nvim text floats regardless of zindex
--     (spike Q2) — a card would bleed the pet on top of it. So the pet HIDES while
--   • Z-order: the pet owns a high-zindex float and re-anchors above whichever
--     bottom surface is active (chat, permission, question, or diff review).
-- state name): stdpath("cache")/kodex_clawd/<skin>/<asset>/000.png…015.png.
--
-- Everything degrades to a no-op when image.nvim, the assets, or a graphics
-- terminal are absent (spec § Licensing: a fresh clone without the fetch step must
-- still load). Nothing here is on the hot stream-json path — pet.lua pcall-guards
-- the render seam — but each image call is pcall'd anyway so a mid-animation throw
-- can never surface to the user.

local require_prefix = "utils.claude."
local pet = require(require_prefix .. "pet")

local M = {}

-- ── Pet state → GIF asset stem (spec § States → assets) ──────────────────────
-- The cache dir is named for the source GIF, not the resolved pet state, so this
-- map is the bridge between pet.lua's state names and the on-disk frame folders.
local STATE_ASSET = {
	sleep = "sleeping",
	idle = "idle",
	thinking = "thinking",
	typing = "typing",
	reading = "idle-reading",
	debugging = "debugger",
	cleaning = "sweeping",
	error = "error",
	subagent = "juggling",
	advising = "advising", -- advisor consult ("● Advising using <model>")
	hero = "hero", -- cool-pose flourish, idle→groove→hero→sleep
	building = "building", -- Edit/Write permission card (rare: usually a diff)
	notification = "notification", -- other permission / question modal
	diff_wait = "building", -- a pending edit/write diff review IS an Edit/Write
	-- → building sprite (the common Edit/Write path)
	diff_approved = "happy",
	happy = "happy",
	diff_rejected = "react-annoyed",
	headphones_groove = "headphones-groove",
}
M._STATE_ASSET = STATE_ASSET -- exposed for the headless map-completeness spec

-- ── Config (defaults from the L3 spike) ──────────────────────────────────────
local DEFAULT_SKIN = "clawd"
local DEFAULT_FPS = 10 -- plenty for an idle desk-pet; halves retransmit cost
-- Float footprint (columns × rows). This is a FIXED bounding box: the sprite is fitted
-- inside it and BOTTOM-RIGHT aligned (see frame_placement), so Clawd stands ON the
-- float's bottom edge — which is pinned to the statusline / chat bar / modal top — with
-- any leftover margin ABOVE him (invisible bar_bg over the panel), never below over the
-- bar. Fixed (not per-asset) so ensure_win can skip nvim_win_set_config on asset changes
-- — reconfiguring the float every state change forced a redraw that retransmitted the
-- kitty image = the transition flicker. Width halved per request (was 24); height is a
-- generous ceiling the tallest sprite fits within.
local DEFAULT_WIDTH = 12 -- pet float footprint, columns
local DEFAULT_HEIGHT = 8 -- pet float footprint, rows (bounding ceiling)
local IDLE_PUMP_MS = 1000 -- how often to tick the idle progression (pet.advance)
local FRAME_STEP = 1 -- use every Nth cached frame (cache is already thinned to 16)

-- Per-asset loop-tail (1-based frame index). Normally an asset loops 1→N→1. For
-- these, the intro plays ONCE and then it loops from the tail index instead of 1 —
-- so the pet holds a pose without replaying the intro every cycle. idle-reading:
-- frames 1–8 pull the book out; 9–16 are reading with the book in hand. Looping from
-- 9 keeps the book OUT (Clawd keeps reading) instead of wrapping to 1 where the book
-- is put away and re-drawn each loop (spec: hold the book until the read ends).
-- idle-reading: files 000–009 are the intro (glasses on, book pulled out and passed
-- across the face); the steady both-hands reading pose is files 010–015. Loop from
-- index 11 (file 010) so the hold is a calm read, not the pass-left-and-back motion.
-- sleeping: frames 1-6 are the one-shot collapse (standing → splooted), 7-16 are the
-- breathing+Zzz loop — loop from 7 so the collapse doesn't replay every cycle.
-- hero: one-shot 4.4s "put on glasses, cool pose" intro that freezes at its last
-- keyframe — loop from 16 (the last frame) so it holds the freeze pose instead of
-- replaying the intro.
local LOOP_FROM = { ["idle-reading"] = 11, ["sleeping"] = 7, ["hero"] = 16 }

-- States that must finish one full animation cycle before a LOW-priority follow-up
-- (the idle asset) may replace them. happy fires at turn end and the idle reset
-- lands within a tick — without the hold it reads as a one-frame flash. Urgent
-- states (typing/thinking/tools/cards) still interrupt immediately.
local HOLD_FULL_CYCLE = { ["happy"] = true }
-- Every source animation uses the accepted idle size: half-scale inside the fixed
-- no-flicker carrier. Per-asset overrides remain available for future art variants.
local DEFAULT_ASSET_SCALE = 0.5
-- Per-asset scale so every animation shows the SAME apparent body size (idle = the
-- reference). Every source GIF draws the same crab at the same pixel size; apparent
-- differences come ONLY from the fetch script's union-bbox crop zoom (each asset is
-- cropped to its own content box, then fit to 120px — a bigger box = smaller crab).
-- So the exact correction is scale = 0.5 * maxdim_asset / maxdim_idle, where maxdim
-- is the source union bbox's larger dimension (idle = 102). Values are then rounded
-- toward the nearest whole-ROW outcome (see the row snap in frame_placement) so the
-- quantized on-screen size stays closest to idle's 67px/102src ratio. happy (193)
-- ideally wants 6 rows but that needs >12 cols and would stretch — capped at 5.
local ASSET_SCALE = {
	["idle"] = 0.50, -- reference, src bbox 102
	["building"] = 0.75, -- 153
	["debugger"] = 0.70, -- 129
	["error"] = 0.70, -- 139
	["happy"] = 0.95, -- 193 (capped, see above)
	["headphones-groove"] = 0.85, -- 164
	["idle-reading"] = 0.55, -- 109
	["juggling"] = 0.70, -- 121
	["notification"] = 0.73, -- 149
	["react-annoyed"] = 0.73, -- 146
	["sleeping"] = 0.70, -- 134
	["sweeping"] = 0.70, -- 122
	["thinking"] = 0.70, -- 134
	["typing"] = 0.73, -- 149
}
M._ASSET_SCALE = ASSET_SCALE

-- ── Renderer state ───────────────────────────────────────────────────────────
local cfg = {
	skin = DEFAULT_SKIN,
	fps = DEFAULT_FPS,
	width = DEFAULT_WIDTH,
	height = DEFAULT_HEIGHT,
	enabled = true,
}
local image -- the image.nvim module, once loaded
local ready = false -- setup succeeded (image.nvim + a UI present)
local cache_root -- stdpath("cache")/kodex_clawd/<skin>

local pet_win, pet_buf
local patch_win, patch_buf -- 1-row border-repair float (see ensure_border_patch)
local last_geom -- last geometry applied to pet_win (skip redundant set_config)
local active_place -- {cols, rows} of the CURRENT asset's sprite (float footprint)

-- ── Render trace ─────────────────────────────────────────────────────────────
-- Always-on lightweight diagnostics: every placement decision appends one line to
-- <cache>/kodex_clawd/render-trace.log (truncated at setup). Kitty behaviour can't
-- be asserted headless, so this is the ground truth for live-position debugging:
-- reproduce the issue, read the log. Declared BEFORE any caller — a later local
-- would leave earlier closures reading the nil GLOBAL of the same name.
local trace_path
local function trace(fmt, ...)
	if not trace_path then
		return
	end
	local f = io.open(trace_path, "a")
	if not f then
		return
	end
	f:write(os.date("%H:%M:%S ") --[[@as string]], fmt:format(...), "\n")
	f:close()
end
local anchor = { mode = "panel", win = nil } -- where the float pins
local frames_cache = {} -- asset stem → { Image, … } (bound to the current pet_win)
local place_cache = {} -- asset stem → { cols, rows } sprite cell box (survives win recreate)
local current_asset -- asset whose frames the swap timer is cycling
local current_key -- frames_cache key for it (asset, or asset@pad on surfaces)
local shown_img -- the Image currently on screen (cleared on the next swap)
local frame_i = 1
local hold_cycle = false -- HOLD_FULL_CYCLE asset playing: defer idle until wrap
local pending_state -- state name deferred by hold_cycle (latest wins)
local swap_timer, idle_timer

-- ── image.nvim loading (lazy, graceful) ──────────────────────────────────────
-- Trigger lazy.nvim to put image.nvim on the runtimepath, then require + setup it.
-- Returns the module or nil; never throws.
local function load_image()
	pcall(function()
		require("lazy").load({ plugins = { "image.nvim" } })
	end)
	local ok, mod = pcall(require, "image")
	if not ok then
		return nil
	end
	local setup_ok = pcall(mod.setup, {
		backend = "kitty",
		processor = "magick_cli", -- uses `convert`; no magick luarock needed
		integrations = {}, -- bare — the pet needs no markdown/treesitter hooks
		-- MUST be 100, not nil: a nil value is an ABSENT key in Lua, so image.nvim's
		-- default max_height_window_percentage=50 survives and silently clamps any
		-- sprite taller than half the pet float (5 rows → 4), which also strands it
		-- one row above the float bottom (the y offset was computed for the un-clamped
		-- height). Trace-proven 2026-07-11: req 12x5 → rendered 9x4.
		max_width_window_percentage = 100,
		max_height_window_percentage = 100,
	})
	if not setup_ok then
		return nil
	end
	return mod
end

-- ── Geometry ─────────────────────────────────────────────────────────────────
-- Compute the pet float's editor-cell position for the current anchor. `panel`
-- pins bottom-right of the panel window (idle anchor); `chat` pins top-right of
-- the chat-bar float. Returns nil when the anchor window is gone — the pet is tied
-- to a real panel/chat window and must NOT float free without one (that's how a
-- raw `:q` on the panel would otherwise orphan a ghost pet).
-- Per-asset left-shift (cells) so every sprite's VISUAL right edge lines up with
-- happy's ~30px window-edge buffer (the reference position, user-picked 2026-07-11:
-- happy is the widest box and cannot move right without clipping, so it defines the
-- common column). Assets differ in transparent right margin INSIDE their canvas, so
-- a uniform pad would misalign them. pad = max(0, round((30px - gap_screen)/cw)).
local X_PAD = {
	["idle"] = 3,
	["building"] = 2,
	["debugger"] = 1,
	["error"] = 2,
	["happy"] = 0,
	["headphones-groove"] = 2,
	["idle-reading"] = 3,
	["juggling"] = 3,
	["notification"] = 3,
	["react-annoyed"] = 1,
	["sleeping"] = 3,
	["sweeping"] = 2,
	["thinking"] = 3,
	["typing"] = 3,
}

local function placed_geom(mode, wrow, wcol, ww, wh, pw, ph, pad, overlap)
	local col = wcol + ww - pw - (pad or 0)
	local row
	if mode == "surface" then
		-- A bordered float's win_get_position() row IS its border row (screenpos-proven:
		-- config row=10 → border at 10, content at 11).
		-- Raw frames (overlap=false): float bottom on wrow-1, one row above the border —
		-- feet flush at the row edge, half a cell above the mid-cell border glyph.
		-- Padded frames (overlap=true): the frame carries a half-cell transparent pad
		-- below the feet and the float extends ONE row onto the border row, so the feet
		-- land exactly at that row's mid-cell — ON the outline. This is NOT the rejected
		-- whole-row overlap: the transparent carrier + kitty z=-1 draw the border glyph
		-- OVER the sprite, so the outline can never be covered.
		row = wrow - ph + (overlap and 1 or 0)
	else
		-- The statusline begins immediately after the normal panel content.
		row = wrow + wh - ph
	end
	return { row = math.max(row, 0), col = math.max(col, 0), width = pw, height = ph }
end
M._placed_geom = placed_geom

local function anchor_geom()
	-- The float footprint IS the current sprite's cell box (not the cfg ceiling):
	-- the opaque carrier bg then covers only the sprite, instead of a 12x8 box
	-- blanking transcript text above/left of the pet.
	local pw = active_place and active_place.cols or cfg.width
	local ph = active_place and active_place.rows or cfg.height
	local win = anchor.win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return nil
	end
	local pos = vim.api.nvim_win_get_position(win)
	return placed_geom(
		anchor.mode,
		pos[1],
		pos[2],
		vim.api.nvim_win_get_width(win),
		vim.api.nvim_win_get_height(win),
		pw,
		ph,
		current_asset and X_PAD[current_asset] or 0,
		active_place and active_place.pad or false
	)
end

-- Transparent carrier (winblend=100): panel text shows through the float, and the
-- kitty image already rides display_zindex=-1 (hardcoded in image.nvim's kitty
-- backend), which Ghostty composites UNDER text glyphs but ABOVE cell backgrounds —
-- so the transcript renders over Clawd, like he's watching his own mirrored screen.
-- Tradeoff (accepted 2026-07-11): transparency re-exposes the per-swap retransmit
-- gap the old opaque ClaudeNormal carrier masked. The round-6 opaque-vs-transparent
-- A/B predates the set_config skip-guard + sprite-sized float, so the residual
-- flicker is expected to be far milder now — revert to opaque if live says otherwise.
local function apply_appearance(win)
	pcall(function()
		if vim.wo[win].winhighlight ~= "NormalFloat:ClaudeNormal" then
			vim.wo[win].winhighlight = "NormalFloat:ClaudeNormal"
		end
		if vim.wo[win].winblend ~= 100 then
			vim.wo[win].winblend = 100
		end
	end)
end

-- ── Border patch (surface anchors only) ──────────────────────────────────────
-- nvim's compositor ERASES the surface float's border glyphs under any
-- overlapping winblend float: it blends the pet carrier against the BASE window,
-- not the float beneath, so the pet float's bottom row (the border row) wipes the
-- outline even though both the carrier and the sprite pixels there are fully
-- transparent (probe-proven 2026-07-11: the covered band stayed glued to the
-- border row while the lifted sprite moved up). Repair: a 1-row OPAQUE float over
-- exactly that strip, redrawing the surface's own top-border char + highlight.
-- The kitty sprite composites above it with real alpha, so the redrawn line shows
-- through under the feet.
local patch_ns = vim.api.nvim_create_namespace("kodex_clawd_border_patch")

-- Top-border char + hl group + body bg group of the anchor surface. The char can
-- carry an hl in the border spec itself ({"c","Hl"}), but every panel surface
-- colors its border via winhighlight instead ("FloatBorder:ClaudePermBorder,…"),
-- so parse that map too — the stock FloatBorder fallback rendered the patch in
-- the wrong color (live 2026-07-11). Same map yields the surface's NormalFloat
-- group so the patch bg matches the bar/modal body exactly.
local function surface_border_spec()
	local chr, hl, bg = "─", "FloatBorder", "ClaudeNormal"
	local ok, wcfg = pcall(vim.api.nvim_win_get_config, anchor.win)
	if ok and type(wcfg.border) == "table" then
		local top = wcfg.border[2] -- spec order: topleft, top, topright, …
		if type(top) == "string" and top ~= "" then
			chr = top
		elseif type(top) == "table" and type(top[1]) == "string" and top[1] ~= "" then
			chr = top[1]
			if type(top[2]) == "string" then
				return chr, top[2], bg
			end -- spec hl wins
		end
	end
	local wh_ok, wh = pcall(function()
		return vim.wo[anchor.win].winhighlight
	end)
	if wh_ok and type(wh) == "string" then
		local border_map = wh:match("FloatBorder:([%w_.]+)")
		if border_map then
			hl = border_map
		end
		local bg_map = wh:match("NormalFloat:([%w_.]+)")
		if bg_map then
			bg = bg_map
		end
	end
	return chr, hl, bg
end

local function close_border_patch()
	if patch_win and vim.api.nvim_win_is_valid(patch_win) then
		pcall(vim.api.nvim_win_close, patch_win, true)
	end
	patch_win = nil
end

-- Keep the patch glued to the pet float's bottom row; close it whenever the pet
-- isn't standing on a border row (panel anchor, or raw-frame fallback).
local function ensure_border_patch(geom)
	if not (anchor.mode == "surface" and active_place and active_place.pad) then
		close_border_patch()
		return
	end
	local row = geom.row + geom.height - 1
	local chr, hl, bg = surface_border_spec()
	if not (patch_buf and vim.api.nvim_buf_is_valid(patch_buf)) then
		patch_buf = vim.api.nvim_create_buf(false, true)
	end
	local line = string.rep(chr, geom.width)
	pcall(vim.api.nvim_buf_set_lines, patch_buf, 0, -1, false, { line })
	vim.api.nvim_buf_clear_namespace(patch_buf, patch_ns, 0, -1)
	pcall(vim.api.nvim_buf_set_extmark, patch_buf, patch_ns, 0, 0, { end_col = #line, hl_group = hl })
	local cfg_tbl = {
		relative = "editor",
		row = row,
		col = geom.col,
		width = geom.width,
		height = 1,
	}
	if patch_win and vim.api.nvim_win_is_valid(patch_win) then
		pcall(vim.api.nvim_win_set_config, patch_win, cfg_tbl)
	else
		cfg_tbl.anchor = "NW"
		cfg_tbl.style = "minimal"
		cfg_tbl.border = "none"
		cfg_tbl.focusable = false
		-- One above the pet carrier so the patch wins its cells in the nvim grid; the
		-- kitty image is terminal-composited above ALL text anyway, so this cannot
		-- push the patch over the sprite. window_overlap_clear is off (image.nvim
		-- default), so the higher float does not make image.nvim hide the sprite.
		cfg_tbl.zindex = 251
		local ok, win = pcall(vim.api.nvim_open_win, patch_buf, false, cfg_tbl)
		if not ok then
			return
		end
		patch_win = win
	end
	-- OPAQUE on purpose — this float's whole job is to repaint glyphs the blend
	-- erased; bg mirrors the surface's own NormalFloat group so it reads as the
	-- border line, not a box.
	pcall(function()
		vim.wo[patch_win].winhighlight = "NormalFloat:" .. bg
		vim.wo[patch_win].winblend = 0
	end)
end

-- Create the pet float if absent/invalid, else move it to the current anchor.
-- Returns true if a usable window exists, false when there is no valid anchor.
local function ensure_win()
	local geom = anchor_geom()
	if not geom then
		return false
	end -- no panel/chat to pin to → no pet
	if pet_win and vim.api.nvim_win_is_valid(pet_win) then
		-- Only reconfigure when the geometry ACTUALLY changed (anchor switch / panel resize).
		-- ensure_win runs on every state change; a no-op set_config still forces a redraw
		-- that retransmits the kitty image = the per-transition flicker. Skip it when the
		-- float already sits where it should.
		if
			not (
				last_geom
				and last_geom.row == geom.row
				and last_geom.col == geom.col
				and last_geom.width == geom.width
				and last_geom.height == geom.height
			)
		then
			pcall(vim.api.nvim_win_set_config, pet_win, {
				relative = "editor",
				row = geom.row,
				col = geom.col,
				width = geom.width,
				height = geom.height,
			})
			last_geom = geom
			local ap = vim.api.nvim_win_get_position(anchor.win)
			trace(
				"move mode=%s float row=%d col=%d | anchor win=%d pos=%d,%d h=%d",
				anchor.mode,
				geom.row,
				geom.col,
				anchor.win,
				ap[1],
				ap[2],
				vim.api.nvim_win_get_height(anchor.win)
			)
		end
		apply_appearance(pet_win)
		ensure_border_patch(geom)
		return true
	end
	-- Recreating the window: the cached frame Images are bound to the OLD (now dead)
	-- window and would render nothing, so drop them to rebind against the new one.
	frames_cache = {}
	shown_img = nil
	if not (pet_buf and vim.api.nvim_buf_is_valid(pet_buf)) then
		pet_buf = vim.api.nvim_create_buf(false, true)
	end
	local ok, win = pcall(vim.api.nvim_open_win, pet_buf, false, {
		relative = "editor",
		anchor = "NW",
		row = geom.row,
		col = geom.col,
		width = geom.width,
		height = geom.height,
		-- High zindex so the pet floats ABOVE permission/question modals (user wants Clawd
		-- on top of them). image.nvim can hide an image whose window is covered by a
		-- higher-zindex float, so the pet must out-rank the cards (dressing/telescope modals
		-- sit ~50–200). The opaque bar_bg float still blends with the modal (same bar_bg).
		style = "minimal",
		border = "none",
		focusable = false,
		zindex = 250,
	})
	if not ok then
		return false
	end
	pet_win = win
	last_geom = geom -- baseline for the set_config skip-guard above
	apply_appearance(pet_win) -- transparent carrier (see apply_appearance)
	ensure_border_patch(geom)
	return true
end

-- ── Frame placement (bottom-right, so Clawd stands ON the surface) ────────────
-- Terminal cell pixel size, needed to know how many rows/cols a fitted sprite spans.
local function cell_size()
	local ok, term = pcall(require, "image.utils.term")
	if ok and term and term.get_size then
		local s = term.get_size()
		if s and (s.cell_width or 0) > 0 and (s.cell_height or 0) > 0 then
			return s.cell_width, s.cell_height
		end
	end
	return 8, 17 -- sane Ghostty-ish fallback
end

-- PNG pixel dimensions straight from the IHDR header (no subprocess): 8-byte signature,
-- 4-byte length, "IHDR", then big-endian 4-byte width + 4-byte height.
local function png_dims(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local hdr = f:read(24)
	f:close()
	if not hdr or #hdr < 24 then
		return nil
	end
	local function be(a)
		return hdr:byte(a) * 0x1000000 + hdr:byte(a + 1) * 0x10000 + hdr:byte(a + 2) * 0x100 + hdr:byte(a + 3)
	end
	return be(17), be(21)
end

-- Fit a (fw×fh px) sprite inside the cfg.width×cfg.height cell box preserving aspect,
-- then BOTTOM-RIGHT align it: return x,y (cell offset) + width,height (fitted cells).
-- Bottom-align puts the feet on the float's bottom edge (the surface); right-align keeps
-- him in the corner. Any slack ends up above/left of the sprite — invisible bar_bg.
local function frame_placement(asset, fw, fh, cell_w, cell_h)
	if not (fw and fh and fw > 0 and fh > 0) then
		return 0, 0, cfg.width, cfg.height
	end
	local cw, ch = cell_w, cell_h
	if not (cw and ch) then
		cw, ch = cell_size()
	end
	local scale = math.min((cfg.width * cw) / fw, (cfg.height * ch) / fh) * (ASSET_SCALE[asset] or DEFAULT_ASSET_SCALE)
	-- Snap the target height to a whole row count, then derive the EXACT scale from
	-- it. image.nvim top-aligns the fitted image inside its cell box, so a ceil'd row
	-- count leaves up to a cell of dead slack UNDER the feet (the "not flush" gap on
	-- statusline/modal borders). With the snapped scale the fitted height is exactly
	-- rows*ch (cols stays ceil'd, so height binds the aspect fit) → feet flush, and
	-- the size error vs the ASSET_SCALE target is at most half a cell.
	local rows = math.max(1, math.min(cfg.height, math.floor((fh * scale) / ch + 0.5)))
	local exact = rows * ch / fh
	local cols = math.max(1, math.min(cfg.width, math.ceil((fw * exact) / cw)))
	return cfg.width - cols, cfg.height - rows, cols, rows
end
M._frame_placement = frame_placement

-- ── Frames ───────────────────────────────────────────────────────────────────
-- Surface-mode feet-on-line variant: a sibling frame set with `p = fh/(2*rows)` px
-- of transparent padding added ABOVE and BELOW the sprite (gravity-center extent).
-- With the row-snap scale, that padding fits to exactly half a cell each side, so
-- rendering the padded set one row TALLER (rows+1, float overlapping the border
-- row) puts the feet at the border row's mid-cell — precisely on the outline glyph.
-- The math is terminal-independent: pad_screen = (fh/2rows) * (rows*ch/fh) = ch/2.
-- Width is untouched, so the prime-127 resize guarantee holds. Built lazily with
-- `convert` (already a hard dep of the frame cache), cached on disk, and rebuilt
-- whenever the raw frames are newer (a --force refetch invalidates it).
-- Feet lift above the outline glyph, in SCREEN pixels. Ghostty does not composite
-- kitty z=-1 images under text glyphs (live-proven 2026-07-11: feet exactly at
-- mid-cell COVER the border stroke), so the feet stop this far above the glyph's
-- mid-cell line instead — the stroke stays visible right under them, which reads
-- as standing ON the line. Tune by eye; bump if the stroke still clips.
-- 3 → 6 → 5 (2026-07-11): the 6px probe proved the covered outline band does NOT
-- move with the sprite — nvim's compositor erases the surface float's border glyphs
-- under any overlapping winblend float (it blends against the base window, not the
-- float beneath), so the border patch float below redraws them. 5 → 4: one more
-- px down per user's eye, flush to the redrawn line.
local FEET_LIFT_PX = 2

local function ensure_padded(asset, prows, fw, fh)
	local raw_dir = cache_root .. "/" .. asset
	local p = math.floor(fh / (2 * prows) + 0.5)
	local _, ch = cell_size()
	-- Source-px lift that lands as FEET_LIFT_PX on screen, via the padded fit scale
	-- exact = (prows+1)*ch / (fh+2p).
	local lift = math.floor(FEET_LIFT_PX * (fh + 2 * p) / ((prows + 1) * ch) + 0.5)
	local out = ("%s@pad%d-%d"):format(raw_dir, prows, lift)
	local raw0, out0 = raw_dir .. "/000.png", out .. "/000.png"
	if vim.fn.filereadable(out0) == 1 and vim.fn.getftime(out0) >= vim.fn.getftime(raw0) then
		return out
	end
	-- Equal pad top+bottom centers the sprite (feet at the fitted mid-cell); the roll
	-- then shifts it UP by the lift. lift < p, so nothing wraps around the canvas.
	-- Build into a staging dir and swap it in back-to-back (fetch-script pattern):
	-- another live nvim instance may hold Image objects into the old dir, and an
	-- up-front rm would feed its render ticks "No such file" for the whole convert.
	local staging = out .. ".staging"
	local cmd = (
		"rm -rf %q && mkdir -p %q && for f in %q/*.png; do "
		.. 'convert "$f" -background none -gravity center -extent %dx%d '
		.. '-roll +0-%d %q/"$(basename "$f")" || exit 1; done '
		.. "&& rm -rf %q && mv %q %q"
	):format(staging, staging, raw_dir, fw, fh + 2 * p, lift, staging, out, staging, out)
	vim.fn.system({ "bash", "-c", cmd })
	if vim.fn.filereadable(out0) == 1 then
		return out
	end
	trace("padded %s FAILED (convert missing?) — falling back to raw frames", asset)
	return nil
end

-- Lazy-load + cache the Image objects for an asset, bound to the current pet_win.
-- Bound-to-window is why the cache is invalidated on teardown (a stale window
-- reference would render nothing). Surface anchors get the padded feet-on-line
-- variant (cache key `asset@pad`), panel anchors the raw set — the two coexist in
-- frames_cache/place_cache so chat open/close never rebuilds either.
-- Returns the frame array (possibly empty) plus its cache key.
local function ensure_frames(asset)
	local padded = anchor.mode == "surface"
	local key = padded and (asset .. "@pad") or asset
	local existing = frames_cache[key]
	if existing then
		return existing, key
	end
	local frames = {}
	local raw_dir = cache_root .. "/" .. asset
	if vim.fn.isdirectory(raw_dir) == 1 then
		local files = vim.fn.readdir(raw_dir)
		table.sort(files)
		-- All frames of an asset share one crop box, so compute placement once from the
		-- first RAW frame and reuse it — every frame lands in the same spot (no jitter).
		-- The padded variant derives from the same numbers: same scale (the pad grows
		-- source and target height by the same factor), one extra row.
		local fw, fh = png_dims(raw_dir .. "/" .. (files[1] or ""))
		local _, _, pcols, prows = frame_placement(asset, fw, fh)
		local dir, rows_used, pad = raw_dir, prows, false
		if padded and fw and fh then
			local pdir = ensure_padded(asset, prows, fw, fh)
			if pdir then
				dir, rows_used, pad = pdir, prows + 1, true
			end
		end
		local tcw, tch = cell_size()
		trace(
			"frames %s: png=%sx%s cols=%d rows=%d pad=%s cell=%.1fx%.2f scale=%.2f",
			key,
			tostring(fw),
			tostring(fh),
			pcols,
			rows_used,
			tostring(pad),
			tcw,
			tch,
			ASSET_SCALE[asset] or DEFAULT_ASSET_SCALE
		)
		-- The float is resized to exactly pcols x rows_used for this asset (see
		-- place_cache/anchor_geom), so the sprite fills the window from its top-left.
		for i = 1, #files, FRAME_STEP do
			local ok, img = pcall(image.from_file, dir .. "/" .. files[i], {
				window = pet_win,
				x = 0,
				y = 0,
				width = pcols,
				height = rows_used,
			})
			if ok and img then
				frames[#frames + 1] = img
			end
		end
		place_cache[key] = { cols = pcols, rows = rows_used, pad = pad }
	end
	frames_cache[key] = frames
	return frames, key
end

-- ── Scroll-storm write hold ──────────────────────────────────────────────────
-- Kitty escapes go out on image.nvim's OWN libuv tty handle (backends/kitty/
-- helpers.lua), uncoordinated with nvim's TUI thread writing the same fd. Under
-- scroll-storm redraw pressure the TUI flush goes out in partial writes, and an
-- APC landing mid-CSI corrupts the terminal state — the CSI dies, its tail
-- (";97H") prints literally, and leaked SGR bg bands paint into the neighbour
-- window (PTY A/B-proven: APC writer on = interrupted CSIs, off = clean). The
-- race is unfixable from plugin land (no TUI flush lock), but it only bites when
-- both writers overlap — so the panel's scroll sites arm a rolling hold and
-- swap_to skips its writes while it runs. The shown frame simply persists (no
-- clear happens), and the ≤100 ms swap tick repaints once the hold expires.
local SCROLL_HOLD_MS = 250
local write_hold_until = 0
local function hold_writes(now_ms)
	write_hold_until = (now_ms or vim.loop.now()) + SCROLL_HOLD_MS
end
local function writes_held(now_ms)
	return (now_ms or vim.loop.now()) < write_hold_until
end
M.hold_writes = hold_writes -- called from init's panel scroll sites
M._writes_held = writes_held -- test seam (injectable clock)

-- Render the next frame BEFORE clearing the previous one (anti-flicker order).
local last_traced_asset
local function swap_to(img)
	if not img or img == shown_img then
		return
	end
	if writes_held() then
		return
	end -- scroll storm: skip the kitty write this tick
	pcall(function()
		img:render()
	end)
	if shown_img then
		pcall(function()
			shown_img:clear(true)
		end)
	end
	shown_img = img
	-- Trace once per asset switch (not per frame): the ACTUAL rendered geometry the
	-- backend used — the decisive number when cells and screen disagree.
	if current_asset ~= last_traced_asset then
		last_traced_asset = current_asset
		local rg = img.rendered_geometry or {}
		local g = img.geometry or {}
		trace(
			"render %s: req x=%s y=%s w=%s h=%s | rendered x=%s y=%s w=%s h=%s",
			tostring(current_asset),
			tostring(g.x),
			tostring(g.y),
			tostring(g.width),
			tostring(g.height),
			tostring(rg.x),
			tostring(rg.y),
			tostring(rg.width),
			tostring(rg.height)
		)
	end
end
local function clear_shown()
	if shown_img then
		pcall(function()
			shown_img:clear(true)
		end)
	end
	shown_img = nil
end

-- ── Timers ───────────────────────────────────────────────────────────────────
-- One animation tick: validate the anchor, then advance one frame.
local function on_swap_tick()
	if not (ready and pet_win and vim.api.nvim_win_is_valid(pet_win)) then
		return
	end

	-- The pet float is editor-relative, so a raw `:q` on the panel leaves pet_win
	-- valid (it survives its anchor). Validate the ANCHOR here too — if the panel/chat
	-- it pins to is gone, no state change may ever come to trip render_state's
	-- lost-anchor path, so the orphan would animate forever. Full teardown closes the
	-- float + stops the timers within one tick (≤100 ms).
	if not (anchor.win and vim.api.nvim_win_is_valid(anchor.win)) then
		M.teardown()
		return
	end

	-- Follow live chat/modal height changes; unchanged geometry is a no-op.
	if not ensure_win() then
		M.teardown()
		return
	end

	local frames = current_key and frames_cache[current_key]
	if not frames or #frames == 0 then
		return
	end
	-- Advance one frame, wrapping to the asset's loop-tail (default 1) at the end so
	-- intro-then-hold assets (idle-reading) don't replay their intro every cycle.
	local nxt
	if frame_i >= #frames then
		-- Full cycle done: release the hold and apply the state it deferred (if any).
		if hold_cycle then
			hold_cycle = false
			local deferred = pending_state
			pending_state = nil
			if deferred then
				M.render_state(deferred)
				return
			end
		end
		nxt = math.min(LOOP_FROM[current_asset] or 1, #frames)
	else
		nxt = frame_i + 1
	end
	if nxt == frame_i then -- single-frame state: just ensure it's up
		swap_to(frames[frame_i])
		return
	end
	frame_i = nxt
	swap_to(frames[frame_i])
end

-- Idle-progression pump: drive pet.advance on a real clock so idle → groove →
-- idle → sleep walks forward. Uses the SAME clock source as pet.M.now so elapsed
-- math is consistent. pet.advance is a cheap no-op when not idling.
local function on_idle_tick()
	pcall(pet.advance, vim.loop.now() / 1000)
end

local function start_timers()
	if not swap_timer then
		swap_timer = vim.loop.new_timer()
		local interval = math.max(math.floor(1000 / cfg.fps), 30)
		swap_timer:start(interval, interval, vim.schedule_wrap(on_swap_tick))
	end
	if not idle_timer then
		idle_timer = vim.loop.new_timer()
		idle_timer:start(IDLE_PUMP_MS, IDLE_PUMP_MS, vim.schedule_wrap(on_idle_tick))
	end
end

local function stop_timer(timer)
	if timer then
		pcall(function()
			timer:stop()
		end)
		pcall(function()
			timer:close()
		end)
	end
	return nil
end

-- ── Public API (the pet.render seam + init lifecycle hooks) ───────────────────

-- The injected renderer seam. pet.lua calls this on every real state change.
-- Maps the pet state to its asset, paints frame 1 render-before-clear, and keeps
-- the swap timer cycling. A no-op while disabled or asset-less.
function M.render_state(name, _prev)
	if not (ready and cfg.enabled) then
		return
	end
	local asset = STATE_ASSET[name]
	if not asset then
		return
	end

	-- A holding asset finishes its cycle before yielding to the idle asset; anything
	-- more urgent (typing/thinking/tools/cards) interrupts and cancels the hold.
	if hold_cycle and asset ~= current_asset then
		if asset == "idle" then
			pending_state = name
			return
		end
		hold_cycle = false
		pending_state = nil
	end
	if HOLD_FULL_CYCLE[asset] and asset ~= current_asset then
		hold_cycle = true
		pending_state = nil
	end
	if not ensure_win() then
		-- No anchor window (panel closed, possibly via a raw `:q` that skipped
		-- teardown). Full teardown — stopping the timers alone would leave shown_img
		-- rendered and pet_win open, i.e. a frozen ghost frame. teardown clears the
		-- image + closes the float too, and the idle pump can't resurrect it.
		M.teardown()
		return
	end

	local frames, key = ensure_frames(asset)
	current_asset = asset
	current_key = key
	frame_i = 1
	if #frames == 0 then
		clear_shown()
		return
	end -- assets missing: show nothing

	-- Resize the float to THIS asset's sprite box (ensure_win above ran with the
	-- previous asset's footprint — it had to exist before ensure_frames could bind
	-- Images to it). Cheap: ensure_win no-ops when the geometry didn't change.
	active_place = place_cache[key]
	ensure_win()

	swap_to(frames[1])
	start_timers()
end

-- Pin the pet bottom-right of the Claude panel (idle/working anchor). Called when
-- the panel opens and when the chat bar closes.
function M.attach_to_panel(win)
	local mode_changed = anchor.mode ~= "panel"
	anchor = { mode = "panel", win = win }
	if not (ready and cfg.enabled) then
		return
	end
	if not ensure_win() then
		return
	end
	if mode_changed and current_asset then
		-- The two anchor modes use DIFFERENT frame variants (raw vs padded feet-on-line),
		-- so a repaint of shown_img would show the wrong one. Re-drive render_state: it
		-- picks the mode's variant from cache (or builds it) and resizes the float.
		M.render_state(pet.state)
	elseif shown_img then
		pcall(function()
			shown_img:render()
		end) -- repaint current frame at the new pos
	elseif current_asset then
		-- ensure_win recreated the float (old one externally killed) → cache + shown_img
		-- were wiped, so there's nothing to repaint. Re-drive render_state to rebuild the
		-- frames against the new window; without it the pet stays blank until the next
		-- real state change (which this attach path can't count on).
		M.render_state(pet.state)
	end
end

-- Pin the pet top-right of a bordered bottom surface: chat bar or modal.
function M.attach_to_surface(win)
	local mode_changed = anchor.mode ~= "surface"
	anchor = { mode = "surface", win = win }
	if not (ready and cfg.enabled) then
		return
	end
	if not ensure_win() then
		return
	end
	if mode_changed and current_asset then
		-- See attach_to_panel: mode switch = frame-variant switch, so re-drive.
		M.render_state(pet.state)
	elseif shown_img then
		pcall(function()
			shown_img:render()
		end)
	elseif current_asset then
		-- Rebuild frames against a recreated float instead of leaving the pet blank
		-- until the next state change.
		M.render_state(pet.state)
	end
end

-- Backward-compatible name for the original chat-only call site.
M.attach_to_chat = M.attach_to_surface

-- Live diagnostic seam for terminal-only placement issues.
function M.debug_geometry()
	local cw, ch = cell_size()
	return {
		asset = current_asset,
		anchor_mode = anchor.mode,
		anchor_geom = anchor_geom(),
		cell = { width = cw, height = ch },
		cfg = vim.deepcopy(cfg),
		image_geometry = shown_img and vim.deepcopy(shown_img.geometry) or nil,
		rendered_geometry = shown_img and vim.deepcopy(shown_img.rendered_geometry) or nil,
		-- Raw anchor-window metrics: enough to hand-check placed_geom against what is
		-- actually on screen (SW-anchored bordered floats are the suspect case).
		anchor_win = (function()
			local w = anchor.win
			if not (w and vim.api.nvim_win_is_valid(w)) then
				return nil
			end
			local p = vim.api.nvim_win_get_position(w)
			local c = vim.api.nvim_win_get_config(w)
			return {
				win = w,
				pos_row = p[1],
				pos_col = p[2],
				width = vim.api.nvim_win_get_width(w),
				height = vim.api.nvim_win_get_height(w),
				cfg_anchor = c.anchor,
				cfg_row = c.row,
				cfg_col = c.col,
				border = c.border and true or false,
			}
		end)(),
		pet_win_cfg = (pet_win and vim.api.nvim_win_is_valid(pet_win)) and vim.api.nvim_win_get_config(pet_win) or nil,
	}
end

-- Tear everything down: stop timers, delete the kitty image, drop the frame cache
-- (its Image objects are bound to the window we're closing), close the float.
-- Called on panel close / session reset so no artifact survives.
function M.teardown()
	swap_timer = stop_timer(swap_timer)
	idle_timer = stop_timer(idle_timer)
	clear_shown()
	for _, frames in pairs(frames_cache) do
		for _, img in ipairs(frames) do
			pcall(function()
				img:clear(true)
			end)
		end
	end
	frames_cache = {}
	current_asset = nil
	current_key = nil
	frame_i = 1
	hold_cycle = false
	pending_state = nil
	if pet_win and vim.api.nvim_win_is_valid(pet_win) then
		pcall(vim.api.nvim_win_close, pet_win, true)
	end
	pet_win = nil
	close_border_patch()
	last_geom = nil -- window gone → next ensure_win recreates + rebaselines
end

-- Wire the renderer into the pure state machine and prime image.nvim. `opts`:
--   { skin, fps, width, height, enabled }.
-- (A `gated` hide predicate existed until 2026-07-11 — removed as dead code once
-- the slash menu went above the carrier by zindex instead of hiding the pet.)
-- Idempotent-ish: safe to call once at plugin setup. When image.nvim or a UI is
-- absent, leaves pet.render as the pure no-op stub so the pet stays headless-safe.
function M.setup(opts)
	opts = opts or {}
	cfg.skin = opts.skin or cfg.skin
	cfg.fps = opts.fps or cfg.fps
	cfg.width = opts.width or cfg.width
	cfg.height = opts.height or cfg.height
	if opts.enabled ~= nil then
		cfg.enabled = opts.enabled
	end
	cache_root = vim.fn.stdpath("cache") .. "/kodex_clawd/" .. cfg.skin

	-- Never render in a headless/embedded session (no graphics terminal).
	if not cfg.enabled or #vim.api.nvim_list_uis() == 0 then
		ready = false
		return false
	end

	image = load_image()
	if not image then
		ready = false
		return false
	end
	ready = true

	-- Fresh trace per session: truncate, then log the live cell metrics once.
	trace_path = vim.fn.stdpath("cache") .. "/kodex_clawd/render-trace.log"
	local tf = io.open(trace_path, "w")
	if tf then
		tf:close()
	end
	local cw, ch = cell_size()
	trace("setup: cell=%.1fx%.2f cfg=%dx%d skin=%s", cw, ch, cfg.width, cfg.height, cfg.skin)

	-- Route pet state changes to the renderer. pet.lua pcall-guards this call, and
	-- render_state pcall-guards each image op, so a render throw can't reach dispatch.
	pet.render = function(name, prev)
		M.render_state(name, prev)
	end
	return true
end

return M
