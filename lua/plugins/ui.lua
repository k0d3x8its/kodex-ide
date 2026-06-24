-- lua/plugins/ui.lua
return {
  -- Dracula colorscheme (Lua port)
  {
    "Mofiqul/dracula.nvim",
    name     = "dracula",
    lazy     = false, -- load at startup
    priority = 1000,  -- before other plugins
    config   = function()
      local dracula = require("dracula")

      dracula.load() -- sets the colorscheme
    end,
  },

  -- Lualine statusline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy         = false,
    config       = function()
      local lualine = require("lualine")
      local lazy_status = require("lazy.status")
      local pio_status = require("utils.pio_status")

      pio_status.setup()

      local function lazy_updates_icon()
        local updates = lazy_status.updates()
        if updates == "" then return "" end
        local count = updates:match("(%d+)")
        return count .. " "
      end

      -- True when the focused buffer is the Claude panel (or its reply float) —
      -- both carry filetype "claude". Drives the modal statusline so the panel
      -- reads as a native Neovim mode: CLAUDE on the left, CODE on the right.
      local function in_claude()
        return vim.bo.filetype == "claude"
      end

      -- Orange (clay #D97757) fill for the modal CLAUDE / CODE words, matching the
      -- Claude logo glyph. Applied only while the panel shows its mode word
      -- ("CLAUDE", i.e. normal mode) — when the chat bar is open and the user is
      -- typing, the mode segment shows a normal "INSERT" in the default theme
      -- colour, exactly like any other Neovim window.
      local claude_orange = { bg = "#D97757", fg = "#111010", gui = "bold" }
      local function mode_color()
        if in_claude() and vim.fn.mode() == "n" then return claude_orange end
        return nil
      end

      -- Powerline separator glyphs as explicit UTF-8 bytes (U+E0B0 right, U+E0B2
      -- left) so the orange CLAUDE / CODE blocks keep their arrow caps — a custom
      -- component `color` otherwise drops lualine's auto-drawn section separators.
      local pl_right = "\238\130\176"
      local pl_left  = "\238\130\178"

      lualine.setup({
        options = {
          theme                = "dracula",
          section_separators   = { left = "", right = "" },
          component_separators = { left = " ", right = "" },
        },
        sections = {
          -- Mode segment: show "CLAUDE" in the panel in normal mode, but fall back
          -- to the real mode ("INSERT" while typing in the chat float) so the bar
          -- behaves like a native Neovim window when editing.
          lualine_a = {
            {
              "mode",
              color     = mode_color,
              -- Explicit right arrow so the orange CLAUDE block keeps its powerline
              -- cap (the custom colour drops the auto separator). Same glyph as
              -- section_separators, so non-claude buffers look unchanged.
              separator = { right = pl_right },
              fmt = function(str)
                if in_claude() and str == "NORMAL" then return "CLAUDE" end
                return str
              end,
            },
          },
          lualine_c = {
            -- Hide the buffer name in the panel (it rendered as the redundant,
            -- truncated "claude [-]"); show it normally everywhere else.
            {
              "filename",
              symbols = { unnamed = "[terminal]" },
              cond    = function() return not in_claude() end,
            },
            {
              pio_status.badge,
              padding = { left = 0, right = 0 },
            },
          },
          lualine_x = {
            {
              lazy_updates_icon,
              cond = lazy_status.has_updates,
              color = { fg = "#ff9e64" },
            },
            "encoding",
            "fileformat",
            -- Drop the "claude" filetype tag in the panel (redundant with the
            -- CLAUDE mode word); keep it for every other buffer.
            { "filetype", cond = function() return not in_claude() end },
          },
          -- In the panel, show the Claude Code glyph (✻) + the current model
          -- (e.g. "✻ Sonnet 4.6") where progress (Top/Bot/%%) normally sits — more
          -- useful than scroll position. Every other buffer keeps progress.
          lualine_y = {
            {
              function() return "✻ " .. require("utils.claude").current_model() end,
              cond = in_claude,
            },
            {
              "progress",
              cond = function() return not in_claude() end,
            },
          },
          -- Far-right "CODE" mirrors the left "CLAUDE", same orange fill; only in
          -- the panel. location stays for all buffers (default lualine_z content).
          lualine_z = {
            "location",
            {
              function() return "CODE" end,
              cond      = in_claude,
              color     = claude_orange,
              -- Left arrow so CODE gets a powerline cap into its orange block.
              separator = { left = pl_left },
            },
          },
        },
        -- Inactive windows (per-window statuslines). While the user types in the
        -- chat float, the panel is "inactive", so without this its bar would fall
        -- back to the default filename → the ugly "claude [-]". Show a clean
        -- "CLAUDE … ✻ model … CODE" instead; the filename stays for normal buffers.
        inactive_sections = {
          lualine_a = {},
          lualine_b = {},
          lualine_c = {
            { function() return "CLAUDE" end, cond = in_claude, color = { fg = "#D97757", gui = "bold" } },
            { "filename", cond = function() return not in_claude() end },
          },
          lualine_x = {
            { function() return "✻ " .. require("utils.claude").current_model() end, cond = in_claude },
            "location",
          },
          lualine_y = {},
          lualine_z = {
            { function() return "CODE" end, cond = in_claude, color = { fg = "#D97757", gui = "bold" } },
          },
        },
      })
    end,
  },
}
