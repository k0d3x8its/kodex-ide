-- PROTOTYPE interactive drive (throwaway). bash proto/run_proto.sh -i
-- Sample file in left window, terminal in right split. In the terminal:
--   echo whatever >> /tmp/diff_proto_ws/alpha.txt
-- then <C-\><C-n> + move to the left window → TermLeave/WinEnter → checktime
-- → diff pops. In the [OpenCode proposed] window:
--   <space>oa accept all · <space>ox reject all · do/dp native hunk pull

vim.g.mapleader = " "
vim.o.swapfile = false

local P = dofile("diff_proto.lua")
P.setup()
P.state.active = true

local ws = "/tmp/diff_proto_ws"
vim.fn.mkdir(ws, "p")
local file = ws .. "/alpha.txt"
vim.fn.writefile({ "line one", "line two", "line three" }, file)

vim.cmd("edit " .. file)
vim.cmd("rightbelow vsplit | terminal")
print("Edit " .. file .. " from the terminal, then leave it. Diff should pop.")
