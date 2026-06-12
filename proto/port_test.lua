-- PROTOTYPE port-verification test (throwaway) — verifies lua/utils/opencode_diff.lua
-- against the same 9 hard cases as diff_proto_test.lua.
-- Run: bash proto/run_port_test.sh
--
-- Differences from diff_proto_test.lua:
--   - Drives the real module, not the prototype
--   - Uses opencode.state.diff_queue (shared state, matches production wiring)
--   - Enables M.state.debug for event log assertions
--   - Guards on opencode.state.opencode_active, not P.state.active

vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "A"

-- Stub toggleterm before requiring the real modules so Terminal:new doesn't
-- blow up in the headless --headless -u NONE environment
package.loaded["toggleterm.terminal"] = {
  Terminal = {
    new = function(_, opts)
      local t = { _opts = opts, _open = false }
      function t:is_open() return self._open end
      function t:toggle()
        if self._open then
          self._open = false
          if self._opts.on_close then self._opts.on_close() end
        else
          self._open = true
          if self._opts.on_open then self._opts.on_open() end
        end
      end
      function t:shutdown()
        if self._open then
          self._open = false
          if self._opts.on_close then self._opts.on_close() end
        end
      end
      return t
    end,
  },
}

-- Stub project_root so toggle() doesn't call vim.fs.root
package.loaded["utils.project_root"] = { detect = function() return "/tmp" end }

-- Load real modules from the repo root
package.path = package.path .. ";../lua/?.lua;../lua/?/init.lua"
local opencode = require("utils.opencode")
opencode.setup({ width_pct = 0.40 })

local D = require("utils.opencode_diff")
D.state.debug = true

-- Simulate panel open (sets opencode_active + autoread hooks; registers autocmds)
opencode.state.opencode_active = true
D.on_panel_open()

local ws = "/tmp/diff_port_ws"
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

local function ext_write(path, lines)
  vim.fn.system({ "sh", "-c", "printf '%s\\n' " .. table.concat(lines, " ") .. " > " .. path })
end

local function buf_lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end

-- ---------------------------------------------------------------------- setup
vim.fn.writefile({ "a1", "a2", "a3" }, file1)
vim.cmd("edit " .. file1)
local buf1 = vim.fn.bufnr(file1)

-- T1: external write, NO checktime — event never fires on its own
ext_write(file1, { "b1", "b2", "b3", "b4" })
vim.wait(100)
check("T1 no event without checktime", fcs_count() == 0, "fcs=" .. fcs_count())

-- T2: checktime → event fires, queued, diff opens, buffer untouched
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
check("T2 fcs fires via checktime", fcs_count() == 1, "fcs=" .. fcs_count())
check("T2 diff opened for file1", D.state.current == file1)
check("T2 buffer keeps ORIGINAL content", buf_lines(buf1) == "a1|a2|a3", buf_lines(buf1))
check("T2 buffer not marked modified", not vim.bo[buf1].modified)
local diffwins = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.wo[w].diff then diffwins = diffwins + 1 end
end
check("T2 two diff windows", diffwins == 2, "diffwins=" .. diffwins)
check("T2 scratch shows DISK content",
  buf_lines(D.state.scratch) == "b1|b2|b3|b4", buf_lines(D.state.scratch))

-- T3: immediate re-checktime — timestamps synced, no re-fire
D.checktime_all()
vim.wait(100)
check("T3 no re-fire for same disk state", fcs_count() == 1, "fcs=" .. fcs_count())

-- T4: second external write while diff pending → fires, deduped against current
ext_write(file1, { "c1", "c2" })
D.checktime_all()
vim.wait(100)
check("T4 new write fires again", fcs_count() == 2, "fcs=" .. fcs_count())
check("T4 deduped against current", has_log("^dedup%-current:"))
check("T4 queue still empty", #opencode.state.diff_queue == 0)

-- T5: reject-all → original back on disk, NO re-queue loop
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)
check("T5 reject succeeded (no FAILED)", has_log("^reject%-all:") and not has_log("FAILED"))
check("T5 disk restored to original",
  table.concat(vim.fn.readfile(file1), "|") == "a1|a2|a3",
  table.concat(vim.fn.readfile(file1), "|"))
D.checktime_all()
vim.wait(100)
D.checktime_all()
vim.wait(100)
check("T5 NO infinite re-queue after reject",
  fcs_count() == 2 and #opencode.state.diff_queue == 0,
  "fcs=" .. fcs_count() .. " queue=" .. #opencode.state.diff_queue)

-- T6: accept-all path
ext_write(file1, { "d1", "d2", "d3" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
D.accept_all()
vim.wait(200, function() return D.state.current == nil end)
check("T6 buffer took proposed content", buf_lines(buf1) == "d1|d2|d3", buf_lines(buf1))
check("T6 buffer written, not modified", not vim.bo[buf1].modified)
D.checktime_all()
vim.wait(100)
check("T6 no re-fire after accept", fcs_count() == 3, "fcs=" .. fcs_count())

-- T7: two files changed → queue, one diff at a time, auto-advance
vim.fn.writefile({ "x1" }, file2)
vim.cmd("edit " .. file2)
local buf2 = vim.fn.bufnr(file2)
ext_write(file1, { "e1" })
ext_write(file2, { "y1", "y2" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
check("T7 both fired", fcs_count() == 5, "fcs=" .. fcs_count())
check("T7 one diff open, one queued",
  D.state.current ~= nil and #opencode.state.diff_queue == 1,
  "current=" .. tostring(D.state.current) .. " queue=" .. #opencode.state.diff_queue)
local first = D.state.current
D.accept_all()
vim.wait(300, function() return D.state.current ~= nil and D.state.current ~= first end)
check("T7 second diff auto-opens after first resolved",
  D.state.current ~= nil and D.state.current ~= first,
  "current=" .. tostring(D.state.current))
D.accept_all()
vim.wait(200, function() return D.state.current == nil end)
check("T7 queue drained", D.state.current == nil and #opencode.state.diff_queue == 0)

-- T8: full fidelity — child process inside real :terminal, WinEnter-driven checktime
local fcs_before = fcs_count()
vim.cmd("tabnew")
local job = vim.fn.jobstart({ "sh", "-c", "echo term-edit > " .. file1 }, { term = true })
vim.fn.jobwait({ job }, 2000)
vim.wait(100)
check("T8 still silent inside terminal tab", fcs_count() == fcs_before)
vim.cmd("tabclose") -- WinEnter on landing window → autocmd → checktime
vim.wait(300, function() return D.state.current ~= nil end)
check("T8 WinEnter autocmd caught terminal-child edit",
  fcs_count() == fcs_before + 1 and D.state.current == file1,
  "fcs=" .. fcs_count() .. " current=" .. tostring(D.state.current))
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)

-- T9: local unsaved edits + external write → WARN flagged
vim.api.nvim_buf_set_lines(buf2, 0, 0, false, { "local-unsaved" })
ext_write(file2, { "z1" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
check("T9 warn on local unsaved edits", has_log("WARN%-local%-edits"))

-- ------------------------------------------------------------------- summary
print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
print("log: " .. table.concat(D.state.log, "  ·  "))
if failures > 0 then vim.cmd("cq") else vim.cmd("qa!") end
