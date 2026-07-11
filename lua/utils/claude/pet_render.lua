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
  sleep             = "sleeping",
  idle              = "idle",
  thinking          = "thinking",
  typing            = "typing",
  reading           = "idle-reading",
  debugging         = "debugger",
  cleaning          = "sweeping",
  error             = "error",
  subagent          = "juggling",
  building          = "building",       -- Edit/Write permission card (rare: usually a diff)
  notification      = "notification",   -- other permission / question modal
  diff_wait         = "building",       -- a pending edit/write diff review IS an Edit/Write
                                        -- → building sprite (the common Edit/Write path)
  diff_approved     = "happy",
  happy             = "happy",
  diff_rejected     = "react-annoyed",
  headphones_groove = "headphones-groove",
}
M._STATE_ASSET = STATE_ASSET  -- exposed for the headless map-completeness spec

-- ── Config (defaults from the L3 spike) ──────────────────────────────────────
local DEFAULT_SKIN   = "clawd"
local DEFAULT_FPS    = 10     -- plenty for an idle desk-pet; halves retransmit cost
-- Float footprint (columns × rows). This is a FIXED bounding box: the sprite is fitted
-- inside it and BOTTOM-RIGHT aligned (see frame_placement), so Clawd stands ON the
-- float's bottom edge — which is pinned to the statusline / chat bar / modal top — with
-- any leftover margin ABOVE him (invisible bar_bg over the panel), never below over the
-- bar. Fixed (not per-asset) so ensure_win can skip nvim_win_set_config on asset changes
-- — reconfiguring the float every state change forced a redraw that retransmitted the
-- kitty image = the transition flicker. Width halved per request (was 24); height is a
-- generous ceiling the tallest sprite fits within.
local DEFAULT_WIDTH  = 12     -- pet float footprint, columns
local DEFAULT_HEIGHT = 8      -- pet float footprint, rows (bounding ceiling)
local IDLE_PUMP_MS   = 1000   -- how often to tick the idle progression (pet.advance)
local FRAME_STEP     = 1      -- use every Nth cached frame (cache is already thinned to 16)

-- Per-asset loop-tail (1-based frame index). Normally an asset loops 1→N→1. For
-- these, the intro plays ONCE and then it loops from the tail index instead of 1 —
-- so the pet holds a pose without replaying the intro every cycle. idle-reading:
-- frames 1–8 pull the book out; 9–16 are reading with the book in hand. Looping from
-- 9 keeps the book OUT (Clawd keeps reading) instead of wrapping to 1 where the book
-- is put away and re-drawn each loop (spec: hold the book until the read ends).
-- idle-reading: files 000–009 are the intro (glasses on, book pulled out and passed
-- across the face); the steady both-hands reading pose is files 010–015. Loop from
-- index 11 (file 010) so the hold is a calm read, not the pass-left-and-back motion.
local LOOP_FROM = { ["idle-reading"] = 11 }

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
  ["idle"]              = 0.50,  -- reference, src bbox 102
  ["building"]          = 0.75,  -- 153
  ["debugger"]          = 0.70,  -- 129
  ["error"]             = 0.70,  -- 139
  ["happy"]             = 0.95,  -- 193 (capped, see above)
  ["headphones-groove"] = 0.85,  -- 164
  ["idle-reading"]      = 0.55,  -- 109
  ["juggling"]          = 0.70,  -- 121
  ["notification"]      = 0.73,  -- 149
  ["react-annoyed"]     = 0.73,  -- 146
  ["sleeping"]          = 0.70,  -- 134
  ["sweeping"]          = 0.70,  -- 122
  ["thinking"]          = 0.70,  -- 134
  ["typing"]            = 0.73,  -- 149
}
M._ASSET_SCALE = ASSET_SCALE

-- ── Renderer state ───────────────────────────────────────────────────────────
local cfg = {
  skin    = DEFAULT_SKIN,
  fps     = DEFAULT_FPS,
  width   = DEFAULT_WIDTH,
  height  = DEFAULT_HEIGHT,
  enabled = true,
}
local image        -- the image.nvim module, once loaded
local ready        = false  -- setup succeeded (image.nvim + a UI present)
local gated_fn     -- injected: returns true while a decision surface is up
local cache_root   -- stdpath("cache")/kodex_clawd/<skin>

local pet_win, pet_buf
local last_geom            -- last geometry applied to pet_win (skip redundant set_config)
local active_place         -- {cols, rows} of the CURRENT asset's sprite (float footprint)

