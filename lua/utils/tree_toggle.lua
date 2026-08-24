-- lua/utils/tree_toggle.lua

local mod = {}
local api = require("nvim-tree.api")

-- Toggle the file tree, always (re)opening it rooted at the current working
-- directory — which is the project the user opened from the dock picker. Opening
-- at cwd (not a fixed ~/dev) means the tree shows the active project's files.
function mod.toggle_at_cwd()
	if api.tree.is_visible() then
		api.tree.close()
	else
		api.tree.open()
		-- Force the root to cwd: tree.open alone reuses the root it was first
		-- initialised with (Neovim's startup cwd), which may be a parent dir.
		api.tree.change_root(vim.fn.getcwd())
	end
end

return mod
