-- tests/claude_diff_spec.lua
-- Drives the REAL lua/utils/claude_diff.lua through the FileChangedShell →
-- queued-vimdiff mechanism. Ports the 13 hard cases from opencode_diff_spec.lua
-- (T1–T13) adapted for Claude state/keymaps, plus:
--   T14: augroup isolation — ClaudeDiff must not clobber OpencodeDiff
--   T15: CORRECTION #1 — on_panel_open() disables autoread
--   T16: CORRECTION #2 — fcs_choice set to "" (not "ignore")
--   T17/T18: new-file path (pending-new → sweep_new whole-file-additions diff)
--   T19: Goal 14.3 diff-review panel card — armed on open, resolves like the
--        winbar/<leader>ca/cx fallback, fallback also clears a stale card
--   T23: accept-time edit hunk anchors under its OWN header, not the buffer
--        tail, when other content (e.g. an advisor escalation) streamed in
--        while the review sat open
-- The remaining CORRECTION behaviors (3,4,5) are exercised implicitly by T2/T7/T5.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_diff_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- No jobstart/chansend/jobstop stub here: claude_diff tests never call toggle(),
-- so claude's subprocess infrastructure is never exercised. Stubbing jobstart
-- would also break T8's terminal job (vim.fn.jobstart is the real call there).

-- Stub term_layout — panel window ops are irrelevant to the diff tests.
package.loaded["utils.term_layout"] = {
	place_vertical = function() end,
	place_horizontal = function() end,
}