-- ── Render trace ─────────────────────────────────────────────────────────────
-- Always-on lightweight diagnostics: every placement decision appends one line to
-- <cache>/kodex_clawd/render-trace.log (truncated at setup). Kitty behaviour can't
-- be asserted headless, so this is the ground truth for live-position debugging:
-- reproduce the issue, read the log. Declared BEFORE any caller — a later local
-- would leave earlier closures reading the nil GLOBAL of the same name.
local trace_path
local function trace(fmt, ...)
  if not trace_path then return end
  local f = io.open(trace_path, "a")
  if not f then return end
  f:write(os.date("%H:%M:%S "), fmt:format(...), "\n")
  f:close()
end
local anchor       = { mode = "panel", win = nil }  -- where the float pins
local frames_cache = {}   -- asset stem → { Image, … } (bound to the current pet_win)
local place_cache  = {}   -- asset stem → { cols, rows } sprite cell box (survives win recreate)
local current_asset       -- asset whose frames the swap timer is cycling
local shown_img           -- the Image currently on screen (cleared on the next swap)
local frame_i  = 1
local hidden   = false    -- true while gated() → image cleared, animation paused
local hold_cycle = false  -- HOLD_FULL_CYCLE asset playing: defer idle until wrap
local pending_state       -- state name deferred by hold_cycle (latest wins)
local swap_timer, idle_timer

-- ── image.nvim loading (lazy, graceful) ──────────────────────────────────────
-- Trigger lazy.nvim to put image.nvim on the runtimepath, then require + setup it.
-- Returns the module or nil; never throws.
local function load_image()
  pcall(function() require("lazy").load({ plugins = { "image.nvim" } }) end)
  local ok, mod = pcall(require, "image")
  if not ok then return nil end
  local setup_ok = pcall(mod.setup, {
    backend   = "kitty",
    processor = "magick_cli",  -- uses `convert`; no magick luarock needed
    integrations = {},          -- bare — the pet needs no markdown/treesitter hooks
    -- MUST be 100, not nil: a nil value is an ABSENT key in Lua, so image.nvim's
    -- default max_height_window_percentage=50 survives and silently clamps any
    -- sprite taller than half the pet float (5 rows → 4), which also strands it
    -- one row above the float bottom (the y offset was computed for the un-clamped
    -- height). Trace-proven 2026-07-11: req 12x5 → rendered 9x4.
    max_width_window_percentage  = 100,
    max_height_window_percentage = 100,
  })
  if not setup_ok then return nil end
  return mod
end

-- ── Geometry ─────────────────────────────────────────────────────────────────
-- Compute the pet float's editor-cell position for the current anchor. `panel`
-- pins bottom-right of the panel window (idle anchor); `chat` pins top-right of
-- the chat-bar float. Returns nil when the anchor window is gone — the pet is tied
-- to a real panel/chat window and must NOT float free without one (that's how a
-- raw `:q` on the panel would otherwise orphan a ghost pet).
-- Per-asset left-shift (cells) so every sprite's VISUAL right edge lines up with
-- groove's ~12px window-edge buffer (the reference position, user-picked). Assets
-- differ in transparent right margin INSIDE their canvas, so a uniform pad would
-- misalign them — groove itself needs 0 (its margin is baked in). Derived from
-- measured content-bbox right gaps: pad = max(0, round((12.3px - gap_screen)/cw)).
local X_PAD = {
  ["idle"]              = 1,
  ["building"]          = 1,
  ["debugger"]          = 0,
  ["error"]             = 1,
  ["happy"]             = 0,
  ["headphones-groove"] = 0,
  ["idle-reading"]      = 1,
  ["juggling"]          = 1,
  ["notification"]      = 1,
  ["react-annoyed"]     = 0,
  ["sleeping"]          = 1,
  ["sweeping"]          = 1,
  ["thinking"]          = 1,
  ["typing"]            = 1,
}

local function placed_geom(mode, wrow, wcol, ww, wh, pw, ph, pad)
  local col = wcol + ww - pw - (pad or 0)
  local row
  if mode == "surface" then
    -- A bordered float's win_get_position() row IS its border row (screenpos-proven:
    -- config row=10 → border at 10, content at 11), so the float bottom lands on
    -- wrow-1, immediately above the border. FINAL after two live A/Bs (2026-07-11):
    -- overlapping the border row makes the feet visibly cover the outline; sitting
    -- one row above it is the flush look the user wants. Do not re-try the overlap.
    row = wrow - ph
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
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
  local pos = vim.api.nvim_win_get_position(win)
  return placed_geom(anchor.mode, pos[1], pos[2],
    vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win), pw, ph,
    current_asset and X_PAD[current_asset] or 0)
