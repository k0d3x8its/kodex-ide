-- tests/opencode_diff_spec.lua
-- Drives the REAL lua/utils/opencode_diff.lua through the FileChangedShell →
-- queued-vimdiff mechanism. Ports the 9 hard cases the throwaway prototype
-- proved (T1–T9), then adds regression tests (T10–T13) for the correctness
-- fixes made during the v1.1.0 code review.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/opencode_diff_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_toggleterm()
H.stub_project_root("/tmp")

local opencode = require("utils.opencode")
opencode.setup({ width_pct = 0.40 })

local D = require("utils.opencode_diff")
D.state.debug = true

-- Simulate panel open: sets opencode_active, autoread hook, registers autocmds.
opencode.state.opencode_active = true
D.on_panel_open()

local function fcs_count()
  local n = 0
  for _, l in ipairs(D.state.log) do
    if l:match("^fcs%-fired:") then n = n + 1 end
  end
  return n
end

local function has_log(pat)
  for _, l in ipairs(D.state.log) do
    if l:match(pat) then return true end
  end
  return false
end

local function diff_win_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].diff then n = n + 1 end
  end
  return n
end

local ws = "/tmp/kodex_diff_ws"
vim.fn.system({ "rm", "-rf", ws })
vim.fn.mkdir(ws, "p")
local file1, file2 = ws .. "/alpha.txt", ws .. "/beta.txt"

-- --------------------------------------------------------------------- T1–T9
vim.fn.writefile({ "a1", "a2", "a3" }, file1)
vim.cmd("edit " .. file1)
local buf1 = vim.fn.bufnr(file1)

-- T1: external write, no checktime → event never fires on its own
H.ext_write(file1, { "b1", "b2", "b3", "b4" })
vim.wait(100)
H.check("T1 no event without checktime", fcs_count() == 0, "fcs=" .. fcs_count())

-- T2: checktime → event fires, queued, diff opens, original buffer untouched
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
H.check("T2 fcs fires via checktime", fcs_count() == 1, "fcs=" .. fcs_count())
H.check("T2 diff opened for file1", D.state.current == file1)
H.check("T2 buffer keeps ORIGINAL content", H.buf_lines(buf1) == "a1|a2|a3", H.buf_lines(buf1))
H.check("T2 buffer not marked modified", not vim.bo[buf1].modified)
H.check("T2 two diff windows", diff_win_count() == 2, "diffwins=" .. diff_win_count())
H.check("T2 scratch shows DISK content", H.buf_lines(D.state.scratch) == "b1|b2|b3|b4",
  H.buf_lines(D.state.scratch))

-- T3: immediate re-checktime → timestamps synced, no re-fire
D.checktime_all()
vim.wait(100)
H.check("T3 no re-fire for same disk state", fcs_count() == 1, "fcs=" .. fcs_count())

-- T4: second external write while diff pending → fires, deduped against current
H.ext_write(file1, { "c1", "c2" })
D.checktime_all()
vim.wait(100)
H.check("T4 new write fires again", fcs_count() == 2, "fcs=" .. fcs_count())
H.check("T4 deduped against current", has_log("^dedup%-current:"))
H.check("T4 queue still empty", #opencode.state.diff_queue == 0)

-- T5: reject-all → original back on disk, no re-queue loop
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)
H.check("T5 reject succeeded (no FAILED)", has_log("^reject%-all:") and not has_log("reject%-all%-FAILED"))
H.check("T5 disk restored to original",
  table.concat(vim.fn.readfile(file1), "|") == "a1|a2|a3", table.concat(vim.fn.readfile(file1), "|"))
