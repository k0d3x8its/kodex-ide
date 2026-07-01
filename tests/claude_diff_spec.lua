-- tests/claude_diff_spec.lua
-- Drives the REAL lua/utils/claude_diff.lua through the FileChangedShell →
-- queued-vimdiff mechanism. Ports the 13 hard cases from opencode_diff_spec.lua
-- (T1–T13) adapted for Claude state/keymaps, plus:
--   T14: augroup isolation — ClaudeDiff must not clobber OpencodeDiff
--   T15: CORRECTION #1 — on_panel_open() disables autoread
--   T16: CORRECTION #2 — fcs_choice set to "" (not "ignore")
-- The remaining CORRECTION behaviors (3,4,5) are exercised implicitly by T2/T7/T5.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_diff_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- No jobstart/chansend/jobstop stub here: claude_diff tests never call toggle(),
-- so claude's subprocess infrastructure is never exercised. Stubbing jobstart
-- would also break T8's terminal job (vim.fn.jobstart is the real call there).

-- Stub term_layout — panel window ops are irrelevant to the diff tests.
package.loaded["utils.term_layout"] = {
  place_vertical   = function() end,
  place_horizontal = function() end,
}

-- Stub opencode for the mutex check inside claude.toggle() (not exercised
-- by diff tests, but pcall(require, "utils.opencode") must not error).
package.loaded["utils.opencode"] = {
  state  = { opencode_active = false },
  toggle = function() end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })

local D = require("utils.claude_diff")
D.state.debug = true

-- Simulate panel open: sets claude_active, disables autoread, registers autocmds.
claude.state.claude_active = true
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

local ws = "/tmp/kodex_claude_diff_ws"
vim.fn.system({ "rm", "-rf", ws })
vim.fn.mkdir(ws, "p")
local file1, file2 = ws .. "/alpha.txt", ws .. "/beta.txt"

-- ─────────────────────────────────────────────────────────────────────── T1–T9

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
H.check("T2 diff opened for file1",   D.state.current == file1)
H.check("T2 buffer keeps ORIGINAL content", H.buf_lines(buf1) == "a1|a2|a3", H.buf_lines(buf1))
H.check("T2 buffer not marked modified", not vim.bo[buf1].modified)
H.check("T2 two diff windows", diff_win_count() == 2, "diffwins=" .. diff_win_count())
H.check("T2 scratch shows DISK content", H.buf_lines(D.state.scratch) == "b1|b2|b3|b4",
  H.buf_lines(D.state.scratch))
-- Verify scratch buffer is named "[Claude proposed] …" (not "[OpenCode proposed] …")
local scratch_name = vim.api.nvim_buf_get_name(D.state.scratch)
H.check("T2 scratch named [Claude proposed]",
  scratch_name:match("%[Claude proposed%]") ~= nil, scratch_name)

-- T3: immediate re-checktime → timestamps synced, no re-fire
D.checktime_all()
vim.wait(100)
H.check("T3 no re-fire for same disk state", fcs_count() == 1, "fcs=" .. fcs_count())

-- T4: second external write while diff pending → fires, deduped against current
H.ext_write(file1, { "c1", "c2" })
D.checktime_all()
vim.wait(100)
H.check("T4 new write fires again",       fcs_count() == 2, "fcs=" .. fcs_count())
H.check("T4 deduped against current",     has_log("^dedup%-current:"))
H.check("T4 queue still empty",           #claude.state.diff_queue == 0)

-- T5: reject-all → original back on disk, no re-queue loop
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)
H.check("T5 reject succeeded (no FAILED)",
  has_log("^reject%-all:") and not has_log("reject%-all%-FAILED"))
H.check("T5 disk restored to original",
  table.concat(vim.fn.readfile(file1), "|") == "a1|a2|a3",
  table.concat(vim.fn.readfile(file1), "|"))
