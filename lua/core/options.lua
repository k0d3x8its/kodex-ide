-- UI & editing settings
local opt = vim.opt -- shorthand for vim.opt[...]

-- sessions (needed for auto-session to restore highlights/locals)
if not vim.tbl_contains(opt.sessionoptions:get(), "localoptions") then
	opt.sessionoptions:append("localoptions")
end

-- statusline & tabs
opt.laststatus = 2 -- always show statusline
opt.showtabline = 2 -- always show tabline

-- line numbers & cursor
opt.number = true -- show absolute line numbers
opt.cursorline = true -- highlight current line

-- tabs & indentation
opt.tabstop = 2 -- a <Tab> equals 2 spaces
opt.shiftwidth = 2 -- auto-indent to 2 spaces
opt.softtabstop = 2 -- make tab key insert 2 spaces
opt.expandtab = true -- convert tabs to spaces
opt.smartindent = true -- smart auto-indent
opt.autoindent = true -- indent new lines like previous

-- wrapping & formatting
opt.wrap = true -- wrap long lines
opt.linebreak = true -- wrap at word boundaries
opt.breakindent = true -- maintain indent on wrapped lines
opt.showbreak = "↪ " -- prepend continue lines with ↪
opt.textwidth = 0 -- disable hard wrapping
opt.formatoptions:remove("t") -- don't auto-wrap text
opt.splitright = true -- vertical split placed to the right

-- Bare `nvim` (no file args) lands in ~/dev so the dashboard/project picker has a
-- sensible home. BUT only when launched from $HOME (the "just opened a terminal"
-- case) — if the user deliberately `cd`'d into a project first, respect that cwd so
-- the Claude/OpenCode panel anchors to the real project (banner, run dir, and the
-- fable-mode badge all key off getcwd()). Without the $HOME guard, `cd ~/dev/proj &&
-- nvim` was forced back to ~/dev. Dock launches are unaffected: they set KODEX_IDE=1
-- and the project picker cd's to the chosen project regardless.
vim.api.nvim_create_autocmd("VimEnter", {
	callback = function()
		if vim.fn.argc() == 0 and vim.fn.getcwd() == vim.fn.expand("$HOME") then
			vim.cmd("cd ~/dev")
		end
	end,
})
