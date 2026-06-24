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
    -- 3) RECENT FILES SECTION — buttons auto-width to the longest path so the
    --    "SPC N" shortcut extends past the path instead of overlapping it
    -- ────────────────────────────────────────────────────────────────────────────
    local recent = { type = "group", val = {}, opts = { spacing = 1 } }

    table.insert(recent.val, {
      type = "text",
      val = "  Recent Files",
      opts = { hl = "Title", position = "center" },
    })

    -- Keep only real files
    local files = {}
    for _, f in ipairs(vim.v.oldfiles) do
      if #files >= 5 then
        break
      end
      if f ~= "" and vim.fn.filereadable(f) == 1 then
        table.insert(files, f)
      end
    end

    -- Build each button's full label (icon + ~-relative path) up front so the
    -- shared width can be sized from real label display widths below.
    local GAP, SHORTCUT_W = 4, 5 -- "SPC 5" = 5 cells; 4 blank cells of slack
    local labels = {}
    for _, file in ipairs(files) do
      local display = vim.fn.fnamemodify(file, ":~")
      local ext = vim.fn.fnamemodify(file, ":e")
      local icon = devicons.get_icon(file, ext, { default = true }) or " "
      table.insert(labels, icon .. "  " .. display)
    end
    -- Size the shared button width from the ACTUAL label display widths, not a
    -- guessed path-length + icon fudge: a nerd-font icon can be 2 cells and the
    -- widest LABEL is not always the longest PATH, which let "SPC N" bleed in.
    local btn_width = require("utils.alpha_layout").button_width(labels, SHORTCUT_W, GAP)

    for i, file in ipairs(files) do
      -- fnameescape = handles spaces, #, etc.
      local cmd = "<cmd>e " .. vim.fn.fnameescape(file) .. "<CR>"

      local btn = dashboard.button("SPC " .. i, labels[i], cmd)
      btn.opts.position = "center"
      btn.opts.width = btn_width
      table.insert(recent.val, btn)
    end

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
