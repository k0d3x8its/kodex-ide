-- tests/opencode_spec.lua
-- Drives the REAL lua/utils/opencode.lua public surface: the availability guard
-- and ask_selection (visual-selection trim + fenced-message assembly). Covers
-- the selection=exclusive fix from the v1.1.0 review (finding #6).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/opencode_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_toggleterm()
H.stub_project_root("/tmp")

local opencode = require("utils.opencode")
opencode.setup({ width_pct = 0.40 })

-- ask_selection reads the '< '> marks of the CURRENT buffer. We aren't really in
-- visual mode under headless, so set a scratch buffer's lines + marks by hand.
local function with_selection(lines, s_line, s_col, e_line, e_col, selection_mode)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.o.selection = selection_mode or "inclusive"
  vim.fn.setpos("'<", { buf, s_line, s_col, 0 })
  vim.fn.setpos("'>", { buf, e_line, e_col, 0 })
  return buf
end

-- Auto-answer the floating prompt so the flow runs end to end.
local function stub_input(answer)
  vim.ui.input = function(_, cb) cb(answer) end
end

-- ---------------------------------------------------- availability guard (gap-free no-op)
opencode.is_available = function() return false end
opencode.state.term = nil
opencode.toggle()
H.check("toggle is a no-op when binary unavailable", opencode.state.term == nil)
stub_input("Q")
with_selection({ "hello" }, 1, 1, 1, 5)
opencode.ask_selection()
vim.wait(50)
H.check("ask_selection is a no-op when binary unavailable", #H.sent == 0,
  "sent=" .. #H.sent)

-- From here on, pretend opencode is installed.
opencode.is_available = function() return true end

-- ---------------------------------------------------- single-line selection (warm panel)
H.sent = {}
opencode.state.term = nil
stub_input("What is this")
with_selection({ "world foo" }, 1, 1, 1, 5) -- inclusive: cols 1..5 → "world"
opencode.ask_selection()
vim.wait(700, function() return #H.sent > 0 end)
H.check("single-line: one message sent", #H.sent == 1, "sent=" .. #H.sent)
H.check("single-line: fenced message assembled correctly",
  H.sent[1] == "What is this\n\n```\nworld\n```", vim.inspect(H.sent[1]))

-- ---------------------------------------------------- multi-line selection
H.sent = {}
opencode.state.term = nil
stub_input("explain")
with_selection({ "abc", "def", "ghi" }, 1, 2, 3, 2) -- (1,2)->(3,2) inclusive
opencode.ask_selection()
vim.wait(700, function() return #H.sent > 0 end)
H.check("multi-line: spans first/last line trims",
  H.sent[1] == "explain\n\n```\nbc\ndef\ngh\n```", vim.inspect(H.sent[1]))

-- ---------------------------------------------------- selection=exclusive (finding #6)
-- "world foo", select "world": exclusive '>' sits one past, at col 6 (the space).
-- Without the fix the trailing space leaks into the selection.
H.sent = {}
opencode.state.term = nil
stub_input("q")
with_selection({ "world foo" }, 1, 1, 1, 6, "exclusive")
opencode.ask_selection()
vim.wait(700, function() return #H.sent > 0 end)
H.check("exclusive: end column trimmed, no trailing space",
  H.sent[1] == "q\n\n```\nworld\n```", vim.inspect(H.sent[1]))
vim.o.selection = "inclusive"

-- ---------------------------------------------------- empty selection guard
H.sent = {}
opencode.state.term = nil
stub_input("q")
with_selection({ "" }, 1, 1, 1, 1)
opencode.ask_selection()
vim.wait(100)
H.check("empty selection sends nothing", #H.sent == 0, "sent=" .. #H.sent)

H.summary("opencode")
