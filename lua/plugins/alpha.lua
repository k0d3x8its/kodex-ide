return {
  "goolord/alpha-nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  event = "VimEnter",
  cmd = "Alpha",

  config = function()
    local alpha = require("alpha")
    local dashboard = require("alpha.themes.dashboard")
    local devicons = require("nvim-web-devicons")

    -- ────────────────────────────────────────────────────────────────────────────
    -- 1) HEADER
    -- ────────────────────────────────────────────────────────────────────────────

    dashboard.section.header.val = {
      "██╗  ██╗ ██████╗ ██████╗ ██████╗ ██╗  ██╗    ██╗██████╗ ███████╗",
      "██║ ██╔╝██╔═████╗██╔══██╗╚════██╗╚██╗██╔╝    ██║██╔══██╗██╔════╝",
      "█████╔╝ ██║██╔██║██║  ██║ █████╔╝ ╚███╔╝     ██║██║  ██║█████╗  ",
      "██╔═██╗ ████╔╝██║██║  ██║ ╚═══██╗ ██╔██╗     ██║██║  ██║██╔══╝  ",
      "██║  ██╗╚██████╔╝██████╔╝██████╔╝██╔╝ ██╗    ██║██████╔╝███████╗",
      "╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚═╝╚═════╝ ╚══════╝",
    }

    -- ────────────────────────────────────────────────────────────────────────────
    -- 2) KEYMAPS SECTION
    -- ────────────────────────────────────────────────────────────────────────────

    local keymap_defs = {
      { key = "SPC nf", icon = " ", desc = "New File", cmd = "<cmd>ene<CR>" },
      {
        key = "SPC ff",
        icon = " ",
        desc = "Find File",
        cmd = "<cmd>lua require('utils.telescope_home').find_files()<CR>",
      },
      {
        key = "SPC fw",
        icon = " ",
        desc = "Find Word",
        cmd = "<cmd>lua require('utils.telescope_home').live_grep()<CR>",
      },
      { key = "SPC rs", icon = "󰁯 ", desc = "Restore Session", cmd = "<cmd>SessionRestore<CR>" },
      {
        key = "SPC cf",
        icon = " ",
        desc = "NVIM Config",
        cmd = "<cmd>lua require('utils.config_tree_toggle').toggle_at_config()<CR>",
      },
      { key = "q", icon = " ", desc = "Quit NVIM", cmd = "<cmd>qa<CR>" },
    }

    local keymaps = { type = "group", val = {}, opts = { spacing = 1 } }
    -- header for the keymaps group
    table.insert(keymaps.val, { type = "text", val = "  Keymaps", opts = { hl = "Title", position = "center" } })

    for _, m in ipairs(keymap_defs) do
      local label = string.format("%s  %s", m.icon, m.desc)
      local btn = dashboard.button(m.key, label, m.cmd)
      btn.opts.position = "center"
      table.insert(keymaps.val, btn)
    end

    -- ────────────────────────────────────────────────────────────────────────────
    -- 3) RECENT FILES SECTION — buttons size to the widest label so the
    --    right-aligned "SPC N" shortcut clears the path. Long paths are
    --    left-truncated ("…/tail") to fit the alpha WINDOW, so opening the
    --    Claude panel (which narrows this window) can't push the shortcut into
    --    the path. Re-flows on resize.
    -- ────────────────────────────────────────────────────────────────────────────
    local layout = require("utils.alpha_layout")
    local GAP, SHORTCUT_W = 4, 5 -- "SPC 5" = 5 cells; 4 blank cells of slack
    local recent = { type = "group", val = {}, opts = { spacing = 1 } }

    -- Keep only the 5 most-recent real files.
    local files = {}
    for _, f in ipairs(vim.v.oldfiles) do
      if #files >= 5 then
        break
      end
      if f ~= "" and vim.fn.filereadable(f) == 1 then
        table.insert(files, f)
      end
    end

    -- Display width of the alpha window right now (falls back to &columns before
    -- the window exists). Splitting in the Claude panel shrinks this AFTER the
    -- first draw, which is exactly when long paths overflowed into "SPC N".
    local function alpha_win_width()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "alpha" then
          return vim.api.nvim_win_get_width(w)
        end
      end
      return vim.o.columns
    end

    -- (Re)build the recent-files buttons sized to the current window. Called at
    -- setup and on resize so the truncation tracks the live window width.
    local function populate_recent()
      recent.val = {
        { type = "text", val = "  Recent Files", opts = { hl = "Title", position = "center" } },
      }
      -- Cap label width so the shared btn_width stays compact on wide windows.
      -- Without a cap, the widest path dominates btn_width and short entries get
      -- 50+ cells of dead space before SPC N. The cap keeps the gap similar to
      -- the keymap section's alpha default (≈40 cells wide) even at full-screen.
      local MAX_LABEL = 44
      local budget = math.min(alpha_win_width() - GAP - SHORTCUT_W - 4, MAX_LABEL)

      local labels = {}
      for _, file in ipairs(files) do
        local ext = vim.fn.fnamemodify(file, ":e")
        local icon = devicons.get_icon(file, ext, { default = true }) or " "
        local prefix = icon .. "  "
        local path = vim.fn.fnamemodify(file, ":~")
        -- Truncate only the path; the icon prefix always survives.
        path = layout.truncate_left(path, budget - vim.fn.strdisplaywidth(prefix))
        table.insert(labels, prefix .. path)
      end

      -- Size the shared width from the ACTUAL (post-truncation) label widths.
      local btn_width = layout.button_width(labels, SHORTCUT_W, GAP)
      for i, file in ipairs(files) do
        local cmd = "<cmd>e " .. vim.fn.fnameescape(file) .. "<CR>" -- fnameescape: spaces/#
        local btn = dashboard.button("SPC " .. i, labels[i], cmd)
        btn.opts.position = "center"
        btn.opts.width = btn_width
        table.insert(recent.val, btn)
      end
    end

    populate_recent()

    -- Re-flow when the alpha window changes size (terminal resize OR a split like
    -- the Claude panel opening/closing beside it), so the path truncation tracks
    -- the new width. We must NOT guard on the *current* buffer being alpha: when
    -- the Claude panel opens, focus moves to the PANEL, so the resize event fires
    -- with a non-alpha current buffer. Instead, act whenever an alpha window is
    -- still displayed anywhere. (alpha's own resize handler redraws too, but it
    -- re-renders the STATIC button labels — only populate_recent() re-truncates.)
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "WinClosed", "WinNew" }, {
      group = vim.api.nvim_create_augroup("AlphaRecentReflow", { clear = true }),
      callback = function()
        local has_alpha = false
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "alpha" then
            has_alpha = true
            break
          end
        end
        if not has_alpha then
          return
        end
        -- Deferred so the split's final geometry has settled before we measure
        -- the alpha window width and rebuild. redraw() with no args resolves the
        -- live alpha state itself, so it works while focus is in the Claude panel.
        vim.schedule(function()
          populate_recent()
          pcall(function()
            require("alpha").redraw()
          end)
        end)
      end,
    })

    -- ────────────────────────────────────────────────────────────────────────────
    -- 4) PROJECTS SECTION
    -- TODO: add ~/dev directory with a list of 5 most recently opened projects
    -- ────────────────────────────────────────────────────────────────────────────

    -- ────────────────────────────────────────────────────────────────────────────
    -- 5) FOOTER
    -- ────────────────────────────────────────────────────────────────────────────
    local avalanche_logo = {
      "         ++         ",
      "        ++++        ",
      "       ++++  +      ",
      "      ++++  +++     ",
      "     ++++  +++++    ",
    }

    local buidl_txt = {
      " ██████╗ ██╗   ██╗██╗██████╗ ██╗          ██████╗ ███╗   ██╗    ",
      " ██╔══██╗██║   ██║██║██╔══██╗██║         ██╔═══██╗████╗  ██║    ",
      " ██████╔╝██║   ██║██║██║  ██║██║         ██║   ██║██╔██╗ ██║    ",
      " ██╔══██╗██║   ██║██║██║  ██║██║         ██║   ██║██║╚██╗██║    ",
      " ██████╔╝╚██████╔╝██║██████╔╝███████╗    ╚██████╔╝██║ ╚████║    ",
    }

    local footer = {}

    for i = 1, #buidl_txt do
      footer[i] = buidl_txt[i] .. "" .. avalanche_logo[i]
    end

    -- Let alpha center the footer. alpha's align_center uses strdisplaywidth
    -- (longest_line, alpha.lua) and applies ONE shared left-offset to every row
    -- in the block, so multi-byte block glyphs center correctly AND uniformly —
    -- it re-runs on each redraw (recomputing the live window width), so it tracks
    -- the alpha window narrowing when the Claude panel opens. (An earlier manual
    -- pre-pad per line — on the false premise that alpha centers by byte count —
    -- gave each row a different offset → crooked footer once the panel narrowed
    -- the window.)
    dashboard.section.footer.val = footer
    dashboard.section.footer.opts = { position = "center" }

    -- custom layout: header → buttons → recent → footer
    dashboard.config.layout = {
      { type = "padding", val = 2 },
      dashboard.section.header,
      { type = "padding", val = 2 },
      keymaps,
      { type = "padding", val = 1 },
      recent,
      { type = "padding", val = 1 },
      dashboard.section.footer,
    }

    -- Send config to alpha
    alpha.setup(dashboard.config)

    -- Disable folding on alpha buffer
    vim.cmd([[autocmd FileType alpha setlocal nofoldenable]])
  end,
}