D.checktime_all(); vim.wait(100); D.checktime_all(); vim.wait(100)
H.check("T5 NO infinite re-queue after reject",
  fcs_count() == 2 and #opencode.state.diff_queue == 0,
  "fcs=" .. fcs_count() .. " queue=" .. #opencode.state.diff_queue)

-- T6: accept-all path
H.ext_write(file1, { "d1", "d2", "d3" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
D.accept_all()
vim.wait(200, function() return D.state.current == nil end)
H.check("T6 buffer took proposed content", H.buf_lines(buf1) == "d1|d2|d3", H.buf_lines(buf1))
H.check("T6 buffer written, not modified", not vim.bo[buf1].modified)
D.checktime_all(); vim.wait(100)
H.check("T6 no re-fire after accept", fcs_count() == 3, "fcs=" .. fcs_count())

-- T7: two files changed → queue, one diff at a time, auto-advance
vim.fn.writefile({ "x1" }, file2)
vim.cmd("edit " .. file2)
local buf2 = vim.fn.bufnr(file2)
H.ext_write(file1, { "e1" })
H.ext_write(file2, { "y1", "y2" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
H.check("T7 both fired", fcs_count() == 5, "fcs=" .. fcs_count())
H.check("T7 one diff open, one queued",
  D.state.current ~= nil and #opencode.state.diff_queue == 1,
  "current=" .. tostring(D.state.current) .. " queue=" .. #opencode.state.diff_queue)
local first = D.state.current
D.accept_all()
vim.wait(300, function() return D.state.current ~= nil and D.state.current ~= first end)
H.check("T7 second diff auto-opens after first resolved",
  D.state.current ~= nil and D.state.current ~= first, "current=" .. tostring(D.state.current))
D.accept_all()
vim.wait(200, function() return D.state.current == nil end)
H.check("T7 queue drained", D.state.current == nil and #opencode.state.diff_queue == 0)

-- T8: full fidelity — child process inside real :terminal, WinEnter-driven checktime
local fcs_before = fcs_count()
vim.cmd("tabnew")
local job = vim.fn.jobstart({ "sh", "-c", "echo term-edit > " .. file1 }, { term = true })
vim.fn.jobwait({ job }, 2000)
vim.wait(100)
H.check("T8 still silent inside terminal tab", fcs_count() == fcs_before)
vim.cmd("tabclose") -- WinEnter on landing window → autocmd → checktime
vim.wait(300, function() return D.state.current ~= nil end)
H.check("T8 WinEnter autocmd caught terminal-child edit",
  fcs_count() == fcs_before + 1 and D.state.current == file1,
  "fcs=" .. fcs_count() .. " current=" .. tostring(D.state.current))
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)

-- T9: local unsaved edits + external write → WARN flagged
vim.api.nvim_buf_set_lines(buf2, 0, 0, false, { "local-unsaved" })
H.ext_write(file2, { "z1" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
H.check("T9 warn on local unsaved edits", has_log("WARN%-local%-edits"))
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)

-- ----------------------------------------------------- T10–T13 review regressions

-- T10 (finding #1): a queued path with NO open buffer must NOT strand the rest
-- of the queue — open_diff has to drain to the next item.
D.state.current = nil
opencode.state.diff_queue = { "/tmp/kodex_ghost_nofile_" .. vim.fn.localtime(), file1 }
D.process_next()
vim.wait(300, function() return D.state.current ~= nil end)
H.check("T10 no-buffer item drained, real file shown",
  D.state.current == file1 and #opencode.state.diff_queue == 0,
  "current=" .. tostring(D.state.current) .. " queue=" .. #opencode.state.diff_queue)
H.check("T10 logged no-buffer skip", has_log("^no%-buffer:"))
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)

-- T11 (finding #2): a file open in a buffer but DELETED from disk must not crash
-- readfile — open_diff pcalls it and drains the queue.
local gone = ws .. "/gone.txt"
vim.fn.writefile({ "g1" }, gone)
vim.cmd("edit " .. gone)
vim.fn.delete(gone)
D.state.current = nil
opencode.state.diff_queue = { gone }
local ok11 = pcall(D.process_next)
vim.wait(300)
H.check("T11 deleted-file readfile did not crash + drained",
  ok11 and D.state.current == nil and #opencode.state.diff_queue == 0 and has_log("^readfile%-failed:"),
  "ok=" .. tostring(ok11) .. " current=" .. tostring(D.state.current))

-- T12 (finding #3): accept_all must survive an invalidated original buffer
-- (e.g. user :bd'd it) rather than throwing on nvim_buf_set_lines.
H.ext_write(file2, { "p1", "p2" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
vim.api.nvim_buf_delete(D.state.orig_buf, { force = true })
local ok12 = pcall(D.accept_all)
vim.wait(200, function() return D.state.current == nil end)
H.check("T12 accept_all survives invalid orig_buf",
  ok12 and D.state.current == nil, "ok=" .. tostring(ok12) .. " current=" .. tostring(D.state.current))

-- T13 (finding #15a): a FAILED reject-all write must NOT silently advance the
-- queue as if the revert succeeded — it must keep the diff open + log FAILED.
-- Force a deterministic write failure by deleting the file's parent directory
-- out from under it (write! → ENOENT).
local subdir = ws .. "/sub"
vim.fn.mkdir(subdir, "p")
local wf = subdir .. "/wf.txt"
vim.fn.writefile({ "w1" }, wf)
vim.cmd("edit " .. wf)
H.ext_write(wf, { "w2" })
D.checktime_all()
vim.wait(200, function() return D.state.current == wf end)
vim.fn.delete(subdir, "rf") -- parent gone → write! cannot succeed
D.reject_all()
vim.wait(200)
H.check("T13 failed reject keeps diff open (no silent advance)",
  D.state.current == wf and has_log("^reject%-all%-FAILED:"),
  "current=" .. tostring(D.state.current))

H.summary("opencode_diff")