-- Stub opencode for the mutex check inside claude.toggle() (not exercised
-- by diff tests, but pcall(require, "utils.opencode") must not error).
package.loaded["utils.opencode"] = {
	state = { opencode_active = false },
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
		if l:match("^fcs%-fired:") then
			n = n + 1
		end
	end
	return n
end

local function has_log(pat)
	for _, l in ipairs(D.state.log) do
		if l:match(pat) then
			return true
		end
	end
	return false
end

local function diff_win_count()
	local n = 0
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.wo[w].diff then
			n = n + 1
		end
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
vim.wait(200, function()
	return D.state.current ~= nil
end)
H.check("T2 fcs fires via checktime", fcs_count() == 1, "fcs=" .. fcs_count())
H.check("T2 diff opened for file1", D.state.current == file1)
H.check("T2 buffer keeps ORIGINAL content", H.buf_lines(buf1) == "a1|a2|a3", H.buf_lines(buf1))
H.check("T2 buffer not marked modified", not vim.bo[buf1].modified)
H.check("T2 two diff windows", diff_win_count() == 2, "diffwins=" .. diff_win_count())
H.check("T2 scratch shows DISK content", H.buf_lines(D.state.scratch) == "b1|b2|b3|b4", H.buf_lines(D.state.scratch))
-- Verify scratch buffer is named "[Claude proposed] …" (not "[OpenCode proposed] …")
local scratch_name = vim.api.nvim_buf_get_name(D.state.scratch)
H.check("T2 scratch named [Claude proposed]", scratch_name:match("%[Claude proposed%]") ~= nil, scratch_name)

-- T19a: opening the diff also arms the panel card (Goal 14.3) with the same
-- edit/new distinction the winbar makes.
H.check("T19 diff card armed on open", claude.state.diff_card ~= nil, vim.inspect(claude.state.diff_card))
H.check(
	"T19 diff card shows 'Modified: <name>' for an existing-file edit",
	claude.state.diff_card and claude.state.diff_card.display == "Modified: alpha.txt",
	vim.inspect(claude.state.diff_card and claude.state.diff_card.display)
)
H.check(
	"T19 diff card options are Accept/Reject",
	claude.state.diff_card
		and #claude.state.diff_card.options == 2
		and claude.state.diff_card.options[1].kind == "accept"
		and claude.state.diff_card.options[2].kind == "reject",
	vim.inspect(claude.state.diff_card and claude.state.diff_card.options)
)

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
H.check("T4 queue still empty", #claude.state.diff_queue == 0)

-- T5: reject-all → original back on disk, no re-queue loop
D.reject_all()
vim.wait(200, function()
	return D.state.current == nil
end)
H.check("T5 reject succeeded (no FAILED)", has_log("^reject%-all:") and not has_log("reject%-all%-FAILED"))
H.check(
	"T5 disk restored to original",
	table.concat(vim.fn.readfile(file1), "|") == "a1|a2|a3",
	table.concat(vim.fn.readfile(file1), "|")
)
-- T19b: resolving via the FALLBACK path (D.reject_all directly, card untouched)
-- must still clear the now-stale panel card — no float left orphaned behind.
H.check(
	"T19 fallback reject_all also clears the panel card",
	claude.state.diff_card == nil,
	vim.inspect(claude.state.diff_card)
)
D.checktime_all()
vim.wait(100)
D.checktime_all()
vim.wait(100)
H.check(
	"T5 NO infinite re-queue after reject",
	fcs_count() == 2 and #claude.state.diff_queue == 0,
	"fcs=" .. fcs_count() .. " queue=" .. #claude.state.diff_queue
)

-- T6: accept-all path
H.ext_write(file1, { "d1", "d2", "d3" })
D.checktime_all()
vim.wait(200, function()
	return D.state.current ~= nil
end)
D.accept_all()
vim.wait(200, function()
	return D.state.current == nil
end)
H.check("T6 buffer took proposed content", H.buf_lines(buf1) == "d1|d2|d3", H.buf_lines(buf1))
H.check("T6 buffer written, not modified", not vim.bo[buf1].modified)
D.checktime_all()
vim.wait(100)
H.check("T6 no re-fire after accept", fcs_count() == 3, "fcs=" .. fcs_count())

-- T7: two files changed → queue, one diff at a time, auto-advance
vim.fn.writefile({ "x1" }, file2)
vim.cmd("edit " .. file2)
local buf2 = vim.fn.bufnr(file2)
H.ext_write(file1, { "e1" })
H.ext_write(file2, { "y1", "y2" })
D.checktime_all()
vim.wait(200, function()
	return D.state.current ~= nil
end)
H.check("T7 both fired", fcs_count() == 5, "fcs=" .. fcs_count())
H.check(
	"T7 one diff open, one queued",
	D.state.current ~= nil and #claude.state.diff_queue == 1,
	"current=" .. tostring(D.state.current) .. " queue=" .. #claude.state.diff_queue
)
local first = D.state.current
D.accept_all()
vim.wait(300, function()
	return D.state.current ~= nil and D.state.current ~= first
end)
H.check(
	"T7 second diff auto-opens after first resolved",
	D.state.current ~= nil and D.state.current ~= first,
	"current=" .. tostring(D.state.current)
)
D.accept_all()
vim.wait(200, function()
	return D.state.current == nil
end)
H.check("T7 queue drained", D.state.current == nil and #claude.state.diff_queue == 0)

-- T8: full fidelity — child process inside real :terminal, WinEnter-driven checktime
local fcs_before = fcs_count()
vim.cmd("tabnew")
local job = vim.fn.jobstart({ "sh", "-c", "echo term-edit > " .. file1 }, { term = true })
vim.fn.jobwait({ job }, 2000)
vim.wait(100)
H.check("T8 still silent inside terminal tab", fcs_count() == fcs_before)
vim.cmd("tabclose") -- WinEnter on landing window → autocmd → checktime
vim.wait(300, function()
	return D.state.current ~= nil
end)
H.check(
	"T8 WinEnter autocmd caught terminal-child edit",
	fcs_count() == fcs_before + 1 and D.state.current == file1,
	"fcs=" .. fcs_count() .. " current=" .. tostring(D.state.current)
)
D.reject_all()
vim.wait(200, function()
	return D.state.current == nil
end)

-- T9: local unsaved edits + external write → WARN flagged
vim.api.nvim_buf_set_lines(buf2, 0, 0, false, { "local-unsaved" })
H.ext_write(file2, { "z1" })
D.checktime_all()
vim.wait(200, function()
	return D.state.current ~= nil
end)
H.check("T9 warn on local unsaved edits", has_log("WARN%-local%-edits"))
D.reject_all()
vim.wait(200, function()
	return D.state.current == nil
end)

-- ─────────────────────────────────────────────────────── T10–T13 review regressions

-- T10: queued path with NO open buffer must drain to next item
D.state.current = nil
claude.state.diff_queue = { "/tmp/claude_ghost_nofile_" .. vim.fn.localtime(), file1 }
D.process_next()
vim.wait(300, function()
	return D.state.current ~= nil
end)
H.check(
	"T10 no-buffer item drained, real file shown",
	D.state.current == file1 and #claude.state.diff_queue == 0,
	"current=" .. tostring(D.state.current) .. " queue=" .. #claude.state.diff_queue
)
H.check("T10 logged no-buffer skip", has_log("^no%-buffer:"))
D.reject_all()
vim.wait(200, function()
	return D.state.current == nil
end)

-- T11: file deleted from disk must not crash readfile
local gone = ws .. "/gone.txt"
vim.fn.writefile({ "g1" }, gone)
vim.cmd("edit " .. gone)
vim.fn.delete(gone)
D.state.current = nil
claude.state.diff_queue = { gone }
local ok11 = pcall(D.process_next)
vim.wait(300)
H.check(
	"T11 deleted-file readfile did not crash + drained",
	ok11 and D.state.current == nil and #claude.state.diff_queue == 0 and has_log("^readfile%-failed:"),
	"ok=" .. tostring(ok11) .. " current=" .. tostring(D.state.current)
)

-- T12: accept_all survives invalidated original buffer
H.ext_write(file2, { "p1", "p2" })
D.checktime_all()
vim.wait(200, function()
	return D.state.current ~= nil
end)
vim.api.nvim_buf_delete(D.state.orig_buf, { force = true })
local ok12 = pcall(D.accept_all)
vim.wait(200, function()
	return D.state.current == nil
end)
H.check("T12 accept_all survives invalid orig_buf", ok12 and D.state.current == nil, "ok=" .. tostring(ok12))

-- T13: FAILED reject-all write must NOT silently advance the queue
local subdir = ws .. "/sub"
vim.fn.mkdir(subdir, "p")
local wf = subdir .. "/wf.txt"
vim.fn.writefile({ "w1" }, wf)
vim.cmd("edit " .. wf)
H.ext_write(wf, { "w2" })
D.checktime_all()
vim.wait(200, function()
	return D.state.current == wf
end)
vim.fn.delete(subdir, "rf") -- parent gone → write! cannot succeed
D.reject_all()
vim.wait(200)
H.check(
	"T13 failed reject keeps diff open (no silent advance)",
	D.state.current == wf and has_log("^reject%-all%-FAILED:"),
	"current=" .. tostring(D.state.current)
)

-- ─────────────────────────── T14: augroup isolation — ClaudeDiff vs OpencodeDiff

-- Load opencode_diff to trigger its autocmd registration. If augroup names were
-- shared, the ClaudeDiff registration (which happened in D.on_panel_open() above)
-- would have been wiped when opencode_diff registers OpencodeDiff — or vice versa.
H.stub_toggleterm()
package.loaded["utils.opencode"] = nil -- force fresh load (was stubbed above)
local opencode_mod = require("utils.opencode")
opencode_mod.state.opencode_active = true
local OD = require("utils.opencode_diff")
OD.state.debug = true
OD.on_panel_open()

local claude_cmds = vim.api.nvim_get_autocmds({ group = "ClaudeDiff" })
local opencode_cmds = vim.api.nvim_get_autocmds({ group = "OpencodeDiff" })
H.check("T14 ClaudeDiff augroup has autocmds", #claude_cmds > 0, "#ClaudeDiff=" .. #claude_cmds)
H.check("T14 OpencodeDiff augroup has autocmds", #opencode_cmds > 0, "#OpencodeDiff=" .. #opencode_cmds)
H.check("T14 neither augroup clobbered the other", #claude_cmds > 0 and #opencode_cmds > 0)

-- ─────────────────────────── T15: CORRECTION #1 — on_panel_open disables autoread

-- autoread must be forced OFF when the panel opens; otherwise Neovim silently
-- reloads changed files and FileChangedShell never fires (CORRECTION #1).
vim.o.autoread = true -- simulate default "on" state
local D2 = require("utils.claude_diff") -- already loaded; re-use
D2.on_panel_close() -- restore autoread first so we can test on_panel_open cleanly
vim.o.autoread = true -- set it back to ON
D2.on_panel_open()
H.check(
	"T15 CORRECTION #1 — on_panel_open sets autoread=false",
	vim.o.autoread == false,
	"autoread=" .. tostring(vim.o.autoread)
)
D2.on_panel_close()
H.check("T15 on_panel_close restores autoread", vim.o.autoread == true, "autoread=" .. tostring(vim.o.autoread))

-- ─────────────────────────── T16: CORRECTION #2 — fcs_choice set to "" not "ignore"

-- T13 intentionally left D.state.current non-nil (the diff stays open on
-- failed reject). T15 re-used D2 without clearing it, so the leftover current
-- from T13's wf.txt path would cause T16's FCS → open_diff to dedup against it.
-- Reset the diff state before T16 so the scenario starts clean.
D2.state.current = nil
D2.state.scratch = nil
D2.state.orig_buf = nil
claude.state.diff_queue = {}
claude.state.diff_pending = false

-- fcs_choice must be set synchronously to "" inside the FCS callback; "ignore"
-- is technically invalid and behaviour depends on Nvim version (CORRECTION #2).
-- We can test this by triggering a FCS event via checktime on a changed file
-- and inspecting the value Neovim holds at the moment the callback ran.
-- (Indirect verification: if fcs_choice were "ignore" the diff wouldn't open.)
-- Re-use the T2 scenario: write to file1 again.
vim.fn.writefile({ "a1", "a2", "a3" }, file1) -- restore original
vim.cmd("edit " .. file1)
local buf1b = vim.fn.bufnr(file1)
claude.state.claude_active = true -- ensure interceptor is active
D2.on_panel_open()
H.ext_write(file1, { "fcs-check" })
D2.checktime_all()
vim.wait(200, function()
	return D2.state.current ~= nil
end)
H.check(
	"T16 CORRECTION #2 — diff opens (implies fcs_choice was '' not 'ignore')",
	D2.state.current == file1,
	"current=" .. tostring(D2.state.current)
)
D2.reject_all()
vim.wait(200, function()
	return D2.state.current == nil
end)

-- ─────────────────────────── T17: NEW file (Claude-created) → whole-file diff

-- watch() on a not-yet-existing file must NOT bufadd/bufload it (that BF_NEW
-- buffer is what raised the W13 wall). It records the path pending; once Claude
-- creates it, poll()→sweep_new promotes it to a whole-file-additions diff.
D2.state.current = nil
D2.state.scratch = nil
D2.state.orig_buf = nil
D2.state.pending_new = {}
D2.state.new_files = {}
claude.state.diff_queue = {}
claude.state.diff_pending = false
claude.state.claude_active = true

local newf = ws .. "/created.txt"
local absnew = vim.fn.fnamemodify(newf, ":p")
vim.fn.delete(newf)
local watch_ret_new = D2.watch(newf) -- file absent → pending, no buffer created (would W13 on create)
H.check(
	"T17 watch records pending-new, creates NO buffer",
	D2.state.pending_new[absnew] == true and vim.fn.bufnr(newf) == -1,
	"pending=" .. tostring(D2.state.pending_new[absnew]) .. " bufnr=" .. vim.fn.bufnr(newf)
)
H.check(
	"T17 watch() returns true for pending-new (covered via sweep_new)",
	watch_ret_new == true,
	"ret=" .. tostring(watch_ret_new)
)

vim.fn.writefile({ "new1", "new2", "new3" }, newf) -- Claude creates it
D2.poll() -- checktime_all + sweep_new + process_next
vim.wait(300, function()
	return D2.state.current ~= nil
end)
H.check("T17 new-file diff opened", D2.state.current == absnew, "current=" .. tostring(D2.state.current))
H.check("T17 kind == new", D2.state.kind == "new", "kind=" .. tostring(D2.state.kind))
H.check(
	"T17 orig side EMPTY (whole file = additions)",
	H.buf_lines(D2.state.orig_buf) == "",
	"orig=[" .. H.buf_lines(D2.state.orig_buf) .. "]"
)
H.check(
	"T17 proposed shows created content",
	H.buf_lines(D2.state.scratch) == "new1|new2|new3",
	H.buf_lines(D2.state.scratch)
)

-- reject of a NEW file DELETES it (must not leave a stray empty file)
D2.reject_all()
vim.wait(200, function()
	return D2.state.current == nil
end)
H.check(
	"T17 reject deletes the new file from disk",
	vim.fn.filereadable(newf) == 0 and has_log("^reject%-new%-deleted:"),
	"readable=" .. vim.fn.filereadable(newf)
)
H.check("T17 new_files cleared after resolve", next(D2.state.new_files) == nil)

-- ─────────────────────────── T18: NEW file accept → file KEPT with content

D2.state.pending_new = {}
D2.state.new_files = {}
D2.state.current = nil
claude.state.diff_queue = {}
local newf2 = ws .. "/created2.txt"
vim.fn.delete(newf2)
D2.watch(newf2)
vim.fn.writefile({ "keep1", "keep2" }, newf2)
D2.poll()
vim.wait(300, function()
	return D2.state.current ~= nil
end)
D2.accept_all()
vim.wait(200, function()
	return D2.state.current == nil
end)
H.check(
	"T18 new-file accept keeps file with proposed content",
	vim.fn.filereadable(newf2) == 1 and table.concat(vim.fn.readfile(newf2), "|") == "keep1|keep2",
	"content=" .. table.concat(vim.fn.readfile(newf2), "|")
)

-- ─────────────────────────── T19c/d: resolving VIA the panel card itself

-- 19c: Accept via claude._resolve_diff_card must behave exactly like accept_all
-- — write to disk, close the diff, clear the card, unlock input.
D2.state.pending_new = {}
D2.state.new_files = {}
D2.state.current = nil
claude.state.diff_queue = {}
local file3 = ws .. "/gamma.txt"
vim.fn.writefile({ "g1", "g2" }, file3)
vim.cmd("edit " .. file3)
-- Snapshot the window set BEFORE the diff opens. If the scratch/card windows
-- don't genuinely CLOSE on accept (BUG, live-observed 2026-07-01: a window
-- fell back to a blank buffer instead of closing), the post-accept window set
-- would differ from this baseline even though the window COUNT might still
-- happen to match by coincidence — comparing the actual id sets catches both.
local function win_set()
	local s = {}
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		s[w] = true
	end
	return s
end
local function win_set_eq(a, b)
	for w in pairs(a) do
		if not b[w] then
			return false
		end
	end
	for w in pairs(b) do
		if not a[w] then
			return false
		end
	end
	return true
end
local wins_before_diff = win_set()
H.ext_write(file3, { "g1", "g2", "g3" })
D2.checktime_all()
vim.wait(200, function()
	return D2.state.current ~= nil
end)
H.check(
	"T19 card armed for existing-file edit before card-accept",
	claude.state.diff_card and claude.state.diff_card.display == "Modified: gamma.txt",
	vim.inspect(claude.state.diff_card)
)
claude._resolve_diff_card("accept")
vim.wait(200, function()
	return D2.state.current == nil
end)
H.check(
	"T19 accept-via-card wrote proposed content",
	table.concat(vim.fn.readfile(file3), "|") == "g1|g2|g3",
	table.concat(vim.fn.readfile(file3), "|")
)
H.check(
	"T19 accept-via-card leaves NO stray window (scratch+card fully closed)",
	win_set_eq(wins_before_diff, win_set()),
	vim.inspect(vim.tbl_keys(win_set())) .. " vs before " .. vim.inspect(vim.tbl_keys(wins_before_diff))
)
H.check(
	"T19 accept-via-card cleared the panel card",
	claude.state.diff_card == nil,
	vim.inspect(claude.state.diff_card)
)
H.check("T19 accept-via-card unlocked input (diff_pending false)", claude.state.diff_pending == false)

-- 19d: Reject via the card on a NEW file must DELETE it, exactly matching the
-- winbar's "reject (delete file)" wording/behaviour for new-file diffs.
D2.state.pending_new = {}
D2.state.new_files = {}
D2.state.current = nil
claude.state.diff_queue = {}
local newf3 = ws .. "/card_new.txt"
vim.fn.delete(newf3)
D2.watch(newf3)
vim.fn.writefile({ "x1" }, newf3)
D2.poll()
vim.wait(300, function()
	return D2.state.current ~= nil
end)
H.check(
	"T19 card armed for new-file kind before card-reject",
	claude.state.diff_card and claude.state.diff_card.display == "New file: card_new.txt",
	vim.inspect(claude.state.diff_card)
)
claude._resolve_diff_card("reject")
vim.wait(200, function()
	return D2.state.current == nil
end)
H.check("T19 reject-via-card deletes the new file", vim.fn.filereadable(newf3) == 0)
H.check(
	"T19 reject-via-card cleared the panel card",
	claude.state.diff_card == nil,
	vim.inspect(claude.state.diff_card)
)

-- ── T20: Issue-B pre-write gate — existing file, accept → allow + silent reload ─
-- open_prewrite shows disk (pristine) vs proposed (reconstructed from tool input);
-- NOTHING is on disk yet. accept_all releases the held can_use_tool request as
-- "allow" via claude.on_prewrite_resolve and flags the path approved so the FCS
-- fired by the CLI's subsequent write reloads silently instead of double-gating.

-- Hermetic start: earlier tests leave stale queue entries / pending paths behind
-- (T13 deliberately strands a failed reject; T17–T19 churn new-file state). The
-- pre-write flow must start from a clean slate or q-delta assertions misfire.
D2.state.current = nil
D2.state.scratch = nil
D2.state.orig_buf = nil
D2.state.pending_new = {}
D2.state.new_files = {}
D2.state.approved = {}
claude.state.diff_queue = {}
claude.state.diff_pending = false
-- Flush FCS debris too: earlier tests changed files on disk under still-loaded
-- buffers; the window churn during T20's mount would checktime them (nested
-- WinEnter autocmd) and queue THEIR diffs behind the pre-write review, polluting
-- the q-delta and reload assertions. Poll now and discard whatever surfaces.
D2.poll()
vim.wait(300)
while D2.state.current do
	local before = D2.state.current
	D2.accept_all()
	vim.wait(200, function()
		return D2.state.current ~= before
	end)
end
claude.state.diff_queue = {}

-- Safe to stub chansend now: T8's real terminal job is long finished, and the
-- stub is what lets us decode the control_response the resolve sends.
local pw_sends = {}
vim.fn.chansend = function(_, data)
	table.insert(pw_sends, data)
	return 1
end
claude.state.job_id = 4242
claude.state.working = false -- skip the spinner restart branch (no panel here)

local function last_pw_response()
	local ok, ev = pcall(vim.json.decode, pw_sends[#pw_sends] or "")
	if not ok or type(ev) ~= "table" or ev.type ~= "control_response" then
		return nil
	end
	return ev
end

local pwf = ws .. "/prewrite.txt"
vim.fn.writefile({ "p1", "p2", "p3" }, pwf)
claude.state.prewrite = { request_id = "pw-1", input = { file_path = pwf } }
local opened = D2.open_prewrite(pwf, { "p1", "P2-new", "p3" })
vim.wait(200, function()
	return D2.state.current ~= nil
end)
H.check(
	"T20 open_prewrite opens in prewrite mode",
	opened == true and D2.state.current == pwf and D2.state.prewrite == true and D2.state.kind == "edit",
	vim.inspect({ opened, D2.state.current, D2.state.prewrite, D2.state.kind })
)
H.check("T20 two diff windows up", diff_win_count() == 2, "wins=" .. diff_win_count())
H.check(
	"T20 scratch shows the PROPOSED (unwritten) content",
	H.buf_lines(D2.state.scratch) == "p1|P2-new|p3",
	H.buf_lines(D2.state.scratch)
)
H.check("T20 disk still pristine while reviewing", table.concat(vim.fn.readfile(pwf), "|") == "p1|p2|p3")
H.check("T20 second open_prewrite refused while one is up", D2.open_prewrite(pwf, { "x" }) == false)
H.check(
	"T20 panel card armed",
	claude.state.diff_card ~= nil and claude.state.diff_card.display == "Modified: prewrite.txt",
	vim.inspect(claude.state.diff_card)
)

D2.accept_all()
vim.wait(200, function()
	return D2.state.current == nil
end)
local pr1 = last_pw_response()
H.check(
	"T20 accept releases the held request as allow",
	pr1 and pr1.response.request_id == "pw-1" and pr1.response.response.behavior == "allow",
	vim.inspect(pr1)
)
H.check("T20 held request cleared", claude.state.prewrite == nil)
H.check("T20 diff closed + mode reset", D2.state.current == nil and D2.state.prewrite == false)
H.check(
	"T20 path flagged approved for the incoming write",
	D2.state.approved[pwf] == true,
	vim.inspect(D2.state.approved)
)

-- The CLI (allowed) now performs the write. poll's checktime must RELOAD the
-- loaded buffer silently — no second review of an already-approved change.
-- (q-delta can't be asserted: earlier tests' deleted-file buffers re-fire FCS on
-- EVERY checktime, so unrelated debris flows through the queue. Assert on the
-- approved path specifically instead.)
vim.fn.writefile({ "p1", "P2-new", "p3" }, pwf)
D2.poll()
vim.wait(300)
H.check(
	"T20 approved write reloads silently (log)",
	has_log("^fcs%-approved%-reload:"),
	table.concat(D2.state.log, ",")
)
local pwf_requeued = D2.state.current == pwf
for _, p in ipairs(claude.state.diff_queue) do
	if p == pwf then
		pwf_requeued = true
	end
end
H.check(
	"T20 approved write NOT re-reviewed (no queue/current entry)",
	not pwf_requeued,
	"current=" .. tostring(D2.state.current) .. " q=" .. vim.inspect(claude.state.diff_queue)
)
vim.wait(500, function()
	return H.buf_lines(vim.fn.bufnr(pwf)) == "p1|P2-new|p3"
end)
H.check(
	"T20 buffer reloaded to the approved content",
	H.buf_lines(vim.fn.bufnr(pwf)) == "p1|P2-new|p3",
	H.buf_lines(vim.fn.bufnr(pwf))
)
H.check("T20 approved flag is one-shot", D2.state.approved[pwf] == nil)

-- ── T21: pre-write gate — NEW file, reject → deny, nothing ever on disk ───────
local pwn = ws .. "/prewrite_new.txt"
claude.state.prewrite = { request_id = "pw-2", input = { file_path = pwn } }
local opened2 = D2.open_prewrite(pwn, { "n1", "n2" })
vim.wait(200, function()
	return D2.state.current ~= nil
end)
H.check(
	"T21 new-file prewrite opens as kind=new",
	opened2 == true and D2.state.kind == "new" and D2.state.prewrite == true,
	vim.inspect({ opened2, D2.state.kind, D2.state.prewrite })
)
H.check(
	"T21 'current' side is a scratch (no real-path buffer → no W13 trap)",
	D2.state.orig_buf and vim.bo[D2.state.orig_buf].buftype == "nofile",
	tostring(D2.state.orig_buf)
)
H.check(
	"T21 card says New file",
	claude.state.diff_card ~= nil and claude.state.diff_card.display == "New file: prewrite_new.txt",
	vim.inspect(claude.state.diff_card)
)

local orig_scratch = D2.state.orig_buf
D2.reject_all()
vim.wait(200, function()
	return D2.state.current == nil
end)
local pr2 = last_pw_response()
H.check(
	"T21 reject releases the held request as deny",
	pr2 and pr2.response.request_id == "pw-2" and pr2.response.response.behavior == "deny",
	vim.inspect(pr2)
)
H.check("T21 file never touched disk", vim.fn.filereadable(pwn) == 0)
H.check("T21 throwaway 'current' scratch wiped", not vim.api.nvim_buf_is_valid(orig_scratch))
H.check("T21 diff closed + card cleared", D2.state.current == nil and claude.state.diff_card == nil)

-- ── T22: pre-write gate — NEW file, accept → allow, reveal created file ───────
-- The buggy path pre-fix: accepting a new-file pre-write left NO buffer to catch
-- the CLI's async write, so close_diff restored the diff window to a blank
-- alternate buffer and the created file never appeared. accept_all now records
-- reveal_new; poll()→reveal_created opens the file once the write lands.
local pwn2 = ws .. "/prewrite_new_accept.txt"
vim.fn.delete(pwn2)
claude.state.prewrite = { request_id = "pw-3", input = { file_path = pwn2 } }
local opened3 = D2.open_prewrite(pwn2, { "created-1", "created-2" })
vim.wait(200, function()
	return D2.state.current ~= nil
end)
H.check(
	"T22 new-file prewrite opens as kind=new",
	opened3 == true and D2.state.kind == "new" and D2.state.prewrite == true,
	vim.inspect({ opened3, D2.state.kind, D2.state.prewrite })
)

D2.accept_all()
vim.wait(200, function()
	return D2.state.current == nil
end)
local pr3 = last_pw_response()
H.check(
	"T22 accept releases the held request as allow",
	pr3 and pr3.response.request_id == "pw-3" and pr3.response.response.behavior == "allow",
	vim.inspect(pr3)
)
H.check(
	"T22 new file recorded for reveal (no approved flag — no buffer to reload)",
	D2.state.reveal_new == pwn2 and D2.state.approved[pwn2] == nil,
	vim.inspect({ D2.state.reveal_new, D2.state.approved[pwn2] })
)

-- The CLI (allowed) now performs the write; poll reveals it in an editor window.
vim.fn.writefile({ "created-1", "created-2" }, pwn2)
D2.poll()
vim.wait(300)
H.check("T22 reveal_new cleared after reveal", D2.state.reveal_new == nil)
H.check(
	"T22 created file is open in a window with its content",
	vim.fn.bufwinid(vim.fn.bufnr(pwn2)) ~= -1 and H.buf_lines(vim.fn.bufnr(pwn2)) == "created-1|created-2",
	"winid=" .. vim.fn.bufwinid(vim.fn.bufnr(pwn2)) .. " content=" .. H.buf_lines(vim.fn.bufnr(pwn2))
)

-- ── T23: accept-time edit hunk anchors under its OWN header, not the tail ────
-- Live bug 2026-07-16 (screenshot: edit-advisoring-issue.png): while a
-- post-write review sat open, the model escalated to the advisor mid-turn —
-- "● Advising using <model>" + the "Consulting" activity line streamed into
-- the transcript BEFORE the user accepted the review. render_edit_block used
-- to buf_append at the (by-then-moved) buffer tail, so the edit's own hunk
-- rendered nested under "● Advising" instead of under its own "● Edit(...)"
-- header. Fixed via an anchor extmark (claude_diff.watch → mark_anchor)
-- captured at the header's own trailing-blank line; render_edit_hunk inserts
-- there instead of appending at the tail. This drives claude.render_edit_block
-- (== render.render_edit_hunk) DIRECTLY — not through accept_all's pcall,
-- which would swallow a throw and let a broken insert pass silently.
local anchor_panel = vim.api.nvim_create_buf(false, true)
claude.state.panel_buf = anchor_panel
vim.bo[anchor_panel].modifiable = true
vim.api.nvim_buf_set_lines(anchor_panel, 0, -1, false, {
	"● Edit(alpha.txt)", -- 0: the edit's own header
	"", -- 1: its trailing blank == the anchor
	"● Advising using Opus 4.8", -- 2: streamed in WHILE the review sat open
	"  └ Consulting", -- 3
	"", -- 4
})
vim.bo[anchor_panel].modifiable = false
local anchor_row = 1 -- 0-indexed: the blank line right after the Edit header

-- Bookkeeping BELOW the anchor that is plain-line-keyed, not extmark-backed —
-- seeded to prove shift_line_bookkeeping rekeys both after the mid-buffer
-- insert (Vim's own fold ranges shift on their own; these two tables don't).
claude.state.folds = { [4] = "3.2s" } -- 1-indexed fold-start key
claude.state.subagents = { { header_lnum = 3, model = nil } } -- 0-indexed, rewrite pending

claude.render_edit_block("alpha.txt", { "a1", "a2", "a3" }, { "a1", "aX", "a3" }, anchor_row)

local out = vim.api.nvim_buf_get_lines(anchor_panel, 0, -1, false)
local advising_idx = nil
for i, l in ipairs(out) do
	if l:match("● Advising") then
		advising_idx = i - 1
		break
	end
end
H.check("T23 'Advising' header still present after the hunk insert", advising_idx ~= nil, vim.inspect(out))

local hunk_before, hunk_after = 0, 0
if advising_idx then
	for i, l in ipairs(out) do
		if l:match("^%s*%d+ [%+%-] ") then
			if (i - 1) < advising_idx then
				hunk_before = hunk_before + 1
			else
				hunk_after = hunk_after + 1
			end
		end
	end
end
H.check(
	"T23 hunk lines land BEFORE 'Advising', none after (anchor path taken, not tail fallback)",
	hunk_before > 0 and hunk_after == 0,
	"before=" .. hunk_before .. " after=" .. hunk_after .. " out=" .. vim.inspect(out)
)

local shift = advising_idx and (advising_idx - 2) or 0 -- "Advising" started at 0-indexed row 2
H.check(
	"T23 fold duration key rekeyed by the insert shift",
	claude.state.folds[4] == nil and claude.state.folds[4 + shift] == "3.2s",
	vim.inspect(claude.state.folds)
)
H.check(
	"T23 pending subagent header_lnum rekeyed by the insert shift",
	claude.state.subagents[1].header_lnum == 3 + shift,
	vim.inspect(claude.state.subagents)
)

claude.state.folds = {}
claude.state.subagents = nil
claude.state.panel_buf = nil

-- ── T24: abandoned review recovers (deadlock safety net) ────────────────────
-- Live deadlock 2026-07-16: if a review window is closed WITHOUT going through
-- accept/reject (a bare `:q`, a layout change), close_diff never runs, so
-- diff_pending sticks true forever — the chat bar wedges ("⚠ Awaiting review")
-- and <leader>ca/cx are bound to a scratch buffer no longer on screen. The
-- WinClosed safety net must catch the stray close, unlock input, and — because
-- the CLI already wrote disk — KEEP Claude's change (never revert on abandon).
D.state.current = nil
H.ext_write(file1, { "aband1", "aband2" })
D.checktime_all()
vim.wait(300, function()
	return D.state.current ~= nil
end)
H.check(
	"T24 diff open + input locked",
	D.state.current == file1 and claude.state.diff_pending == true,
	"current=" .. tostring(D.state.current) .. " pending=" .. tostring(claude.state.diff_pending)
)
local aband_scratch_win = D.state.scratch_win
-- Simulate the user closing the diff window directly (NOT accept/reject).
pcall(vim.api.nvim_win_close, aband_scratch_win, true)
vim.wait(300, function()
	return D.state.current == nil
end)
H.check("T24 abandon recovered diff state", D.state.current == nil, "current=" .. tostring(D.state.current))
H.check(
	"T24 abandon unlocked the input bar",
	claude.state.diff_pending == false,
	"pending=" .. tostring(claude.state.diff_pending)
)
H.check(
	"T24 abandon KEPT Claude's change on disk (no revert)",
	table.concat(vim.fn.readfile(file1), "|") == "aband1|aband2",
	table.concat(vim.fn.readfile(file1), "|")
)

-- ── T25: orig buffer is read-only while under review (stale-write guard) ─────
-- The orig buffer is deliberately held at pre-edit content for the diff while
-- the CLI rewrites disk (autoread off). A stray `:w`/autowriteall of that stale
-- buffer would revert the CLI's write (the CLAUDE.md "modified since read" loop).
-- It must be 'readonly' for the life of the review and restored on resolve.
local ro_prior = vim.bo[buf1].readonly
H.ext_write(file1, { "ro1", "ro2" })
D.checktime_all()
vim.wait(300, function()
	return D.state.current ~= nil
end)
H.check(
	"T25 orig buffer readonly during review",
	vim.bo[buf1].readonly == true,
	"readonly=" .. tostring(vim.bo[buf1].readonly)
)
D.accept_all()
vim.wait(300, function()
	return D.state.current == nil
end)
H.check(
	"T25 accept still succeeded despite readonly (write! punches through)",
	H.buf_lines(buf1) == "ro1|ro2",
	H.buf_lines(buf1)
)
H.check(
	"T25 orig readonly restored to its prior value after resolve",
	vim.bo[buf1].readonly == ro_prior,
	"readonly=" .. tostring(vim.bo[buf1].readonly) .. " prior=" .. tostring(ro_prior)
)

-- ── T26: watch() return-value CONTRACT — locks the boolean render.lua depends on ──
-- render.lua's MultiEdit/NotebookEdit branch trusts watch()'s return value to decide
-- auto-allow vs permission-card fallback (claude_spec.lua T31 proves that wiring with
-- a stub). This test proves the REAL watch() actually reports each branch correctly —
-- a silently-dropped `return true`/`return false` here would either spam the card on
-- every legitimate edit or silently reopen the blind-allow hole, and nothing else
-- would catch it.
claude.state.claude_active = true
H.check("T26 watch(nil) returns false", D.watch(nil) == false)
H.check("T26 watch('') returns false", D.watch("") == false)

claude.state.claude_active = false
local existing = ws .. "/t26_existing.txt"
vim.fn.writefile({ "line1" }, existing)
H.check("T26 watch() returns false when the panel is inactive", D.watch(existing) == false)
claude.state.claude_active = true

H.check("T26 watch() returns true for a real existing file (bufload succeeds)", D.watch(existing) == true)
vim.fn.delete(existing)

H.summary("claude_diff")
