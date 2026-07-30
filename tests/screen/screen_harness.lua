-- [DEBUG-b7c1] Screen harness for the subagent drill-in overlap bug.
--
-- Why this exists: three prior investigation passes logged window GEOMETRY and all
-- came back internally consistent, while the user kept seeing an overlap. Geometry
-- logs cannot see paint results. This harness runs a child nvim inside a :terminal
-- buffer, so the terminal buffer holds the COMPOSITED screen (floats included) as
-- plain text that can be read back and asserted on -- headless, deterministic.
--
-- Usage:
--   CHILD_SCRIPT=<path> nvim --headless -u NONE -l screen_harness.lua

local SCREEN_ROWS = tonumber(vim.env.SCREEN_ROWS or "40")
local SCREEN_COLS = tonumber(vim.env.SCREEN_COLS or "120")
local RENDER_TIMEOUT_MS = 8000
local SENTINEL = "SCREENREADY"

local child_script = vim.env.CHILD_SCRIPT
if not child_script or child_script == "" then
	io.stderr:write("screen_harness: CHILD_SCRIPT not set\n")
	vim.cmd("cq")
end

vim.o.lines = SCREEN_ROWS
vim.o.columns = SCREEN_COLS

local term_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(term_buf)

-- The child must start a REAL TUI in the pty (so floats composite), hence `-c luafile`
-- rather than `-l`, which runs headless and never paints.
local job_id = vim.fn.jobstart({ "nvim", "--clean", "-c", "luafile " .. child_script }, { term = true })
if job_id <= 0 then
	io.stderr:write("screen_harness: jobstart failed for child " .. child_script .. "\n")
	vim.cmd("cq")
end

local function screen_lines()
	return vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
end

local function screen_contains(needle)
	for _, line in ipairs(screen_lines()) do
		if line:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local rendered = vim.wait(RENDER_TIMEOUT_MS, function()
	return screen_contains(SENTINEL)
end, 100)

if not rendered then
	io.stderr:write(
		"screen_harness: child never rendered sentinel "
			.. SENTINEL
			.. " within "
			.. RENDER_TIMEOUT_MS
			.. "ms; dumping what it did render\n"
	)
end

io.stdout:write("=== [DEBUG-b7c1] composited screen " .. SCREEN_COLS .. "x" .. SCREEN_ROWS .. " ===\n")
for row_index, line in ipairs(screen_lines()) do
	io.stdout:write(string.format("%02d|%s|\n", row_index, line))
end

pcall(vim.fn.jobstop, job_id)
vim.cmd(rendered and "qa!" or "cq")
