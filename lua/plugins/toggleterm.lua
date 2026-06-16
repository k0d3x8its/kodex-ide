return {
  "akinsho/toggleterm.nvim",
  version = "*",
  keys = {
    {
      "<C-x>",
      function()
        require("utils.term_toggle").toggle_dev()
      end,
      -- `t` matters: when focus is inside the OpenCode TUI you're in terminal
      -- mode, where a normal-mode-only bind never fires — so <C-x> fell through
      -- to OpenCode and did nothing. Binding `t` lets you summon the dev
      -- terminal from inside any terminal panel.
      mode = { "n", "t" },
      desc = "Toggle Dev Terminal",
    },
  },
  cmd = { "ToggleTerm", "ToggleTermToggleAll", "TermExec" },

  config = function()
    local toggleterm = require("toggleterm")

    -- NOTE: no `open_mapping`. It installs a global <C-x> bound to
    -- `<count>ToggleTerm` (smart_toggle), which CLOSES any open terminal when
    -- pressed — so with OpenCode open, <C-x> closed OpenCode instead of opening
    -- the dev terminal. <C-x> is owned solely by the lazy `keys` spec above,
    -- which routes to term_toggle.toggle_dev (the intended dev terminal).
    toggleterm.setup {
      direction       = "horizontal",
      size            = 15,
      start_in_insert = true,
      close_on_exit   = false,
    }
  end,
}
