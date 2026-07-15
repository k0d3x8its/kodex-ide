-- 1️⃣ Bootstrap lazy.nvim
local fn = vim.fn
local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

-- 2️⃣ Python provider
local python3_host_prog = vim.fn.stdpath("config") .. "/venv/bin/python"
if vim.fn.executable(python3_host_prog) == 1 then
	vim.g.python3_host_prog = python3_host_prog
end

-- disabled Perl and Ruby
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0

-- 3️⃣ Claude event log — per-launch timestamped JSONL in stdpath("log").
-- Captures every raw stream-json line before decode (see utils/claude/process.lua).
-- Manual override still wins: KODEX_CLAUDE_EVENTLOG=/tmp/foo.jsonl nvim
-- stdpath("log") = ~/.local/state/nvim — always exists, no mkdir needed.
local _elog_dir = vim.fn.stdpath("log")
local _elog_ts  = os.date("%Y%m%d-%H%M%S")
vim.env.KODEX_CLAUDE_EVENTLOG = vim.env.KODEX_CLAUDE_EVENTLOG
  or (_elog_dir .. "/claude-events-" .. _elog_ts .. ".jsonl")

-- 4️⃣ Hand off to unit.lua
require("unit")
