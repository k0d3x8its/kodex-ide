-- Treesitter parser installation & setup
return {
	"nvim-treesitter/nvim-treesitter",
	branch = "master",
	build = ":TSUpdate",
	event = { "BufReadPre", "BufNewFile" },

	config = function()
		local treesitter = require("nvim-treesitter.configs")

		treesitter.setup({
			ensure_installed = {
				"python",
				"c",
				"cpp",
				"javascript",
				"typescript",
				"tsx",
				"html",
				"css",
				"solidity",
				"lua",
				"markdown",
				"markdown_inline",
				"bash",
				"yaml",
				"regex",
			},
			highlight = { enable = true },
			indent = { enable = true },
		})
	end,
}
