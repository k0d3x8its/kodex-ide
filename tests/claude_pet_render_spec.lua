-- tests/claude_pet_render_spec.lua
-- Headless guards for the Clawd pet RENDERER (lua/utils/claude/pet_render.lua).
-- The renderer is image/window code — the visual behaviour (animation, hide-on-
-- gated, teardown) is proven by the L1–L3 Ghostty spikes + a HITL pass, NOT here.
-- What IS headless-checkable, and matters, is the invariants that fail silently:
--   • the state→asset map covers EVERY state the pure machine can resolve (a
--     missing entry = the pet shows nothing for that state, no error);
--   • setup() disables cleanly with no UI (this is what keeps `make test` green);
--   • render_state / attach / teardown are safe no-ops while disabled.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_pet_render_spec.lua"

local H = dofile("tests/helpers.lua")

local pr  = require("utils.claude.pet_render")
local pet = require("utils.claude.pet")

-- The 14 canonical pet states (docs/clawd-overlay-spec.md § States → assets). This
-- is the renderer's contract with the pure machine: every state pet.resolve() can
-- return must map to an asset.
local STATES = {
  "error", "diff_wait", "diff_rejected", "diff_approved", "debugging", "cleaning",
  "reading", "subagent", "thinking", "typing", "happy", "headphones_groove",
  "idle", "sleep",
}

-- ── Map completeness (PR-MAP) ────────────────────────────────────────────────
local map = pr._STATE_ASSET
H.check("PR-MAP0 map exposed", type(map) == "table")
for _, st in ipairs(STATES) do
  H.check("PR-MAP " .. st .. " → nonempty asset",
    type(map[st]) == "string" and #map[st] > 0)
end

-- ── Disabled-path safety (PR-SAFE) ───────────────────────────────────────────
-- Under `nvim --headless` there is no UI, so setup() must disable and every op
-- must be a guarded no-op (this is exactly the state `make test` runs in).
local sok, enabled = pcall(pr.setup, {})
H.check("PR-SAFE0 setup does not throw headless", sok)
H.check("PR-SAFE1 setup returns false with no UI", enabled == false)
H.check("PR-SAFE2 pet.render left as the pure stub (no renderer wired)",
  pet.render(nil, nil) == nil)

for _, st in ipairs(STATES) do
  H.check("PR-SAFE render_state(" .. st .. ") no-op",
    pcall(pr.render_state, st, "sleep"))
end
H.check("PR-SAFE3 attach_to_panel no-op", pcall(pr.attach_to_panel, nil))
H.check("PR-SAFE4 attach_to_chat no-op", pcall(pr.attach_to_chat, nil))
H.check("PR-SAFE5 teardown no-op", pcall(pr.teardown))


-- Pure placement contract for surfaces, statusline, and idle normalization.
-- win_get_position row = the BORDER row of a bordered float. Raw frames: the pet
-- float's bottom row (row+ph-1) is wrow-1, just above the border. Padded feet-on-
-- line frames (overlap=true): ph counts the extra row and the float extends onto
-- the border row itself — feet land at its mid-cell, on the outline glyph (which
-- kitty z=-1 draws OVER the sprite, so the outline is never covered).
local sg = pr._placed_geom("surface", 50, 80, 40, 3, 12, 8)
H.check("PR-GEOM0 surface sits above top border", sg.row == 42)
H.check("PR-GEOM1 surface right edge is flush when unpadded", sg.col == 108)
local sgp = pr._placed_geom("surface", 50, 80, 40, 3, 12, 8, 1)
H.check("PR-GEOM1b per-asset x-pad shifts left", sgp.col == 107)
-- Padded variant: same sprite (8 raw rows) ships as ph=9 with overlap → the float
-- bottom row IS the border row (top row unchanged vs the raw placement).
local sgo = pr._placed_geom("surface", 50, 80, 40, 3, 12, 9, 0, true)
H.check("PR-GEOM0b padded surface overlaps the border row", sgo.row == 42)
H.check("PR-GEOM0c padded float bottom row is the border row", sgo.row + 9 - 1 == 50)
local pg = pr._placed_geom("panel", 2, 80, 40, 50, 12, 8)
H.check("PR-GEOM2 panel sits above statusline", pg.row == 44)
local ix, iy, iw, ih = pr._frame_placement("idle", 96, 64, 8, 16)
H.check("PR-SCALE0 idle is half-width", iw == 6)
H.check("PR-SCALE1 idle is half-height", ih == 2)
H.check("PR-SCALE2 idle remains bottom-right", ix == 6 and iy == 6)
-- sleeping carries a per-asset scale (0.70): source-bbox normalization to idle.
-- rows snap to floor(64*0.70/16+0.5)=3, exact 3*16/64=0.75 → cols ceil(96*0.75/8)=9.
local _, _, sw, sh = pr._frame_placement("sleeping", 96, 64, 8, 16)
H.check("PR-SCALE3 sleep uses its per-asset scale", sw == 9 and sh == 3)

H.summary("claude_pet_render_spec")
