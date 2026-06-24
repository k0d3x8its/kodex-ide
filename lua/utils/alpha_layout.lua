-- lua/utils/alpha_layout.lua
--
-- Width math for alpha dashboard buttons that carry a right-aligned shortcut key
-- (e.g. the Recent Files list: "  ~/dev/foo            SPC 4").
--
-- alpha right-aligns the shortcut at the button's `width`, and every button in a
-- group shares ONE width. So the width must clear the WIDEST label in the group,
-- not a guessed path-length + constants. The previous approach sized from the
-- longest path plus a fixed "+3 icon / +8 shortcut" fudge, which ignored that a
-- nerd-font icon can be two display cells (and that the widest *label* may not be
-- the longest *path*) — leaving too little room, so "SPC N" bled into the label.

local M = {}

--- Button width (display cells) guaranteeing the right-aligned shortcut keeps at
--- least `gap` blank cells from every label, so it never bleeds into the text.
--- @param labels     string[]  full label strings (icon + path), measured by display width
--- @param shortcut_w integer   display cells of the widest shortcut (e.g. "SPC 5" = 5)
--- @param gap        integer    minimum blank cells kept between a label and its shortcut
--- @return integer
function M.button_width(labels, shortcut_w, gap)
  local max_label = 0
  for _, l in ipairs(labels) do
    local w = vim.fn.strdisplaywidth(l)
    if w > max_label then max_label = w end
  end
  return max_label + gap + shortcut_w
end

--- Left-truncate `s` to at most `max` display cells, prepending an ellipsis when
--- cut so the meaningful TAIL (the filename) stays visible — the head of a long
--- path is the throwaway part. Display-width aware, so a 2-cell nerd-font or CJK
--- glyph never straddles the budget. Returns `s` unchanged when it already fits.
--- @param s   string
--- @param max integer  display-cell budget
--- @return string
function M.truncate_left(s, max)
  if max <= 0 then return "" end
  if vim.fn.strdisplaywidth(s) <= max then return s end
  local ell = "…" -- 1 display cell
  local budget = max - 1 -- reserve the ellipsis cell
  local chars = vim.fn.split(s, "\\zs") -- per-character, multibyte-safe
  local tail, w = {}, 0
  for i = #chars, 1, -1 do
    local cw = vim.fn.strdisplaywidth(chars[i])
    if w + cw > budget then break end
    table.insert(tail, 1, chars[i])
    w = w + cw
  end
  return ell .. table.concat(tail)
end

return M
