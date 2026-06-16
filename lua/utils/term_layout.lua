-- lua/utils/term_layout.lua
--
-- Centralised window placement for the project's two singleton terminals
-- (the dev shell + the OpenCode panel).
--
-- WHY this exists: toggleterm GROUPS terminal splits. `ui.open_split` calls
-- `find_open_windows()`, which matches *any* window whose buffer filetype is
-- "toggleterm" — so when a second terminal opens while the first is visible, it
-- anchors its split to the first terminal's window (the `existing` split command)
-- instead of taking its own edge. Net effect:
--   * opening OpenCode (vertical) while the dev term (horizontal) is open ran
--     `rightbelow split` → OpenCode stacked HORIZONTALLY under the terminal.
--   * opening the dev term while OpenCode is open ran `rightbelow vsplit` →
--     the terminal opened as a thin full-height column right of OpenCode.
-- Re-asserting the intended edge in each terminal's `on_open` defeats the
-- grouping.
local mod = {}

-- Windows we never want to anchor the dev strip under: the OTHER terminals and
-- the side panels. Everything else is "main content" — a real file, but also the
-- alpha dashboard (buftype "nofile") when no file is open yet. Matching on
-- buftype=="" alone missed the dashboard and fell back to a full-width strip
-- under OpenCode.
local EXCLUDE_FT = {
  toggleterm = true,
  NvimTree = true,
  ["neo-tree"] = true,
}

--- The main content window to anchor the bottom strip under: the first window
--- that is neither a terminal nor a side panel. `exclude` is the strip's own
--- window. Returns nil only when nothing but terminals/sidebars is visible.
---@param exclude integer
---@return integer?
local function editor_window(exclude)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= exclude then
      local b = vim.api.nvim_win_get_buf(w)
      local ft = vim.api.nvim_get_option_value("filetype", { buf = b })
      if not EXCLUDE_FT[ft] then
        return w
      end
    end
  end
  return nil
end

--- Pin the just-opened terminal window to the far-right, full-height column.
--- Call from a vertical terminal's on_open. `width` is columns.
function mod.place_vertical(width)
  vim.cmd("wincmd L")
  vim.cmd("vertical resize " .. width)
end

--- Pin the just-opened terminal window to a bottom strip under the EDITOR.
--- Call from a horizontal terminal's on_open. `height` is rows.
---
--- Uses win_splitmove to re-home the strip directly below the editor window
--- rather than `wincmd J` (full-width bottom). This is deliberate: `wincmd J`
--- would span the strip under the OpenCode panel too, and — worse — any wincmd
--- that moves/resizes OpenCode's window leaves its live TUI on a stale
--- alternate screen (blank/black) because the move doesn't trigger a redraw.
--- win_splitmove relocates ONLY our window, so OpenCode is never touched.
--- Falls back to `wincmd J` when no editor window is visible.
function mod.place_horizontal(height)
  local strip = vim.api.nvim_get_current_win()
  local editor = editor_window(strip)
  if editor then
    pcall(vim.fn.win_splitmove, strip, editor, { vertical = false, rightbelow = true })
    -- win_splitmove can shift the current window; reselect the strip to resize it
    if vim.api.nvim_win_is_valid(strip) then
      vim.api.nvim_set_current_win(strip)
    end
  else
    vim.cmd("wincmd J")
  end
  vim.cmd("resize " .. height)
end

return mod
