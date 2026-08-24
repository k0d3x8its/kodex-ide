return {
  "rmagatti/auto-session",
  lazy = false,

  config = function()
    local auto_session = require("auto-session")

    auto_session.setup({

      auto_restore_enabled = false,
      auto_save_enabled = true,
      auto_session_suppress_dirs = { "~/", "~/pictures/", "~/Downloads/", "/" },

      -- Purge terminal buffers before the session file is written.
      -- toggle_all(true) closes terminal windows; the second cmd force-wipes the
      -- buffers. Both steps are required: close() only shuts the window, leaving
      -- the buffer listed — mksession then writes it into the session file. On
      -- restore, toggleterm tries to reopen the saved terminal but the
      -- reconstructed object has direction=nil, which hits terminal.lua:466.
      -- pre_save_cmds fire at VimLeavePre (exit), so tearing panels down here is
      -- harmless — nvim is quitting.
      pre_save_cmds = {
        "lua require('toggleterm').toggle_all(true)",
        "lua for _,b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].buftype=='terminal' then pcall(vim.api.nvim_buf_delete,b,{force=true}) end end",
        -- Purge the Claude panel before the session is written. sessionoptions
        -- carries `localoptions` (core/options.lua), so mksession serialises each
        -- window's `setlocal` values — including the panel window's `nonumber`
        -- (set window-local in open_panel_window). Left in the session, that
        -- nonumber replays onto a restored FILE window on the next launch and the
        -- editor loses its line numbers. Closing the panel window + wiping its
        -- scratch buffer here means only real editor windows (which keep the
        -- global number=true) reach mksession, so nothing turns numbers off.
        "lua require('utils.claude').close_panel()",
      },
    })

    -- Guard: avoid E517 when there are no listed buffers before restore
    vim.api.nvim_create_autocmd("User", {
      pattern = "AutoSessionRestorePre",
      callback = function()
        local listed_buffer_exists = false

        for _, buffer_handle in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buffer_handle].buflisted then
            listed_buffer_exists = true
            break
          end
        end

        if listed_buffer_exists then
          pcall(vim.cmd, "silent! %bwipeout!")
        end
      end,
    })

    local keymap = vim.keymap

    -- restore last workspace session for current directory
    keymap.set("n", "<leader>wr", "<cmd>SessionRestore<CR>", { desc = "Restore session for cwd" })

    -- save workspace session for current working directory
    keymap.set("n", "<leader>ws", "<cmd>SessionSave<CR>", { desc = "Save session for auto session root dir" })
  end,
}