end

-- Opaque carrier: the float paints the shared bar_bg (ClaudeNormal) so it reads as
-- an invisible box on panel/chat/modal surfaces AND masks the per-swap kitty
-- retransmit gap (image.nvim clear() wipes the transmit cache; the flash shows
-- through a transparent carrier). True transparency is a future goal, but only
-- once a non-ghosting cache-preserving swap is proven live.
local function apply_appearance(win)
  pcall(function()
    if vim.wo[win].winhighlight ~= "NormalFloat:ClaudeNormal" then
      vim.wo[win].winhighlight = "NormalFloat:ClaudeNormal"
    end
    if vim.wo[win].winblend ~= 0 then vim.wo[win].winblend = 0 end
  end)
end

-- Create the pet float if absent/invalid, else move it to the current anchor.
-- Returns true if a usable window exists, false when there is no valid anchor.
local function ensure_win()
  local geom = anchor_geom()
  if not geom then return false end   -- no panel/chat to pin to → no pet
  if pet_win and vim.api.nvim_win_is_valid(pet_win) then
    -- Only reconfigure when the geometry ACTUALLY changed (anchor switch / panel resize).
    -- ensure_win runs on every state change; a no-op set_config still forces a redraw
    -- that retransmits the kitty image = the per-transition flicker. Skip it when the
    -- float already sits where it should.
    if not (last_geom and last_geom.row == geom.row and last_geom.col == geom.col
        and last_geom.width == geom.width and last_geom.height == geom.height) then
      pcall(vim.api.nvim_win_set_config, pet_win, {
        relative = "editor", row = geom.row, col = geom.col,
        width = geom.width, height = geom.height,
      })
      last_geom = geom
      local ap = vim.api.nvim_win_get_position(anchor.win)
      trace("move mode=%s float row=%d col=%d | anchor win=%d pos=%d,%d h=%d",
        anchor.mode, geom.row, geom.col, anchor.win, ap[1], ap[2],
        vim.api.nvim_win_get_height(anchor.win))
    end
    apply_appearance(pet_win)
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
    relative = "editor", anchor = "NW",
    row = geom.row, col = geom.col, width = geom.width, height = geom.height,
    -- High zindex so the pet floats ABOVE permission/question modals (user wants Clawd
    -- on top of them). image.nvim can hide an image whose window is covered by a
    -- higher-zindex float, so the pet must out-rank the cards (dressing/telescope modals
    -- sit ~50–200). The opaque bar_bg float still blends with the modal (same bar_bg).
    style = "minimal", border = "none", focusable = false, zindex = 250,
  })
  if not ok then return false end
  pet_win = win
  last_geom = geom            -- baseline for the set_config skip-guard above
  apply_appearance(pet_win)   -- opaque bar_bg (invisible box, masks the retransmit flicker)
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
  return 8, 17  -- sane Ghostty-ish fallback
end

