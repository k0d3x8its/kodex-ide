-- OpenCode panel — right vertical split AI pair (findings.md Q1–Q14)
-- Spec fragment on toggleterm: reuses the existing dep, adds only keymaps.
-- lazy.nvim merges this with lua/plugins/toggleterm.lua.
return {
  "akinsho/toggleterm.nvim",

  init = function()
    -- cheap at startup: utils/opencode requires toggleterm only on first toggle
    require("utils.opencode").setup({ width_pct = 0.40 })
    -- VimEnter dock-launch hook removed — dock.lua owns the single VimEnter
    -- for both KODEX_IDE and KODEX_CLAUDE launchers (FINDINGS.md § A2).
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
