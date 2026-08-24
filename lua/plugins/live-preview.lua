return {
	"brianhuster/live-preview.nvim",
	ft = { "markdown", "asciidoc", "html", "svg" },
	dependencies = { "nvim-telescope/telescope.nvim" },

	config = function()
		local ok, preview = pcall(require, "livepreview.config")

		-- Guard: plugin requires Neovim >= 0.10.1
		if vim.fn.has("nvim-0.10.1") == 0 then
			vim.notify("live-preview.nvim requires Neovim >= 0.10.1", vim.log.levels.ERROR)
			return
		end

		-- Load the config module safely
		if not ok or type(preview) ~= "table" then
			vim.notify("live-preview: failed to load livepreview.config", vim.log.levels.ERROR)
			return
		end

		preview.set({
			picker = "telescope",
			address = "127.0.0.1",
			port = 9000,
			browser = "default",
			dynamic_root = true,
			sync_scroll = true,
		})

		vim.o.autowriteall = true

		local aug = vim.api.nvim_create_augroup("LivePreviewHTMLAutosave", { clear = true })
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
			group = aug,
			pattern = "*.html",
			callback = function(args)
				if vim.api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].modified then
					pcall(vim.cmd, "silent! update")
				end
			end,
			desc = "Auto-save HTML so live-preview refreshes",
		})
	end,
}
