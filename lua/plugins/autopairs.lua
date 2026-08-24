-- Auto-close brackets & quotes

---@diagnostic disable: undefined-field
-- NOTE: this tells the Lua language server to ignore "undefined-field" errors in this file.
--       Lua language server is not aware of the "cmp.event:on" API; it thinks "event" has no field.

return {
	"windwp/nvim-autopairs",
	event = "InsertEnter",
	dependencies = {
		"hrsh7th/nvim-cmp",
	},
	config = function()
		local autopairs = require("nvim-autopairs")

		autopairs.setup({
			check_ts = true,
		})

		local cmp_autopairs = require("nvim-autopairs.completion.cmp")

		local cmp = require("cmp")

		cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
	end,
}
