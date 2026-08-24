-- autocommands & helper functions
local mod = {}

-- Treat Arduino .ino files as C++ for Treesitter & ALE
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
	pattern = "*.ino",
	callback = function()
		vim.bo.filetype = "cpp"
	end,
})

-- Prompt & rename current tab (used by Ctrl+k)
function mod.rename_current_tab()
	local name = vim.fn.input("Tab name: ")
	if name ~= "" then
		vim.cmd("file " .. name)
	end
end

return mod
