-- OpenCode panel — right vertical split AI pair (findings.md Q1–Q14)
-- Spec fragment on toggleterm: reuses the existing dep, adds only keymaps.
-- lazy.nvim merges this with lua/plugins/toggleterm.lua.
return {
  "akinsho/toggleterm.nvim",

  init = function()
    -- cheap at startup: utils/opencode requires toggleterm only on first toggle
    require("utils.opencode").setup({ width_pct = 0.40 })
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
  },
}
