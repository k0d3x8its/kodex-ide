-- lua/plugins/dock.lua
-- Single VimEnter hook for all dock-launch flows
-- (.work/archive/legacy-findings.md § A2).
--
-- Why a dedicated file?
--   Both opencode.lua and claude.lua plugin specs needed VimEnter to trigger the
--   project picker on dock launch. Two VimEnter hooks on the same lazy.nvim plugin
--   (even with once=true) both fire — the picker opens twice. Consolidating here
--   lets each panel spec stay ignorant of the other, with a single dispatch point
--   that checks which launcher env var is set.
--
-- Anchor: nvim-tree/nvim-tree.lua — already a dep, loads before VimEnter fires.
-- lazy.nvim merges specs for the same plugin; nvim-tree.lua's own spec owns
-- opts/config, so we only add init here to avoid overriding its setup.

return {
  "nvim-tree/nvim-tree.lua",

  init = function()
    -- ONE VimEnter, once=true — fires for KODEX_IDE (OpenCode dock) or
    -- KODEX_CLAUDE (Claude dock). The project picker handles which panel to open
    -- based on the env var (branched in project_picker.lua open_workspace).
    -- 100 ms defer: lets alpha + auto-session finish rendering before the picker
    -- overlay appears (matches the original defer in opencode.lua).
    vim.api.nvim_create_autocmd("VimEnter", {
      once     = true,
      callback = function()
        if vim.env.KODEX_IDE == "1" or vim.env.KODEX_CLAUDE == "1" then
          vim.defer_fn(function()
            require("utils.project_picker").pick()
          end, 100)
        end
      end,
    })
  end,
}
