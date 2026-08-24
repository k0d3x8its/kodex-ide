-- core modules
require("core.options")
require("core.health_filter")
require("core.keymaps")
require("core.autocmds")

-- plugin loader
require("lazy").setup("plugins", {
	defaults = { lazy = true },
	install = { colorscheme = { "dracula" } },

	-- Silent background checks for updates
	checker = {
		enabled = true,
		notify = false, -- don't show a popup
		frequency = 3600, -- seconds (1h). Use 86400 for daily, etc.
	},
})
