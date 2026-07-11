return {
  "folke/noice.nvim",
  event = "VeryLazy",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "rcarriga/nvim-notify",
  },
  config = function()
    -- background_colour is required when the colorscheme has a transparent or
    -- unset Normal background; nvim-notify uses it as the 100%-transparency
    -- fallback colour when building notification highlight groups
    require("notify").setup({
      background_colour = "#000000",
    })
    vim.notify = require("notify")
    local noice = require("noice")

    noice.setup({
      lsp = {
        override = {
          ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
          ["vim.lsp.util.stylize_markdown"] = true,
          ["cmp.entry.get_documentation"] = true,
        },
      },
      presets = {
        bottom_search = true,
        command_palette = true,
        long_message_to_split = true,
      },
      views = {
        -- LSP progress ("Diagnosing…", workspace loading) renders in the mini
        -- view, whose default position is the SCREEN's bottom-right — inside the
        -- Claude panel (and on top of the Clawd pet's corner) whenever the panel
        -- is open. Pin it bottom-LEFT so it always lands over the editor side.
        mini = {
          position = { row = -1, col = 0 },
        },
      },
    })
  end,
}
