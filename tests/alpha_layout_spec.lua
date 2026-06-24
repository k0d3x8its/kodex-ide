-- tests/alpha_layout_spec.lua
--
-- No-bleed invariant for the alpha recent-files button width math.
-- alpha right-aligns the "SPC N" shortcut at the button's width; every button
-- in a group shares ONE width, so that width must clear the WIDEST label by at
-- least `gap + shortcut_w` cells — otherwise the shortcut bleeds into the label.
-- Sizing from byte length (or a guessed 1-cell icon) underflows when a label
-- carries a 2-display-cell nerd-font glyph, which is the bug this guards.
local H = dofile("tests/helpers.lua")
local layout = require("utils.alpha_layout")

-- Core invariant: for EVERY label the shared width leaves at least gap+shortcut
-- cells of slack, so the right-aligned shortcut never touches the label text.
local function no_bleed(labels, shortcut_w, gap)
  local w = layout.button_width(labels, shortcut_w, gap)
  for _, l in ipairs(labels) do
    local slack = w - vim.fn.strdisplaywidth(l)
    if slack < gap + shortcut_w then
      return false, string.format("label %q slack %d < %d", l, slack, gap + shortcut_w)
    end
  end
  return true
end

-- 2-cell nerd-font icon: "" is a single PUA glyph rendered in 2 display cells,
-- so a byte-length or codepoint-count guess would size the button too narrow.
local ok1, why1 = no_bleed({ "  ~/dev/foo" }, 5, 4)
H.check("2-cell icon label clears shortcut", ok1, why1)

-- Mixed widths: the shared width must be driven by the WIDEST label, not the
-- first/last one, and must hold the invariant for all of them.
local mixed = {
  "  ~/a",
  "  ~/dev/some/very/long/nested/path/to/batctrl",
  "  ~/dev/mid",
}
local ok2, why2 = no_bleed(mixed, 5, 4)
H.check("mixed-width group: every label clears shortcut", ok2, why2)

local widest = "  ~/dev/some/very/long/nested/path/to/batctrl"
H.check(
  "width sized from the widest label",
  layout.button_width(mixed, 5, 4) == vim.fn.strdisplaywidth(widest) + 4 + 5,
  layout.button_width(mixed, 5, 4)
)

-- Empty list (no recent files): degrades to gap+shortcut, never errors or goes
-- negative.
H.check("empty label list returns gap+shortcut", layout.button_width({}, 5, 4) == 9)

-- ── truncate_left ───────────────────────────────────────────────────────────
-- A string that already fits is returned untouched (no spurious ellipsis).
H.check(
  "fitting string unchanged",
  layout.truncate_left("~/dev/foo", 20) == "~/dev/foo"
)

-- A long string is cut from the LEFT, keeps the tail, fits the budget exactly.
do
  local s = "~/dev/kos-burn-bar/.compound-engineering/config.local.example.yaml"
  local t = layout.truncate_left(s, 20)
  H.check("long string truncated to budget", vim.fn.strdisplaywidth(t) <= 20, vim.fn.strdisplaywidth(t))
  H.check("truncation keeps the tail (filename)", t:sub(-4) == "yaml", t)
  H.check("truncation prepends ellipsis", t:sub(1, string.len("…")) == "…", t)
end

-- Budget never exceeded even when the kept tail starts with a 2-cell glyph: the
-- glyph is dropped whole rather than straddling the boundary.
H.check(
  "2-cell glyph never straddles the budget",
  vim.fn.strdisplaywidth(layout.truncate_left("aaaa", 2)) <= 2,
  vim.fn.strdisplaywidth(layout.truncate_left("aaaa", 2))
)

-- Degenerate budgets return empty, never error or go negative.
H.check("zero budget returns empty", layout.truncate_left("anything", 0) == "")
H.check("negative budget returns empty", layout.truncate_left("anything", -3) == "")

H.summary("alpha_layout_spec")