-- PNG pixel dimensions straight from the IHDR header (no subprocess): 8-byte signature,
-- 4-byte length, "IHDR", then big-endian 4-byte width + 4-byte height.
local function png_dims(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local hdr = f:read(24)
  f:close()
  if not hdr or #hdr < 24 then return nil end
  local function be(a) return hdr:byte(a) * 0x1000000 + hdr:byte(a + 1) * 0x10000
    + hdr:byte(a + 2) * 0x100 + hdr:byte(a + 3) end
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
  if not (cw and ch) then cw, ch = cell_size() end
  local scale = math.min((cfg.width * cw) / fw, (cfg.height * ch) / fh)
    * (ASSET_SCALE[asset] or DEFAULT_ASSET_SCALE)
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
-- Lazy-load + cache the Image objects for an asset, bound to the current pet_win.
-- Bound-to-window is why the cache is invalidated on teardown (a stale window
-- reference would render nothing). Returns the frame array (possibly empty).
local function ensure_frames(asset)
  local existing = frames_cache[asset]
  if existing then return existing end
  local frames = {}
  local dir = cache_root .. "/" .. asset
  if vim.fn.isdirectory(dir) == 1 then
    local files = vim.fn.readdir(dir)
    table.sort(files)
    -- All frames of an asset share one crop box, so compute placement once from the
    -- first frame and reuse it — every frame lands in the same spot (no jitter).
    local fw, fh = png_dims(dir .. "/" .. (files[1] or ""))
    local _, _, pcols, prows = frame_placement(asset, fw, fh)
    local tcw, tch = cell_size()
    trace("frames %s: png=%sx%s cols=%d rows=%d cell=%.1fx%.2f scale=%.2f",
      asset, tostring(fw), tostring(fh), pcols, prows, tcw, tch,
      ASSET_SCALE[asset] or DEFAULT_ASSET_SCALE)
    -- The float is resized to exactly pcols x prows for this asset (see
    -- place_cache/anchor_geom), so the sprite fills the window from its top-left.
    for i = 1, #files, FRAME_STEP do
      local ok, img = pcall(image.from_file, dir .. "/" .. files[i], {
        window = pet_win, x = 0, y = 0, width = pcols, height = prows,
      })
      if ok and img then frames[#frames + 1] = img end
    end
    place_cache[asset] = { cols = pcols, rows = prows }
  end
  frames_cache[asset] = frames
  return frames
end

-- Render the next frame BEFORE clearing the previous one (anti-flicker order).
local last_traced_asset
local function swap_to(img)
  if not img or img == shown_img then return end
  pcall(function() img:render() end)
  if shown_img then pcall(function() shown_img:clear(true) end) end
  shown_img = img
  -- Trace once per asset switch (not per frame): the ACTUAL rendered geometry the
  -- backend used — the decisive number when cells and screen disagree.
  if current_asset ~= last_traced_asset then
    last_traced_asset = current_asset
    local rg = img.rendered_geometry or {}
    local g = img.geometry or {}
    trace("render %s: req x=%s y=%s w=%s h=%s | rendered x=%s y=%s w=%s h=%s",
      tostring(current_asset), tostring(g.x), tostring(g.y), tostring(g.width),
      tostring(g.height), tostring(rg.x), tostring(rg.y), tostring(rg.width),
      tostring(rg.height))
  end
end
local function clear_shown()
  if shown_img then pcall(function() shown_img:clear(true) end) end
  shown_img = nil
end

-- ── Timers ───────────────────────────────────────────────────────────────────
-- One animation tick: hide/restore off gated(), then advance one frame.
local function on_swap_tick()
  if not (ready and pet_win and vim.api.nvim_win_is_valid(pet_win)) then return end

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
  if not ensure_win() then M.teardown(); return end

  local now_gated = gated_fn and gated_fn() or false
  if now_gated then
    if not hidden then clear_shown(); hidden = true end
    return
  elseif hidden then
    hidden = false  -- decision surface dismissed → repaint below
  end

  local frames = current_asset and frames_cache[current_asset]
  if not frames or #frames == 0 then return end
  -- Advance one frame, wrapping to the asset's loop-tail (default 1) at the end so
  -- intro-then-hold assets (idle-reading) don't replay their intro every cycle.
  local nxt
  if frame_i >= #frames then
    -- Full cycle done: release the hold and apply the state it deferred (if any).
    if hold_cycle then
      hold_cycle = false
      local deferred = pending_state
      pending_state = nil
      if deferred then M.render_state(deferred); return end
    end
    nxt = math.min(LOOP_FROM[current_asset] or 1, #frames)
  else
    nxt = frame_i + 1
  end
  if nxt == frame_i then                 -- single-frame state: just ensure it's up
    swap_to(frames[frame_i]); return
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
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
  return nil
end

-- ── Public API (the pet.render seam + init lifecycle hooks) ───────────────────

-- The injected renderer seam. pet.lua calls this on every real state change.
-- Maps the pet state to its asset, paints frame 1 render-before-clear, and keeps
-- the swap timer cycling. A no-op while disabled, gated, or asset-less.
function M.render_state(name, _prev)
  if not (ready and cfg.enabled) then return end
  local asset = STATE_ASSET[name]
  if not asset then return end

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

  local frames = ensure_frames(asset)
  current_asset = asset
  frame_i = 1
  if #frames == 0 then clear_shown(); return end  -- assets missing: show nothing

  -- Resize the float to THIS asset's sprite box (ensure_win above ran with the
  -- previous asset's footprint — it had to exist before ensure_frames could bind
  -- Images to it). Cheap: ensure_win no-ops when the geometry didn't change.
  active_place = place_cache[asset]
  ensure_win()

  if not (gated_fn and gated_fn()) then
    hidden = false
    swap_to(frames[1])
  else
    -- Entered while a card is up: clear any sprite still on screen BEFORE latching
    -- hidden. Without the clear, the next swap tick skips it (its guard is
    -- `if not hidden`), leaving the old frame kitty-composited ON TOP of the card
    -- for its whole lifetime — the spike-Q2 bleed the hide rule exists to prevent.
    clear_shown()
    hidden = true
  end
  start_timers()
end

-- Pin the pet bottom-right of the Claude panel (idle/working anchor). Called when
-- the panel opens and when the chat bar closes.
function M.attach_to_panel(win)
  anchor = { mode = "panel", win = win }
  if not (ready and cfg.enabled) then return end
  if not ensure_win() then return end
  if shown_img then
    pcall(function() shown_img:render() end)  -- repaint current frame at the new pos
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
  anchor = { mode = "surface", win = win }
  if not (ready and cfg.enabled) then return end
  if not ensure_win() then return end
  if shown_img then
    pcall(function() shown_img:render() end)
  elseif current_asset then
    -- See attach_to_panel: rebuild frames against a recreated float instead of
    -- leaving the pet blank until the next state change.
    M.render_state(pet.state)
  end
end

-- Backward-compatible name for the original chat-only call site.
M.attach_to_chat = M.attach_to_surface

-- Live diagnostic seam for terminal-only placement issues.
function M.debug_geometry()
  local cw, ch = cell_size()
  return {
    asset = current_asset, anchor_mode = anchor.mode, anchor_geom = anchor_geom(),
    cell = { width = cw, height = ch }, cfg = vim.deepcopy(cfg),
    image_geometry = shown_img and vim.deepcopy(shown_img.geometry) or nil,
    rendered_geometry = shown_img and vim.deepcopy(shown_img.rendered_geometry) or nil,
    -- Raw anchor-window metrics: enough to hand-check placed_geom against what is
    -- actually on screen (SW-anchored bordered floats are the suspect case).
    anchor_win = (function()
      local w = anchor.win
      if not (w and vim.api.nvim_win_is_valid(w)) then return nil end
      local p = vim.api.nvim_win_get_position(w)
      local c = vim.api.nvim_win_get_config(w)
      return { win = w, pos_row = p[1], pos_col = p[2],
        width = vim.api.nvim_win_get_width(w), height = vim.api.nvim_win_get_height(w),
        cfg_anchor = c.anchor, cfg_row = c.row, cfg_col = c.col, border = c.border and true or false }
    end)(),
    pet_win_cfg = (pet_win and vim.api.nvim_win_is_valid(pet_win))
      and vim.api.nvim_win_get_config(pet_win) or nil,
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
    for _, img in ipairs(frames) do pcall(function() img:clear(true) end) end
  end
  frames_cache = {}
  current_asset = nil
  frame_i = 1
  hidden = false
  hold_cycle = false
  pending_state = nil
  if pet_win and vim.api.nvim_win_is_valid(pet_win) then
    pcall(vim.api.nvim_win_close, pet_win, true)
  end
  pet_win = nil
  last_geom = nil   -- window gone → next ensure_win recreates + rebaselines
end

-- Wire the renderer into the pure state machine and prime image.nvim. `opts`:
--   { skin, fps, width, height, enabled, gated = <fn> }.
-- Idempotent-ish: safe to call once at plugin setup. When image.nvim or a UI is
-- absent, leaves pet.render as the pure no-op stub so the pet stays headless-safe.
function M.setup(opts)
  opts = opts or {}
  cfg.skin    = opts.skin    or cfg.skin
  cfg.fps     = opts.fps     or cfg.fps
  cfg.width   = opts.width   or cfg.width
  cfg.height  = opts.height  or cfg.height
  if opts.enabled ~= nil then cfg.enabled = opts.enabled end
  gated_fn = opts.gated
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
  if tf then tf:close() end
  local cw, ch = cell_size()
  trace("setup: cell=%.1fx%.2f cfg=%dx%d skin=%s", cw, ch, cfg.width, cfg.height, cfg.skin)

  -- Route pet state changes to the renderer. pet.lua pcall-guards this call, and
  -- render_state pcall-guards each image op, so a render throw can't reach dispatch.
  pet.render = function(name, prev) M.render_state(name, prev) end
  return true
end

return M
