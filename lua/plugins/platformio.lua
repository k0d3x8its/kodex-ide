-- lua/plugins/platformio.lua

return {
	"anurag3301/nvim-platformio.lua",
	-- Lazy-load by command so keymaps recognize them
	cmd = {
		"Pioinit",
		"Piorun",
		"Piocmdh",
		"Piocmdf",
		"Piolib",
		"Piomon",
		"Piodebug",
		"Piodb",
	},

	dependencies = {
		"akinsho/toggleterm.nvim",
		"nvim-telescope/telescope.nvim",
		"nvim-telescope/telescope-ui-select.nvim",
		"nvim-lua/plenary.nvim",
	},

	config = function()
		local platformio = require("platformio")

		platformio.setup({
			lsp = "clangd",
		})
	end,
}
