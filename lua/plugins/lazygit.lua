-- ~/.config/nvim/lua/plugins/lazygit.lua
return {
	"kdheepak/lazygit.nvim",
	event = "InsertEnter",

	dependencies = { "nvim-lua/plenary.nvim" },

	config = function()
		-- Map <leader>gg to open LazyGit
		vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<CR>", {
			desc = " Open LazyGit",
			noremap = true,
			silent = true,
		})
	end,
}
