-- lua/utils/term_toggle.lua

local mod = {}
local Terminal = require("toggleterm.terminal").Terminal

local DEV_HEIGHT = 10

-- one persistent “dev” terminal
local dev_term = Terminal:new({
	cmd = vim.o.shell,
	dir = vim.fn.expand("~/dev"),
	direction = "horizontal",
	size = DEV_HEIGHT,
	start_in_insert = true,
	close_on_exit = false,
	hidden = true,
	-- Force the bottom edge on every open. Without this, opening the dev term
	-- while the OpenCode panel is up anchors the split to OpenCode's window and
	-- the terminal lands as a thin full-height column on the right. See
	-- utils.term_layout for the toggleterm grouping behaviour this works around.
	-- place_horizontal homes the strip under the editor window only, so it sits
	-- beside OpenCode (never below it) and never moves OpenCode's window.
	on_open = function()
		require("utils.term_layout").place_horizontal(DEV_HEIGHT)
	end,
})

--- Toggle the dev terminal
function mod.toggle_dev()
	dev_term:toggle()
end

return mod
