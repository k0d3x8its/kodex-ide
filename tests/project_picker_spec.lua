-- tests/project_picker_spec.lua
-- Covers project_picker.lua's panel-choice routing: chosen_panel + open_panel
-- are the branch point that decides which AI panel a launch opens, and
-- resolve_chosen_panel is the Esc-dismiss default logic. Run: nvim --headless
-- -u NONE --cmd "set runtimepath+=." -c "luafile tests/project_picker_spec.lua"

local H = dofile("tests/helpers.lua")

local opened = {}
package.loaded["utils.claude"] = {
	open = function(proj)
		table.insert(opened, { panel = "claude", proj = proj })
	end,
}
package.loaded["utils.opencode"] = {
	open = function()
		table.insert(opened, { panel = "opencode" })
	end,
}

local project_picker = require("utils.project_picker")

-- ---------------------------------------------------- resolve_chosen_panel

H.check(
	'resolve_chosen_panel("Claude Code") -> "claude"',
	project_picker._resolve_chosen_panel("Claude Code") == "claude"
)
H.check(
	'resolve_chosen_panel("OpenCode") -> "opencode" (explicit non-Claude selection)',
	project_picker._resolve_chosen_panel("OpenCode") == "opencode"
)
H.check(
	'resolve_chosen_panel(nil) -> "opencode" (Esc dismiss default)',
	project_picker._resolve_chosen_panel(nil) == "opencode"
)

-- ---------------------------------------------------- open_panel routing

opened = {}
project_picker._set_chosen_panel("claude")
project_picker._open_panel("/home/k0d3x/dev/kodex-ide")
H.check(
	"open_panel routes to utils.claude.open when chosen_panel is claude",
	#opened == 1 and opened[1].panel == "claude" and opened[1].proj == "/home/k0d3x/dev/kodex-ide",
	vim.inspect(opened)
)

opened = {}
project_picker._set_chosen_panel("opencode")
project_picker._open_panel("/home/k0d3x/dev/kodex-ide")
H.check(
	"open_panel routes to utils.opencode.open when chosen_panel is opencode",
	#opened == 1 and opened[1].panel == "opencode",
	vim.inspect(opened)
)

-- ---------------------------------------------------- finish() end-to-end wiring
-- Drives the real vim.ui.select callback finish() wires up, proving the
-- panel-choice selection actually reaches chosen_panel and open_panel --
-- not just that each half works given a value handed to it directly.

-- A real, named, non-empty buffer in the current tabpage puts open_workspace
-- on its "resumed session" branch (an already-open file window), which skips
-- nvim-tree.api entirely -- keeps this test from needing to stub it.
local file_window_seq = 0
local function with_file_window()
	file_window_seq = file_window_seq + 1
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, "/tmp/project_picker_spec_test_" .. file_window_seq .. ".lua")
	vim.api.nvim_set_current_buf(buf)
end

local function stub_panel_select(answer)
	vim.ui.select = function(_, _, cb)
		cb(answer)
	end
end

opened = {}
with_file_window()
stub_panel_select("Claude Code")
project_picker._finish("/home/k0d3x/dev/kodex-ide")
vim.wait(1000, function()
	return #opened > 0
end)
H.check(
	'finish("Claude Code") wires the selection through to utils.claude.open',
	#opened == 1 and opened[1].panel == "claude",
	vim.inspect(opened)
)

opened = {}
with_file_window()
stub_panel_select(nil) -- Esc dismiss
project_picker._finish("/home/k0d3x/dev/kodex-ide")
vim.wait(1000, function()
	return #opened > 0
end)
H.check(
	"finish(nil) (Esc dismiss) wires the default through to utils.opencode.open",
	#opened == 1 and opened[1].panel == "opencode",
	vim.inspect(opened)
)

H.summary("project_picker")
