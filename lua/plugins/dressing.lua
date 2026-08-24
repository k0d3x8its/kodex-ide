-- dressing.nvim: nicer vim.ui.select & vim.ui.input
return {
	"stevearc/dressing.nvim",
	event = "VeryLazy",
	opts = {
		select = {
			-- Global backend is telescope (project picker, PlatformIO menu, etc.),
			-- but its dropdown theme is oversized for a short 8-item list like the
			-- Claude model picker. Shrink just that kind to half the default
			-- dropdown size instead of resizing telescope for every other caller.
			get_config = function(opts)
				if opts.kind == "claude_model" then
					local themes = require("telescope.themes")
					-- get_config's return is deep-merged into the `select` config
					-- table (see dressing/config.lua), so the telescope theme must
					-- nest under `telescope`, not be returned at the top level.
					return { telescope = themes.get_dropdown({ width = 0.4, height = 0.35 }) }
				end
			end,
		},
	},
}
