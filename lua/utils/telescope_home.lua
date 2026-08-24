-- lua/utils/telescope_home.lua

local mod = {}

function mod.find_files()
	require("telescope.builtin").find_files({ cwd = vim.env.HOME, hidden = true })
end

function mod.live_grep()
	require("telescope.builtin").live_grep({ cwd = vim.env.HOME, hidden = true })
end

return mod
