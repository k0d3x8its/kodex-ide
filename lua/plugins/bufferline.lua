return {
	"akinsho/bufferline.nvim",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	version = "*",
	event = "VimEnter",

	config = function()
		local bufferline = require("bufferline")

		bufferline.setup({
			options = {
				mode = "tabs",
				show_buffer_close_icons = true,
				show_close_icon = true,
				separator_style = "slant",
				-- In "tabs" mode each tab is labelled by the tabpage's active buffer.
				-- When that buffer is the OpenCode terminal the tab would read
				-- "opencode" — but the window statusline already shows that. Keep the
				-- tab showing the file the user is editing by substituting the name of
				-- a real file window living in the same tabpage.
				name_formatter = function(buf)
					if vim.bo[buf.bufnr].buftype ~= "terminal" then
						return nil -- non-terminal: let bufferline use its default name
					end
					-- buf.tabnr is the 1-based tabpage index (provided in tabs mode)
					local tabpage = vim.api.nvim_list_tabpages()[buf.tabnr]
					if not tabpage then
						return nil
					end
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
						local b = vim.api.nvim_win_get_buf(win)
						if vim.bo[b].buftype == "" then
							local n = vim.api.nvim_buf_get_name(b)
							if n ~= "" then
								return vim.fn.fnamemodify(n, ":t")
							end
						end
					end
					return nil -- no file window in this tab: fall back to "opencode"
				end,
			},
		})
	end,
}
