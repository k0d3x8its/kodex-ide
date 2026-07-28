-- ALE linting & fixing configuration

return {
	"dense-analysis/ale",

	ft = {
		"python",
		"c",
		"cpp",
		"javascript",
		"typescript",
		"javascriptreact",
		"typescriptreact",
		"sh",
		"json",
		"lua",
		"html",
		"css",
		"solidity",
		"yaml",
		"swift",
	},

	config = function()
		vim.g.ale_linters = {
			python = { "flake8", "mypy" },
			c = { "gcc", "cppcheck", "arduino" },
			cpp = { "g++", "cppcheck", "arduino" },
			javascript = { "eslint" },
			typescript = { "eslint" },
			javascriptreact = { "eslint" },
			typescriptreact = { "eslint" },
			sh = { "shellcheck" },
			json = { "jq" },
			lua = { "luacheck" },
			html = { "htmllint" },
			css = { "stylelint" },
			solidity = { "solhint" },
			markdown = { "markdownlint" },
			yaml = { "yamllint" },
			swift = { "swiftlint" },
		}

		vim.g.ale_fix_on_save = 1

		vim.g.ale_fixers = {
			["*"] = { "remove_trailing_lines", "trim_whitespace" },
			python = { "autopep8" },
			lua = { "stylua" },
			sh = { "shfmt" },
			javascript = { "prettier" },
			typescript = { "prettier" },
			javascriptreact = { "prettier" },
			typescriptreact = { "prettier" },
			html = { "prettier" },
			css = { "prettier" },
			json = { "prettier" },
			markdown = { "prettier" },
			yaml = { "prettier" },
			swift = { "appleswiftformat" }, -- official swift-format; matches SWIFT.md's
			-- stated priority (swift-format first, third-party `swiftformat` fixer
			-- second if a project's own convention prefers it)
		}

		vim.g.ale_lint_on_text_changed = "always"
		vim.g.ale_lint_on_save = 1

		vim.g.ale_arduino_executable = "arduino-cli"
		vim.g.ale_arduino_fqbn = "arduino:avr:uno"

		-- solhint/htmllint auto-discover global fallback configs
		-- unreliably (confirmed: same file works via explicit path, silently
		-- no-ops via implicit search) — pass the path explicitly instead of
		-- relying on their config discovery. Project-local configs should be
		-- passed the same way if a project needs to override these.
		vim.g.ale_solidity_solhint_options = "--config " .. vim.fn.expand("~/.solhint.json")
		vim.g.ale_html_htmllint_options = "--rc " .. vim.fn.expand("~/.htmllintrc")
	end,
}
