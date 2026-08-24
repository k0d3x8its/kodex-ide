-- lua/utils/config_tree_toggle.lua
local mod = {}

--- Toggle nvim-tree rooted at NVIM config directory
function mod.toggle_at_config()
	-- change cwd to ~/.config/nvim
	vim.cmd("lcd " .. vim.fn.stdpath("config"))
	-- toggle the tree
	require("nvim-tree.api").tree.toggle()
end

return mod