D.checktime_all(); vim.wait(100); D.checktime_all(); vim.wait(100)
H.check("T5 NO infinite re-queue after reject",
  fcs_count() == 2 and #claude.state.diff_queue == 0,
  "fcs=" .. fcs_count() .. " queue=" .. #claude.state.diff_queue)

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
  D.state.current ~= nil and #claude.state.diff_queue == 1,
  "current=" .. tostring(D.state.current) .. " queue=" .. #claude.state.diff_queue)
local first = D.state.current
D.accept_all()
vim.wait(300, function() return D.state.current ~= nil and D.state.current ~= first end)
H.check("T7 second diff auto-opens after first resolved",
  D.state.current ~= nil and D.state.current ~= first, "current=" .. tostring(D.state.current))
D.accept_all()
vim.wait(200, function() return D.state.current == nil end)
H.check("T7 queue drained", D.state.current == nil and #claude.state.diff_queue == 0)

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

-- ─────────────────────────────────────────────────────── T10–T13 review regressions

-- T10: queued path with NO open buffer must drain to next item
D.state.current = nil
claude.state.diff_queue = { "/tmp/claude_ghost_nofile_" .. vim.fn.localtime(), file1 }
D.process_next()
vim.wait(300, function() return D.state.current ~= nil end)
H.check("T10 no-buffer item drained, real file shown",
  D.state.current == file1 and #claude.state.diff_queue == 0,
  "current=" .. tostring(D.state.current) .. " queue=" .. #claude.state.diff_queue)
H.check("T10 logged no-buffer skip", has_log("^no%-buffer:"))
D.reject_all()
vim.wait(200, function() return D.state.current == nil end)

-- T11: file deleted from disk must not crash readfile
local gone = ws .. "/gone.txt"
vim.fn.writefile({ "g1" }, gone)
vim.cmd("edit " .. gone)
vim.fn.delete(gone)
D.state.current = nil
claude.state.diff_queue = { gone }
local ok11 = pcall(D.process_next)
vim.wait(300)
H.check("T11 deleted-file readfile did not crash + drained",
  ok11 and D.state.current == nil and #claude.state.diff_queue == 0
    and has_log("^readfile%-failed:"),
  "ok=" .. tostring(ok11) .. " current=" .. tostring(D.state.current))

-- T12: accept_all survives invalidated original buffer
H.ext_write(file2, { "p1", "p2" })
D.checktime_all()
vim.wait(200, function() return D.state.current ~= nil end)
vim.api.nvim_buf_delete(D.state.orig_buf, { force = true })
local ok12 = pcall(D.accept_all)
vim.wait(200, function() return D.state.current == nil end)
H.check("T12 accept_all survives invalid orig_buf",
  ok12 and D.state.current == nil, "ok=" .. tostring(ok12))

-- T13: FAILED reject-all write must NOT silently advance the queue
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

-- ─────────────────────────── T14: augroup isolation — ClaudeDiff vs OpencodeDiff

-- Load opencode_diff to trigger its autocmd registration. If augroup names were
-- shared, the ClaudeDiff registration (which happened in D.on_panel_open() above)
-- would have been wiped when opencode_diff registers OpencodeDiff — or vice versa.
H.stub_toggleterm()
package.loaded["utils.opencode"] = nil  -- force fresh load (was stubbed above)
local opencode_mod = require("utils.opencode")
opencode_mod.state.opencode_active = true
local OD = require("utils.opencode_diff")
OD.state.debug = true
OD.on_panel_open()

local claude_cmds   = vim.api.nvim_get_autocmds({ group = "ClaudeDiff" })
local opencode_cmds = vim.api.nvim_get_autocmds({ group = "OpencodeDiff" })
H.check("T14 ClaudeDiff augroup has autocmds",
  #claude_cmds > 0, "#ClaudeDiff=" .. #claude_cmds)
H.check("T14 OpencodeDiff augroup has autocmds",
  #opencode_cmds > 0, "#OpencodeDiff=" .. #opencode_cmds)
H.check("T14 neither augroup clobbered the other",
  #claude_cmds > 0 and #opencode_cmds > 0)

-- ─────────────────────────── T15: CORRECTION #1 — on_panel_open disables autoread

-- autoread must be forced OFF when the panel opens; otherwise Neovim silently
-- reloads changed files and FileChangedShell never fires (CORRECTION #1).
vim.o.autoread = true  -- simulate default "on" state
local D2 = require("utils.claude_diff")  -- already loaded; re-use
D2.on_panel_close()   -- restore autoread first so we can test on_panel_open cleanly
vim.o.autoread = true  -- set it back to ON
D2.on_panel_open()
H.check("T15 CORRECTION #1 — on_panel_open sets autoread=false",
  vim.o.autoread == false,
  "autoread=" .. tostring(vim.o.autoread))
D2.on_panel_close()
H.check("T15 on_panel_close restores autoread",
  vim.o.autoread == true,
  "autoread=" .. tostring(vim.o.autoread))

-- ─────────────────────────── T16: CORRECTION #2 — fcs_choice set to "" not "ignore"

-- T13 intentionally left D.state.current non-nil (the diff stays open on
-- failed reject). T15 re-used D2 without clearing it, so the leftover current
-- from T13's wf.txt path would cause T16's FCS → open_diff to dedup against it.
-- Reset the diff state before T16 so the scenario starts clean.
D2.state.current  = nil
D2.state.scratch  = nil
D2.state.orig_buf = nil
claude.state.diff_queue  = {}
claude.state.diff_pending = false

-- fcs_choice must be set synchronously to "" inside the FCS callback; "ignore"
-- is technically invalid and behaviour depends on Nvim version (CORRECTION #2).
-- We can test this by triggering a FCS event via checktime on a changed file
-- and inspecting the value Neovim holds at the moment the callback ran.
-- (Indirect verification: if fcs_choice were "ignore" the diff wouldn't open.)
-- Re-use the T2 scenario: write to file1 again.
vim.fn.writefile({ "a1", "a2", "a3" }, file1)  -- restore original
vim.cmd("edit " .. file1)
local buf1b = vim.fn.bufnr(file1)
claude.state.claude_active = true   -- ensure interceptor is active
D2.on_panel_open()
H.ext_write(file1, { "fcs-check" })
D2.checktime_all()
vim.wait(200, function() return D2.state.current ~= nil end)
H.check("T16 CORRECTION #2 — diff opens (implies fcs_choice was '' not 'ignore')",
  D2.state.current == file1,
  "current=" .. tostring(D2.state.current))
D2.reject_all()
vim.wait(200, function() return D2.state.current == nil end)

-- ─────────────────────────── T17: NEW file (Claude-created) → whole-file diff

-- watch() on a not-yet-existing file must NOT bufadd/bufload it (that BF_NEW
-- buffer is what raised the W13 wall). It records the path pending; once Claude
-- creates it, poll()→sweep_new promotes it to a whole-file-additions diff.
D2.state.current   = nil
D2.state.scratch   = nil
D2.state.orig_buf  = nil
D2.state.pending_new = {}
D2.state.new_files   = {}
claude.state.diff_queue   = {}
claude.state.diff_pending = false
claude.state.claude_active = true

local newf   = ws .. "/created.txt"
local absnew = vim.fn.fnamemodify(newf, ":p")
vim.fn.delete(newf)
D2.watch(newf)  -- file absent → pending, no buffer created (would W13 on create)
H.check("T17 watch records pending-new, creates NO buffer",
  D2.state.pending_new[absnew] == true and vim.fn.bufnr(newf) == -1,
  "pending=" .. tostring(D2.state.pending_new[absnew]) ..
    " bufnr=" .. vim.fn.bufnr(newf))

vim.fn.writefile({ "new1", "new2", "new3" }, newf)  -- Claude creates it
D2.poll()  -- checktime_all + sweep_new + process_next
vim.wait(300, function() return D2.state.current ~= nil end)
H.check("T17 new-file diff opened", D2.state.current == absnew,
  "current=" .. tostring(D2.state.current))
H.check("T17 kind == new", D2.state.kind == "new", "kind=" .. tostring(D2.state.kind))
H.check("T17 orig side EMPTY (whole file = additions)",
  H.buf_lines(D2.state.orig_buf) == "", "orig=[" .. H.buf_lines(D2.state.orig_buf) .. "]")
H.check("T17 proposed shows created content",
  H.buf_lines(D2.state.scratch) == "new1|new2|new3", H.buf_lines(D2.state.scratch))

-- reject of a NEW file DELETES it (must not leave a stray empty file)
D2.reject_all()
vim.wait(200, function() return D2.state.current == nil end)
H.check("T17 reject deletes the new file from disk",
  vim.fn.filereadable(newf) == 0 and has_log("^reject%-new%-deleted:"),
  "readable=" .. vim.fn.filereadable(newf))
H.check("T17 new_files cleared after resolve", next(D2.state.new_files) == nil)

-- ─────────────────────────── T18: NEW file accept → file KEPT with content

D2.state.pending_new = {}
D2.state.new_files   = {}
D2.state.current     = nil
claude.state.diff_queue = {}
local newf2 = ws .. "/created2.txt"
vim.fn.delete(newf2)
D2.watch(newf2)
vim.fn.writefile({ "keep1", "keep2" }, newf2)
D2.poll()
vim.wait(300, function() return D2.state.current ~= nil end)
D2.accept_all()
vim.wait(200, function() return D2.state.current == nil end)
H.check("T18 new-file accept keeps file with proposed content",
  vim.fn.filereadable(newf2) == 1
    and table.concat(vim.fn.readfile(newf2), "|") == "keep1|keep2",
  "content=" .. table.concat(vim.fn.readfile(newf2), "|"))

H.summary("claude_diff")
