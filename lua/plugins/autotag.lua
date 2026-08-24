-- lua/plugins/autotag.lua
return {
	"windwp/nvim-ts-autotag",
	dependencies = {
		"nvim-treesitter/nvim-treesitter",
	},
	event = { "BufReadPre", "BufNewFile" },

	config = function()
		local autotag = require("nvim-ts-autotag")

		autotag.setup({
			opts = {
				enable_close = true, -- auto-close tags when you type `>`
				enable_rename = true, -- rename paired tags together
				enable_close_on_slash = false, -- auto-close on typing `</`
			},
			-- NOTE: override indivual filetype configs --- example below
			-- per_filetype = { html = { enable_close = true } },
		})
	end,
}
