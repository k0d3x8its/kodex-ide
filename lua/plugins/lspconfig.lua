-- LSP server configuration
return {
	"neovim/nvim-lspconfig",
	event = { "BufReadPre", "BufNewFile" },
	dependencies = {
		"hrsh7th/cmp-nvim-lsp", -- for autocompletion capabilities
		{ "antosha417/nvim-lsp-file-operations", config = true }, -- file ops for LSP
		"b0o/SchemaStore.nvim", -- YAML/JSON schemas
	},

	config = function()
		-- import cmp-nvim-lsp plugin for enhanced completion capabilities
		local cmp_nvim_lsp = require("cmp_nvim_lsp")

		-- keymap options
		local capabilities = cmp_nvim_lsp.default_capabilities()

		-- filetypes where LSP should not format (ALE fixers already own these —
		-- see ale.lua's ale_fixers; letting LSP format too means two formatters
		-- fighting over the same file on save)
		local lsp_format_blocklist = {
			yaml = true,
			yml = true,
			python = true,
			lua = true,
			sh = true,
			javascript = true,
			typescript = true,
			javascriptreact = true,
			typescriptreact = true,
			html = true,
			css = true,
			json = true,
			markdown = true,
			swift = true,
		}

		-- Created once, outside on_attach — on_attach fires per buffer, and
		-- clear=true inside it would wipe every earlier buffer's format-on-save
		-- autocmd each time a new buffer attaches, leaving only the
		-- last-attached buffer formatting on save.
		local format_augroup = vim.api.nvim_create_augroup("LspFormatting", { clear = true })

		-- on_attach function for keymaps and formatting
		local on_attach = function(client, bufnr)
			local nmap = function(keys, fn, desc)
				vim.keymap.set("n", keys, fn, { buffer = bufnr, desc = desc and "LSP: " .. desc })
			end

			-- keymaps
			nmap("gd", vim.lsp.buf.definition, "Go to Definition")
			nmap("K", vim.lsp.buf.hover, "Hover Docs")
			nmap("gi", vim.lsp.buf.implementation, "Go to Implementation")
			nmap("<leader>rn", vim.lsp.buf.rename, "Rename Symbol")
			nmap("gr", vim.lsp.buf.references, "Find References")
			nmap("<leader>ld", vim.diagnostic.open_float, "Line Diagnostic")

			-- format on save (skip filetypes handled by ALE)
			local ft = vim.bo[bufnr].filetype
			if
				not lsp_format_blocklist[ft]
				and client.server_capabilities
				and client.server_capabilities.documentFormattingProvider
			then
				vim.api.nvim_create_autocmd("BufWritePre", {
					group = format_augroup,
					buffer = bufnr,
					callback = function()
						vim.lsp.buf.format({ bufnr = bufnr })
					end,
				})
			end
		end

		vim.diagnostic.config({
			virtual_text = true, -- show inline error text
			underline = true, -- underline errors in the buffer
			signs = {
				-- define one gutter icon per severity
				text = {
					[vim.diagnostic.severity.ERROR] = " ",
					[vim.diagnostic.severity.WARN] = " ",
					[vim.diagnostic.severity.INFO] = " ",
					[vim.diagnostic.severity.HINT] = " ",
				},
				-- optionally tweak the highlight groups (uses built-in groups by default)
				texthl = {
					[vim.diagnostic.severity.ERROR] = "DiagnosticSignError",
					[vim.diagnostic.severity.WARN] = "DiagnosticSignWarn",
					[vim.diagnostic.severity.INFO] = "DiagnosticSignInfo",
					[vim.diagnostic.severity.HINT] = "DiagnosticSignHint",
				},
			},
		})

		-- list all servers you installed via Mason (basic setup only)
		local servers = {
			"cssls",
			"ts_ls",
			"solidity_ls",
			"pyright",
			"clangd",
			"arduino_language_server",
			"bashls",
			"jsonls",
		}

		for _, server in ipairs(servers) do
			vim.lsp.config(server, {
				on_attach = on_attach,
				capabilities = capabilities,
			})
			vim.lsp.enable(server)
		end

		vim.lsp.config("clangd", {
			capabilities = capabilities,
			on_attach = on_attach,
			filetypes = { "c", "cpp", "objc", "objcpp", "arduino" },
			on_new_config = function(new_config, new_root_dir)
				local compile_commands_path =
					vim.fs.find("compile_commands.json", { path = new_root_dir, upward = true })[1]

				if compile_commands_path then
					local compile_commands_dir = vim.fs.dirname(compile_commands_path)
					new_config.cmd = { "clangd", "--compile-commands-dir=" .. compile_commands_dir }
				end
			end,
		})

		-- configure lua_ls server (with diagnostics fix for `vim`)
		vim.lsp.config("lua_ls", {
			capabilities = capabilities,
			on_attach = on_attach,
			settings = {
				Lua = {
					diagnostics = {
						globals = { "vim" }, -- fixes: undefined global `vim`
					},
				},
			},
		})
		vim.lsp.enable("lua_ls")

		-- YAML language server (disable LSP formatting; ALE/Prettier does it):
		local ok_schema, schemastore = pcall(require, "schemastore")
		vim.lsp.config("yamlls", {
			capabilities = capabilities,
			on_attach = on_attach,
			settings = {
				yaml = {
					validate = true,
					format = { enable = false }, -- IMPORTANT: avoid double-formatting
					keyOrdering = false,
					schemaStore = { enable = false, url = "" }, -- use SchemaStore.nvim’s local index
					schemas = ok_schema and schemastore.yaml.schemas()
						or {
							["https://json.schemastore.org/github-workflow.json"] = "/.github/workflows/*.{yml,yaml}",
							["https://json.schemastore.org/github-action.json"] = "/.github/actions/*.{yml,yaml}",
							["https://json.schemastore.org/kubernetes.json"] = "/*.k8s.{yml,yaml}",
							["https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json"] = "docker-compose*.{yml,yaml}",
						},
				},
			},
		})
		vim.lsp.enable("yamlls")

		-- HTML language server, extended with htmx's hx-* attributes via
		-- custom data. vscode-html-language-server reads custom data paths
		-- from `initializationOptions.dataPaths`, not `settings.html.customData`
		-- (that settings key only exists client-side, in VS Code's own
		-- extension, which translates it into initializationOptions before
		-- ever talking to the server) — sending it as `settings` is a silent
		-- no-op over LSP.
		vim.lsp.config("html", {
			capabilities = capabilities,
			on_attach = on_attach,
			init_options = {
				dataPaths = {
					vim.fs.joinpath(vim.fn.stdpath("config"), "lua/data/htmx-custom-data.json"),
				},
			},
		})
		vim.lsp.enable("html")

		-- sourcekit-lsp ships bundled with the Swift toolchain, not via Mason —
		-- installing the toolchain (swift.org or Xcode) is a host-level
		-- prerequisite, not something this config can provision.
		--
		-- Scoped to `swift` only: the bundled config (nvim-lspconfig's
		-- lsp/sourcekit.lua) defaults filetypes to
		-- { swift, objc, objcpp, c, cpp } — same C/C++/objc filetypes clangd
		-- above already owns. Left at the default, both servers would attach
		-- to every C/C++ buffer, double-registering `on_attach`'s
		-- BufWritePre formatter (double-format on save, since neither `c`
		-- nor `cpp` is in lsp_format_blocklist).
		vim.lsp.config("sourcekit", {
			capabilities = capabilities,
			on_attach = on_attach,
			filetypes = { "swift" },
		})
		vim.lsp.enable("sourcekit")
	end,
}
