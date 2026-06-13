-- OpenCode panel — right vertical split AI pair (findings.md Q1–Q14)
-- Spec fragment on toggleterm: reuses the existing dep, adds only keymaps.
-- lazy.nvim merges this with lua/plugins/toggleterm.lua.
return {
  "akinsho/toggleterm.nvim",

  init = function()
    -- cheap at startup: utils/opencode requires toggleterm only on first toggle
    require("utils.opencode").setup({ width_pct = 0.40 })

    -- Dock-launch flow: KODEX_IDE=1 is set by ~/.local/bin/kodex-ide.
    -- VimEnter fires after all plugins init; the 100 ms defer lets alpha and
    -- auto-session finish rendering before the project picker overlay appears.
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        if vim.env.KODEX_IDE == "1" then
          vim.defer_fn(function()
            require("utils.project_picker").pick()
          end, 100)
        end
      end,
    })
  end,

  keys = {
    {
      "<leader>oc",
      function()
        require("utils.opencode").toggle()
      end,
      desc = "OpenCode: toggle panel",
    },
    {
      "<leader>or",
      function()
        require("utils.opencode").reset()
      end,
      desc = "OpenCode: reset session",
    },
    {
      -- visual-mode only: yank selection, prompt for a question, send both to
      -- the OpenCode panel. Bound to <leader>oq (o=opencode, q=question) —
      -- free in the <leader>o* namespace and mnemonic for "ask".
      "<leader>oq",
      function()
        require("utils.opencode").ask_selection()
      end,
      mode = "v",
      desc = "OpenCode: ask about selection",
    },
  },
}
