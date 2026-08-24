-- nvim-tree config & first-open toggle
return {
	"nvim-tree/nvim-tree.lua",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	keys = {
		{
			"<C-s>",
			function()
				require("utils.tree_toggle").toggle_at_cwd()
			end,
			desc = "Toggle File Tree at project cwd",
		},
	},
	config = function()
		local nvim_tree = require("nvim-tree")

		nvim_tree.setup({
			view = { side = "left", width = 35 },
			-- Keep the tree root following :cd so it shows the project the dock picker
			-- opened (e.g. ~/dev/kos), not Neovim's startup cwd (~/dev).
			sync_root_with_cwd = true,
			respect_buf_cwd = true,
			update_focused_file = { enable = true, update_root = true },
			renderer = {
				indent_markers = {
					enable = true,
				},
				icons = {
					glyphs = {
						folder = {
							arrow_closed = "", -- arrow when folder is closed
							arrow_open = "", -- arrow when folder is open
						},
					},
				},
			},
		})
	end,
}
