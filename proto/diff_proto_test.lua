-- PROTOTYPE driver (throwaway) — drives diff_proto.lua through the hard cases.
-- Run: bash proto/run_proto.sh

vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "A"

local P = dofile("diff_proto.lua")
P.setup()
P.state.active = true

local ws = "/tmp/diff_proto_ws"
vim.fn.system({ "rm", "-rf", ws })
vim.fn.mkdir(ws, "p")
local file1, file2 = ws .. "/alpha.txt", ws .. "/beta.txt"

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. (detail and ("  — " .. detail) or ""))
  end
end

local function fcs_count()
  local n = 0
  for _, l in ipairs(P.state.log) do
    if l:match("^fcs%-fired:") then n = n + 1 end
  end
  return n
end

local function has_log(pat)
  for _, l in ipairs(P.state.log) do
    if l:match(pat) then return true end
  end
  return false
end

local function ext_write(path, lines)
  -- real child process, no Neovim window events — simulates opencode's write
  vim.fn.system({ "sh", "-c", "printf '%s\\n' " .. table.concat(lines, " ") .. " > " .. path })
end

local function buf_lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end

-- ---------------------------------------------------------------------- setup
vim.fn.writefile({ "a1", "a2", "a3" }, file1)
vim.cmd("edit " .. file1)
local buf1 = vim.fn.bufnr(file1)

-- T1: external write, NO checktime — premise: event never fires on its own
ext_write(file1, { "b1", "b2", "b3", "b4" })
vim.wait(100)
check("T1 no event without checktime", fcs_count() == 0, "fcs=" .. fcs_count())

-- T2: checktime → event fires, ignored, queued, diff opens, buffer untouched
P.checktime_all()
vim.wait(200, function() return P.state.current ~= nil end)
check("T2 fcs fires via checktime", fcs_count() == 1, "fcs=" .. fcs_count())
check("T2 diff opened for file1", P.state.current == file1)
check("T2 buffer keeps ORIGINAL content", buf_lines(buf1) == "a1|a2|a3", buf_lines(buf1))
check("T2 buffer not marked modified", not vim.bo[buf1].modified)
local diffwins = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.wo[w].diff then diffwins = diffwins + 1 end
end
check("T2 two diff windows", diffwins == 2, "diffwins=" .. diffwins)
check("T2 scratch shows DISK content",
  buf_lines(P.state.scratch) == "b1|b2|b3|b4", buf_lines(P.state.scratch))

-- T3: immediate re-checktime — fcs_choice=ignore must have synced timestamps
P.checktime_all()
vim.wait(100)
check("T3 no re-fire for same disk state", fcs_count() == 1, "fcs=" .. fcs_count())

-- T4: second external write while diff pending → fires again, dedups
ext_write(file1, { "c1", "c2" })
P.checktime_all()
vim.wait(100)
check("T4 new write fires again", fcs_count() == 2, "fcs=" .. fcs_count())
check("T4 deduped against current", has_log("^dedup%-current:"))
check("T4 queue still empty", #P.state.queue == 0)

-- T5: reject-all → original back on disk, NO re-queue loop
P.reject_all()
vim.wait(200, function() return P.state.current == nil end)
check("T5 plain :w succeeded (no E13)", has_log("^reject%-all:") and not has_log("FAILED"))
check("T5 disk restored to original",
  table.concat(vim.fn.readfile(file1), "|") == "a1|a2|a3",
  table.concat(vim.fn.readfile(file1), "|"))
P.checktime_all()
vim.wait(100)
P.checktime_all()
vim.wait(100)
check("T5 NO infinite re-queue after reject", fcs_count() == 2 and #P.state.queue == 0,
  "fcs=" .. fcs_count() .. " queue=" .. #P.state.queue)

-- T6: accept-all path
ext_write(file1, { "d1", "d2", "d3" })
P.checktime_all()
vim.wait(200, function() return P.state.current ~= nil end)
P.accept_all()
vim.wait(200, function() return P.state.current == nil end)
check("T6 buffer took proposed content", buf_lines(buf1) == "d1|d2|d3", buf_lines(buf1))
check("T6 buffer written, not modified", not vim.bo[buf1].modified)
P.checktime_all()
vim.wait(100)
check("T6 no re-fire after accept", fcs_count() == 3, "fcs=" .. fcs_count())

-- T7: two files changed → queue, one diff at a time, auto-advance
vim.fn.writefile({ "x1" }, file2)
vim.cmd("edit " .. file2)
local buf2 = vim.fn.bufnr(file2)
ext_write(file1, { "e1" })
ext_write(file2, { "y1", "y2" })
P.checktime_all()
vim.wait(200, function() return P.state.current ~= nil end)
check("T7 both fired", fcs_count() == 5, "fcs=" .. fcs_count())
check("T7 one diff open, one queued",
  P.state.current ~= nil and #P.state.queue == 1,
  "current=" .. tostring(P.state.current) .. " queue=" .. #P.state.queue)
local first = P.state.current
P.accept_all()
vim.wait(300, function() return P.state.current ~= nil and P.state.current ~= first end)
check("T7 second diff auto-opens after first resolved",
  P.state.current ~= nil and P.state.current ~= first,
  "current=" .. tostring(P.state.current))
P.accept_all()
vim.wait(200, function() return P.state.current == nil end)
check("T7 queue drained", P.state.current == nil and #P.state.queue == 0)

-- T8: full fidelity — child process inside real :terminal, WinEnter-driven checktime
local fcs_before = fcs_count()
vim.cmd("tabnew")
local job = vim.fn.jobstart({ "sh", "-c", "echo term-edit > " .. file1 }, { term = true })
vim.fn.jobwait({ job }, 2000)
vim.wait(100)
check("T8 still silent inside terminal tab", fcs_count() == fcs_before)
vim.cmd("tabclose") -- WinEnter on landing window → autocmd → checktime
vim.wait(300, function() return P.state.current ~= nil end)
check("T8 WinEnter autocmd caught terminal-child edit",
  fcs_count() == fcs_before + 1 and P.state.current == file1,
  "fcs=" .. fcs_count() .. " current=" .. tostring(P.state.current))
P.reject_all()
vim.wait(200, function() return P.state.current == nil end)

-- T9: local unsaved edits + external write → WARN flagged
vim.api.nvim_buf_set_lines(buf2, 0, 0, false, { "local-unsaved" })
ext_write(file2, { "z1" })
P.checktime_all()
vim.wait(200, function() return P.state.current ~= nil end)
check("T9 warn on local unsaved edits", has_log("WARN%-local%-edits"))

-- ------------------------------------------------------------------- summary
print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
print("log: " .. table.concat(P.state.log, "  ·  "))
if failures > 0 then vim.cmd("cq") else vim.cmd("qa!") end
