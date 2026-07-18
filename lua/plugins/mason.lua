-- Mason installer for LSP servers
return {
	"williamboman/mason.nvim",
	dependencies = {
		"williamboman/mason-lspconfig.nvim",
	},

	lazy = false,

	config = function()
		local mason = require("mason")
		local mason_lspconfig = require("mason-lspconfig")

		mason.setup({
			ui = {
				package_installed = " ",
				package_pending = " ",
				package_uninstalled = " ",
			},
		})

		mason_lspconfig.setup({
			ensure_installed = {
				"pyright",
				"ts_ls",
				"html",
				"cssls",
				"lua_ls",
				"solidity",
				"bashls",
				"jsonls",
				"arduino_language_server",
				"yamlls",
				"clangd",
			},
			automatic_installation = true,
			automatic_enable = false,
		})
	end,
}
