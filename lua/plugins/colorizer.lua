return {
	"NvChad/nvim-colorizer.lua",
	event = { "BufReadPre", "BufNewFile" },

	config = function()
		local colorizer = require("colorizer")

		colorizer.setup({
			filetypes = { "*" }, -- Highlight all filetypes
			user_default_options = {
				names = false,
				RRGGBBAA = true,
				rgb_fn = true,
				hsl_fn = true,
			},
		})
	end,
}
