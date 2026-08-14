-- tests/claude_gate_perm_lines_spec.lua
-- Unit coverage for gate.lua's perm_path_ranges (ClaudeDir/ClaudePath highlight
-- classification) and perm_input_lines (field-priority value picker + the
-- full-dump fallback for tools with no primary field — Goal 12 batch 1's High
-- allowlist-miss finding: an MCP tool or Task/Agent whose input carries none
-- of command/url/query/pattern/file_path/path used to render ZERO parameters
-- above the choice row). Both were local-only with no direct coverage before
-- Gate._perm_path_ranges / Gate._perm_input_lines were exported.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_gate_perm_lines_spec.lua"

local H = dofile("tests/helpers.lua")
local gate = require("utils.claude.gate")

-- ── perm_path_ranges ───────────────────────────────────────────────────────────
local ranges = gate._perm_path_ranges("  edit src/init.lua then check ~/.config/nvim/")
H.check("path_ranges finds a file path", #ranges >= 1)
local file_range = ranges[1]
H.check("file path classified ClaudePath (no trailing slash)", file_range[3] == "ClaudePath", vim.inspect(file_range))

local dir_ranges = gate._perm_path_ranges("look in ~/.config/nvim/ for it")
local dir_hit
for _, r in ipairs(dir_ranges) do
	if r[3] == "ClaudeDir" then
		dir_hit = r
	end
end
H.check("trailing-slash token classified ClaudeDir", dir_hit ~= nil, vim.inspect(dir_ranges))

H.check("no slash → no ranges", #gate._perm_path_ranges("no paths here at all") == 0)

-- ── perm_input_lines ───────────────────────────────────────────────────────────
H.check("non-table input → empty", #gate._perm_input_lines("not a table") == 0)
H.check("empty table input → empty", #gate._perm_input_lines({}) == 0)

local cmd_lines = gate._perm_input_lines({ command = "git status" })
H.check("command field picked as primary value", cmd_lines[1] == "git status", vim.inspect(cmd_lines))

-- Priority order: command wins over url when both present.
local priority_lines = gate._perm_input_lines({ url = "https://example.com", command = "curl x" })
H.check(
	"command outranks url per PRIMARY_INPUT_FIELDS order",
	priority_lines[1] == "curl x",
	vim.inspect(priority_lines)
)

-- Multi-line value (e.g. a Write's file content) splits on "\n".
local multi = gate._perm_input_lines({ command = "line one\nline two\nline three" })
H.check("embedded newlines split into separate lines", #multi == 3 and multi[2] == "line two", vim.inspect(multi))

-- The High finding: an MCP-style / Task-style input with none of the primary
-- fields must NOT render zero parameters — it falls back to a full dump.
local mcp_input = { description = "spawn a subagent", prompt = "do the thing", subagent_type = "fork" }
local fallback_lines = gate._perm_input_lines(mcp_input)
H.check("no-primary-field input still renders something", #fallback_lines > 0, vim.inspect(fallback_lines))
local dump = table.concat(fallback_lines, "\n")
H.check("fallback dump surfaces the hidden prompt field", dump:find("do the thing", 1, true) ~= nil, dump)

H.summary("claude_gate_perm_lines")
