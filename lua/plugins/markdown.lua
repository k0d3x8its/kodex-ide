return {
	"tadmccorkle/markdown.nvim",
	ft = { "markdown", "mdx" },

	config = function()
		local markdown = require("markdown")

		markdown.setup()

		local grp = vim.api.nvim_create_augroup("MarkdownLintFix", { clear = true })

		vim.api.nvim_create_autocmd("BufWritePre", {
			group = grp,
			pattern = { "*.md", "*.mdx" },

			callback = function(args)
				local view = vim.fn.winsaveview()

				vim.api.nvim_buf_call(args.buf, function()
					vim.cmd([[%s/\s\+$//e]])
				end)

				vim.api.nvim_buf_call(args.buf, function()
					-- insert a blank line if a heading is immediately followed by text
					vim.cmd([[%s/^\(#\{1,6} .\+\)\n\(\S\)/\1\r\r\2/ge]])
					-- collapse 2+ blank lines after a heading to exactly one
					vim.cmd([[%s/^\(#\{1,6} .\+\)\n\{3,}/\1\r\r/ge]])
					-- delete whitespace-only "blank" lines so they count as empty
					vim.cmd([[%s/^\s\+$//e]])
				end)

				vim.bo[args.buf].fixol = true

				vim.fn.winsaveview(view)
			end,
			desc = "markdownlint quick fixes",
		})
	end,
}
