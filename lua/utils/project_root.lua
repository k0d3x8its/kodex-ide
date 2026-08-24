-- lua/utils/project_root.lua

local mod = {}

-- Any one of these in a directory marks it as a project root (findings Q7)
local markers = { ".git", "package.json", "Cargo.toml", "go.mod", "platformio.ini" }

--- Detect project root by walking up from the current buffer's path.
--- Generic on purpose — reusable beyond opencode (not PIO-specific).
---@return string root absolute path
function mod.detect()
	-- Terminal/dashboard buffers have no file name; vim.fs.root then walks
	-- from cwd, which is the sensible anchor for those buffers anyway.
	local source = vim.api.nvim_buf_get_name(0)
	if source == "" then
		source = vim.fn.getcwd()
	end

	return vim.fs.root(source, markers) or vim.fn.getcwd()
end

return mod
