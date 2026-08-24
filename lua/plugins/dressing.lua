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
					-- Within that theme table, width/height must ALSO nest under
					-- layout_config -- get_dropdown() itself deep-merges its opts
					-- arg at the TOP level (siblings of layout_config), and the
					-- "center" layout strategy only ever reads layout_config.width/
					-- layout_config.height. A top-level width/height is accepted
					-- but silently ignored -- the dropdown stays at get_dropdown's
					-- own default size (min(max_columns,80) / min(max_lines,15)).
					return {
						telescope = themes.get_dropdown({
							layout_config = { width = 0.4, height = 0.35 },
						}),
					}
				end
			end,
		},
	},
}
