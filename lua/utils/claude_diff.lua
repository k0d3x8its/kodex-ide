-- lua/utils/claude_diff.lua
-- Goal 7: intercepted FileChangedShell → queued vimdiff per file.
-- Adapted from lua/utils/opencode_diff.lua — same mechanism, different panel.
--
-- Mechanism prototype-validated 2026-06-11 (proto/, 9 hard cases) — the five
-- CORRECTION comments below are load-bearing; removing any of them silently
-- kills the interceptor. See proto/PROTO-NOTES.md.
--
-- Why a separate module rather than extending opencode_diff.lua?
--   Augroup names must be distinct (FINDINGS.md § A4 / Goal 7 MG 7.1): two
--   modules sharing the same augroup name means the second `clear=true`
--   registration wipes the first's autocmds. OpencodeDiff and ClaudeDiff are
--   independent interception sessions for independent panels.
--
-- v1 limitation (accepted, FINDINGS.md Q6): files NOT open in a buffer —
-- including new files Claude creates — fire no FileChangedShell at all;
-- their changes land on disk silently (gitsigns still shows them).
-- An fs_event watcher is a TODOS.md backlog item.

local M = {}

-- Shared panel state: claude_active gates the interceptor, diff_queue holds
-- pending file paths. Owned by utils/claude so reset() can clear both.
local claude = require("utils.claude")
-- core.opts.width_pct: the panel's designed width fraction, needed directly
-- (not via core.panel_width()) because that function prefers the LIVE window
-- width when one exists — exactly wrong right after a squashing split, where
-- the live width IS the squashed value we're trying to correct.
local core = require("utils.claude.core")

M.state = {
  current  = nil,   -- file currently shown in diff
  scratch  = nil,   -- scratch buffer id of current diff
  orig_buf = nil,   -- original buffer id of current diff
  kind     = "edit",-- "edit" (existing file changed) | "new" (Claude-created file)
  debug    = false, -- when true, events append to .log (port-verification only)
  log      = {},
  -- MG 14.2 new-file path: files Claude is ABOUT to create (watch saw them not yet
  -- on disk). sweep_new() promotes each to new_files + the diff queue once it lands.
  pending_new = {}, -- abs path → true, awaiting creation on disk
  new_files   = {}, -- abs path → true, queued/open as a whole-file-additions diff
  -- Issue-B pre-write gate (prototype: Write/Edit). When true, the open diff shows
  -- content reconstructed from the tool INPUT — the file is NOT yet written. Accept
  -- releases the held can_use_tool request as "allow" (the CLI then writes), reject
  -- as "deny" (nothing ever touches disk). MultiEdit/NotebookEdit stay post-write.
  prewrite = false,
  -- abs path → true: an approved pre-write edit is about to land on disk. The FCS
  -- interceptor consumes the flag and silently reloads instead of queueing a diff —
  -- without this the approved write would be double-gated by the post-write flow.
  approved = {},
  -- abs path of an approved pre-write NEW file, awaiting reveal. Unlike an edit
  -- (whose loaded buffer FCS-reloads), a new file has no buffer to repaint, so
  -- poll() opens it in an editor window once the CLI's write lands. Single-shot.
  reveal_new = nil,
  -- Pre-write NEW-file teardown bookkeeping (set in mount_diff, consumed in
  -- close_diff). The throwaway orig scratch has no file worth keeping, so the
  -- window it lives in must be returned to its pre-diff state WITHOUT relying on
  -- `buffer #`: when the panel was the only window, mount_diff splits off the
  -- panel, making the panel buffer that window's alternate — `buffer #` then
  -- resurrects the panel (a phantom 2nd panel column, live-observed 2026-07-03).
  orig_win_created = nil, -- win id we created via `topleft vsplit` (panel-only), else nil
  orig_prev_buf    = nil, -- buffer a REUSED editor window showed before the diff
  -- Anchor for the accept-time transcript hunk (render.render_edit_block): an
  -- extmark on the tool header's own trailing blank line, captured the instant
  -- watch() runs (which is always right after render_tool appends that header —
  -- see the EDIT_NAMES branch in render.lua's dispatch). accept_all() can fire
  -- much later, after arbitrary other content (e.g. an advisor escalation)
  -- streamed past that point; without this the hunk lands wherever the buffer
  -- TAIL happens to be instead of under its own header (live bug 2026-07-16).
  anchor_mark = nil,
  anchor_buf  = nil,
  -- Window ids of the CURRENT review, captured at mount. A WinClosed on either
  -- that did NOT go through accept/reject (user `:q` on the diff, a layout change)
  -- means the review was abandoned — recover_abandoned then unlocks the input bar
  -- so diff_pending can't stick true forever (the wedged chat bar + dead
  -- <leader>ca/cx deadlock, live-observed 2026-07-16).
  orig_win    = nil,
  scratch_win = nil,
  -- The orig file buffer is deliberately HELD at pre-edit content for the diff's
  -- "before" side while the CLI rewrites disk (autoread is off — see
  -- on_panel_open). A stray `:w` or an autowriteall of that stale buffer would
  -- OVERWRITE the CLI's write and revert Claude's edit (root cause of the
  -- CLAUDE.md "modified since read" retry loop, 2026-07-16). We set the buffer
  -- 'readonly' for the life of the review; this holds the prior value so
  -- close_diff can restore it.
  orig_prev_readonly = nil,
}

local anchor_ns = vim.api.nvim_create_namespace("claude_diff_anchor")

-- Reentrancy guard for the WinClosed safety net (below): true only while
-- close_diff is tearing the review down ITSELF — it closes the scratch window,
-- which fires WinClosed. Without this the safety-net autocmd would re-enter
-- close_diff on that self-inflicted close. See the WinClosed autocmd in
-- ensure_autocmds.
local in_close = false

local function log(msg)
  if M.state.debug then
    table.insert(M.state.log, msg)
  end
end

-- Mark "right here" in the panel transcript as where a hunk for the CURRENT
-- review belongs. Called at the top of watch() — the only two call sites
-- (render.lua's ordinary post-write path and the gated-fallback path) both run
-- immediately after the tool's own header block was appended, so the buffer
-- tail at this instant IS that header's trailing blank line.
local function mark_anchor()
  local buf = claude.state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 1 then return end
  M.state.anchor_mark = vim.api.nvim_buf_set_extmark(buf, anchor_ns, n - 1, 0, {})
  M.state.anchor_buf  = buf
end

-- Fetched live, never cached: claude.reset() replaces the diff_queue table
-- wholesale. Caching the reference here would point at the old (cleared) table.
local function queue()
  return claude.state.diff_queue
end

-- ─────────────────────────────────────────────────────────────────── queue logic

function M.push(path)
  if M.state.current == path then
    log("dedup-current:" .. path)
    return
  end
  for _, p in ipairs(queue()) do
    if p == path then
      log("dedup-queue:" .. path)
      return
    end
  end
  table.insert(queue(), path)
  log("queued:" .. path)
end

-- MG 14.2: pre-load a file Claude is ABOUT to edit into a listed + loaded buffer
-- so the FileChangedShell interceptor catches the CLI's subsequent disk write.
--
-- Closes v1's blind spot (FINDINGS.md Q6 / header): an Edit/Write to a file with
-- no buffer fired no FCS, so the change landed on disk silently. The dispatcher
-- calls this on the tool_use block — which the stream always emits BEFORE the
-- tool executes — so bufload reads the PRE-edit content (or an empty buffer for a
-- new file Claude is creating). When the CLI then writes, checktime_all sees the
-- mtime change and queues the diff: a new file diffs against the empty buffer =
-- whole file as additions.
function M.watch(path)
  if not path or path == "" then return end
  if not claude.state.claude_active then return end
  mark_anchor()
  -- Absolute + slash-normalised so bufadd matches the name checktime/FCS report
  -- (a relative path would create a SECOND buffer for the same file → no FCS on
  -- the one we loaded).
  local abs = vim.fn.fnamemodify(path, ":p")
  -- A file that does NOT exist yet can't use the FileChangedShell mechanism:
  -- bufload'ing a nonexistent path flags the buffer BF_NEW, and when Claude then
  -- creates it on disk `checktime` raises a blocking W13 confirm dialog and SKIPS
  -- FileChangedShell entirely (proven headless). So DON'T pre-load new files —
  -- record them as pending instead; sweep_new() (run from poll() after the CLI
  -- finishes a tool) picks up the created file and opens a whole-file-additions
  -- diff directly, bypassing FCS/W13 entirely.
  if vim.fn.filereadable(abs) == 0 then
    M.state.pending_new[abs] = true
    log("watch-new-pending:" .. abs)
    return
  end
  local bufnr = vim.fn.bufadd(abs)          -- listed buffer, may be unloaded
  if bufnr == 0 then
    log("watch-bufadd-failed:" .. abs)
    return
  end
  vim.fn.bufload(bufnr)                      -- read current content (empty if new)
  log("watch:" .. abs)
end

-- ───────────────────────────────────────────────────────────────── diff window

local function close_diff()
  local s = M.state
  -- Mark the teardown in progress so the WinClosed safety net doesn't re-enter
  -- when we close the scratch window ourselves below.
  in_close = true
  -- Restore the orig buffer's writability before any teardown — a new-file orig
  -- gets wiped further down, so restore while it is still valid.
  if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf)
      and s.orig_prev_readonly ~= nil then
    vim.bo[s.orig_buf].readonly = s.orig_prev_readonly
  end
  if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf) then
    local win = vim.fn.bufwinid(s.orig_buf)
    if win ~= -1 then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
      -- Restore the default (global) highlight namespace: the orig window may be
      -- a REUSED editor window that outlives the diff. Leaving the red lens on it
      -- would tint its normal content after the diff closes. (0 = default ns.)
      pcall(vim.api.nvim_win_set_hl_ns, win, 0)
    end
  end
  if s.scratch and vim.api.nvim_buf_is_valid(s.scratch) then
    -- Close the window EXPLICITLY rather than relying on nvim_buf_delete's
    -- window-buffer fallback: deleting a buffer that's displayed in a window
    -- does NOT reliably close that window — Neovim can instead leave the
    -- window open showing a blank/alternate buffer (BUG, live-observed
    -- 2026-07-01: a stray blank pane stayed open where the diff used to be,
    -- instead of the diff column closing and returning to the editor). Close
    -- the window first to remove the ambiguity; deleting the now-hidden
    -- scratch buffer after is a clean wipe with nothing left to fall back to.
    local swin = vim.fn.bufwinid(s.scratch)
    if swin ~= -1 and vim.api.nvim_win_is_valid(swin) then
      pcall(vim.api.nvim_win_close, swin, true)
    end
    if vim.api.nvim_buf_is_valid(s.scratch) then
      pcall(vim.api.nvim_buf_delete, s.scratch, { force = true })
    end
  end
  -- Pre-write new-file case: the "current" side is a throwaway scratch (a real-path
  -- buffer would be BF_NEW and trip W13 on the post-approval checktime). Wipe it —
  -- unlike the post-write orig, there's no file content worth keeping on screen.
  -- The window must be MOVED OFF the scratch first: when it's the only normal
  -- window and a float (the review card) is focused, nvim_buf_delete silently
  -- no-ops — it returns success but the buffer stays valid (live-reproduced).
  -- Do NOT use `buffer #` here: when the panel was the only window at mount time,
  -- mount_diff split off the panel, so this window's alternate IS the panel buffer
  -- → `buffer #` resurrects the panel (phantom 2nd panel column, live-observed
  -- 2026-07-03). Instead: close a window we created; restore the tracked prior
  -- buffer for a reused window; fresh empty buffer as the last resort.
  if s.prewrite and s.kind == "new"
      and s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf) then
    local w = vim.fn.bufwinid(s.orig_buf)
    if s.orig_win_created and vim.api.nvim_win_is_valid(s.orig_win_created)
        and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      -- We opened this window by splitting off the panel; remove it entirely.
      pcall(vim.api.nvim_win_close, s.orig_win_created, true)
    elseif w ~= -1 then
      local prev = s.orig_prev_buf
      if prev and vim.api.nvim_buf_is_valid(prev)
          and prev ~= claude.state.panel_buf then
        pcall(vim.api.nvim_win_set_buf, w, prev)
      else
        pcall(vim.api.nvim_win_set_buf, w, vim.api.nvim_create_buf(true, false))
      end
    end
    pcall(vim.api.nvim_buf_delete, s.orig_buf, { force = true })
  end
  if s.current then M.state.new_files[s.current] = nil end
  s.current, s.scratch, s.orig_buf = nil, nil, nil
  s.orig_win_created, s.orig_prev_buf = nil, nil
  s.orig_win, s.scratch_win = nil, nil
  s.orig_prev_readonly = nil
  s.kind = "edit"
  s.prewrite = false
  s.anchor_mark, s.anchor_buf = nil, nil
  -- Notify the Claude panel that the diff is resolved so it can unlock the
  -- input bar (MG 7.2 — mirrors the on_diff_open call in open_diff below).
  claude.on_diff_close()
  in_close = false
  vim.schedule(M.process_next)
end

function M.accept_all()
  local s = M.state
  -- Capture before/after for the post-approval transcript block (Goal 14.4)
  -- NOW, before any mutation below overwrites orig_buf. Both buffers are pristine
  -- in every accept path (prewrite: orig=disk / scratch=proposed; post-write:
  -- orig=old buffer / scratch=new disk). Rendered only after a SUCCESSFUL accept;
  -- pcall so a render failure can never block the accept/write flow.
  local blk_path, blk_old, blk_new
  if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf)
      and s.scratch and vim.api.nvim_buf_is_valid(s.scratch) then
    blk_path = s.current   -- for filetype → treesitter language of the block
    blk_old  = vim.api.nvim_buf_get_lines(s.orig_buf, 0, -1, false)
    blk_new  = vim.api.nvim_buf_get_lines(s.scratch, 0, -1, false)
  end
  -- Captured before close_diff() below resets s.kind. A NEW-file Write already
  -- rendered its content inline as a numbered body at tool_use time
  -- (render.render_write_body), so the accept-time red/green hunk would double it up.
  local is_new = s.kind == "new"
  -- Resolve the anchor NOW, before close_diff() below can reset it — the
  -- extmark tracks the header's blank line through anything that streamed
  -- in while this review sat open (see mark_anchor()).
  local anchor_row
  if s.anchor_mark and s.anchor_buf and vim.api.nvim_buf_is_valid(s.anchor_buf) then
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id,
      s.anchor_buf, anchor_ns, s.anchor_mark, {})
    if ok and pos and pos[1] then anchor_row = pos[1] end
  end
  local function emit_transcript_block()
    if is_new then return end
    if blk_old and blk_new then
      pcall(claude.render_edit_block, blk_path, blk_old, blk_new, anchor_row)
    end
  end
  -- Pre-write gate: nothing to write — accepting RELEASES the held permission
  -- request as "allow"; the CLI does the write itself right after. Flag the path
  -- approved first so the FCS the write triggers reloads silently (no second diff).
  if s.prewrite then
    if s.current and s.kind ~= "new" then
      M.state.approved[s.current] = true
    elseif s.current and s.kind == "new" then
      -- New file: no real-path buffer catches the CLI's async write (one would be
      -- BF_NEW and trip W13, the trap open_prewrite dodges with a throwaway scratch),
      -- so the FCS approved-reload path can't run. Without this, close_diff restores
      -- the diff window to a blank alternate buffer and the created file never shows
      -- (live-observed 2026-07-01: new-file approve left a blank page on screen).
      -- Record the path; poll() reveals it in an editor window once the write lands.
      M.state.reveal_new = s.current
    end
    log("prewrite-accept:" .. tostring(s.current))
    claude.on_prewrite_resolve(true)
    close_diff()
    emit_transcript_block()
    return
  end
  -- The original buffer can be :bd'd while the scratch diff is still open;
  -- writing into an invalid buffer throws. Bail to the next queue item instead.
  if not (s.scratch  and vim.api.nvim_buf_is_valid(s.scratch)
      and s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf)) then
    log("accept-all-skipped-invalid:" .. tostring(s.current))
    close_diff()
    return
  end
  local lines = vim.api.nvim_buf_get_lines(s.scratch, 0, -1, false)
  vim.api.nvim_buf_set_lines(s.orig_buf, 0, -1, false, lines)
  -- CORRECTION #5: bang required — disk changed since last *read*, and the FCS
  -- event doesn't sync the read-timestamp the overwrite check uses. Plain :w
  -- prompts "changed since reading it!!!" and blocks the UI.
  local name = vim.fn.fnamemodify(s.current or "?", ":t")
  local ok, err = pcall(vim.api.nvim_buf_call, s.orig_buf, function()
    vim.cmd("silent write!")
  end)
  if not ok then
    -- write failed (perms, disk full): the accepted content is in the buffer
    -- but NOT on disk. Warn and keep the diff open so the user can retry,
    -- rather than advancing as if the write succeeded.
    log("accept-all-FAILED:" .. tostring(err))
    vim.schedule(function()
      vim.notify(
        "Claude: write FAILED for " .. name .. " — " .. tostring(err),
        vim.log.levels.ERROR
      )
    end)
    return
  end
  log("accept-all:" .. s.current)
  close_diff()
  emit_transcript_block()
end

function M.reject_all()
  local s = M.state
  -- Pre-write gate: the file was never written — rejecting DENIES the held
  -- permission request and the CLI moves on. No disk revert, no file delete.
  if s.prewrite then
    log("prewrite-reject:" .. tostring(s.current))
    claude.on_prewrite_resolve(false)
    close_diff()
    return
  end
  -- New file: rejecting means it should NOT exist. Delete it from disk (writing
  -- the empty orig back would leave a stray empty file) and wipe its buffer.
  if s.kind == "new" then
    local path = s.current
    local name = vim.fn.fnamemodify(path or "?", ":t")
    -- vim.fn.delete returns 0 on success, -1 on failure (it does not raise).
    if path and vim.fn.delete(path) ~= 0 then
      log("reject-new-FAILED:" .. tostring(path))
      vim.schedule(function()
        vim.notify(
          "Claude: delete FAILED for " .. name .. " — new file still on disk",
          vim.log.levels.ERROR
        )
      end)
      return
    end
    if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf) then
      pcall(vim.api.nvim_buf_delete, s.orig_buf, { force = true })
    end
    log("reject-new-deleted:" .. tostring(path))
    close_diff()
    return
  end
  if not (s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf)) then
    close_diff()
    return
  end
  -- Claude already wrote the file: closing without writing leaves disk modified
  -- → next checktime re-queues the same file forever. Write original buffer
  -- content back to disk to neutralize (bang: see CORRECTION #5 above).
  local name = vim.fn.fnamemodify(s.current or "?", ":t")
  local ok, err = pcall(vim.api.nvim_buf_call, s.orig_buf, function()
    vim.cmd("silent write!")
  end)
  if not ok then
    -- write failed → Claude's changes are STILL on disk. Silently advancing
    -- here would make the user believe the revert succeeded (data loss). Warn
    -- loudly and keep the diff open so they can fix the cause and retry.
    log("reject-all-FAILED:" .. tostring(err))
    vim.schedule(function()
      vim.notify(
        "Claude: revert FAILED for " .. name
          .. " — changes still on disk: " .. tostring(err),
        vim.log.levels.ERROR
      )
    end)
    return
  end
  log("reject-all:" .. s.current)
  close_diff()
end

-- A review's windows were closed OUTSIDE accept/reject (user `:q` on the diff, a
-- layout change). close_diff never ran, so diff_pending would stick true forever —
-- the chat bar refuses input ("⚠ Awaiting review") and <leader>ca/cx are bound to a
-- scratch buffer no longer reachable on screen. Recover by resolving the held state
-- so input unlocks:
--   prewrite — a can_use_tool request is still armed; DENY it (reject_all's prewrite
--     branch releases it and writes NOTHING to disk) so the CLI isn't left blocked.
--   post-write — the CLI already wrote disk; abandoning review KEEPS that change, so
--     just tear down state (close_diff). Never revert here — that is reject's job.
local function recover_abandoned()
  local s = M.state
  if s.current == nil then return end
  log("recover-abandoned:" .. tostring(s.current))
  if s.prewrite then
    M.reject_all()
  else
    close_diff()
  end
end

-- Pick a normal editor window to host the diff — never the Claude panel and
-- never a terminal. RC1 (claude.lua tool_result poll) now fires checktime while
-- focus is in the Claude terminal panel, so the current window is NOT safe to
-- reuse: `:buffer` there would eat the panel AND leave state.panel_win showing
-- the wrong buffer (render_thinking's fold then hits E16). Returns a win id, or
-- nil when the panel is the only window (caller must create a split).
local function editor_win()
  local panel = claude.state.panel_win
  local cur = vim.api.nvim_get_current_win()
  -- Prefer the current window when it already qualifies (pre-RC1 behaviour:
  -- checktime fired from WinEnter, so focus was a real editor window).
  local order = { cur }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= cur then table.insert(order, w) end
  end
  for _, w in ipairs(order) do
    if vim.api.nvim_win_is_valid(w)
        and w ~= panel
        and vim.api.nvim_win_get_config(w).relative == "" -- not floating
        and vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= "terminal" then
      return w
    end
  end
  return nil
end

-- Shared window mount for BOTH diff flavours (post-write open_diff and pre-write
-- open_prewrite): host the orig buffer in a real editor window, split the scratch
-- (proposed) to its right, diffthis both, wrap, lenses, winbar, keymaps.
local function mount_diff(buf, scratch, is_new, prewrite)
  -- Reset teardown bookkeeping for this mount (see M.state field docs).
  M.state.orig_win_created = nil
  M.state.orig_prev_buf    = nil

  local win = vim.fn.bufwinid(buf)
  local created_win = false
  if win ~= -1 then
    -- Orig buffer already on screen: focus its window.
    vim.api.nvim_set_current_win(win)
  else
    -- Orig buffer is off-screen (unopened/pre-loaded file). Host the diff in a
    -- real editor window, NOT the current one — post-RC1 the current window is
    -- often the Claude terminal panel, and :buffer there hijacks the panel.
    local target = editor_win()
    if target then
      vim.api.nvim_set_current_win(target)
      -- Record the buffer this reused window showed so close_diff can restore it
      -- exactly (the throwaway new-file orig gets wiped; `buffer #` is unreliable).
      M.state.orig_prev_buf = vim.api.nvim_win_get_buf(target)
    else
      -- Panel is the only window: open an editor split to its LEFT so the panel
      -- stays put on the right where it lives. `vsplit` splits the CURRENT
      -- window in half — and the panel IS current here (it's the only window)
      -- — so this halves the panel itself. Restored to its designed width below
      -- (see the comment after the scratch split lands).
      vim.cmd("topleft vsplit")
      created_win = true
    end
    vim.cmd("buffer " .. buf)
  end
  vim.cmd("diffthis")
  local orig_win = vim.api.nvim_get_current_win()
  M.state.orig_win = orig_win
  -- A window WE created off the panel must be CLOSED on teardown, not have a
  -- buffer restored into it (its alternate is the panel buffer → phantom panel).
  if created_win then M.state.orig_win_created = orig_win end
  -- Hold the orig buffer read-only for the life of the review so a stray `:w` or
  -- an autowriteall of its (deliberately stale) content can't overwrite disk and
  -- revert the CLI's write. accept_all/reject_all use `write!` (CORRECTION #5), so
  -- they punch through this unchanged; close_diff restores the prior value.
  M.state.orig_prev_readonly = vim.bo[buf].readonly
  vim.bo[buf].readonly = true
  log("mount-branch:" .. (created_win and "only-window"
    or (win ~= -1 and "buf-onscreen" or "reused-target")))
  vim.cmd("rightbelow vsplit")
  vim.api.nvim_win_set_buf(0, scratch)
  vim.cmd("diffthis")

  -- Live bug (screenshots 2026-07-16): the Claude panel gets squashed when a
  -- diff mounts, compounding on each subsequent diff, until the panel is
  -- closed and reopened. Confirmed empirically (headless repro) for the
  -- only-window branch (`topleft vsplit` splits the CURRENT window, and the
  -- panel IS current there since it's the only window — winfixwidth guards
  -- against automatic resizes elsewhere, not an explicit split of the fixed
  -- window itself). NOT independently confirmed against the reused-window
  -- branch in a real session (a bare `-u NONE` headless harness loads none of
  -- this plugin's own autocmds, so it can't rule out an interaction there) —
  -- resize unconditionally rather than gate on the branch, since restoring an
  -- already-correct width is a harmless no-op. `mount-branch` above records
  -- which path fired; enable `M.state.debug = true` and inspect `.log` to
  -- confirm which branch the real squash comes from if it recurs.
  local panel_win = claude.state.panel_win
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    local designed_w = math.floor(vim.o.columns * core.opts.width_pct)
    vim.api.nvim_win_set_width(panel_win, designed_w)
    log("panel-w-after:" .. vim.api.nvim_win_get_width(panel_win)
      .. " designed:" .. designed_w)
  end

  -- Wrap long lines INSIDE each diff column (BUG: proposed/original content ran
  -- off the right edge past the user's view). diffthis leaves the global `wrap`
  -- value, which is off in this config — force it on per-window. `linebreak`
  -- breaks at word boundaries; `breakindent` keeps wrapped rows visually nested
  -- under their source line so the diff stays readable. Tradeoff: wrapped rows
  -- can nudge left/right column alignment apart on very long lines — acceptable
  -- vs. content the user can't see at all.
  local scratch_win = vim.api.nvim_get_current_win()
  M.state.scratch_win = scratch_win
  for _, w in ipairs({ orig_win, scratch_win }) do
    vim.wo[w].wrap        = true
    vim.wo[w].linebreak   = true
    vim.wo[w].breakindent = true
  end

  -- Red/green colour lenses (plugins/claude.lua): apply the RED lens to the orig
  -- window (its diff-unique lines are removals) and the GREEN lens to the scratch
  -- window (its diff-unique lines are additions). This is the ONLY way to get
  -- asymmetric red-removed / green-added out of vim's symmetric diff — the Diff*
  -- groups are resolved per-window, so a per-window namespace recolours each side
  -- independently. Guarded: the namespaces are nil under a bare engine load (tests
  -- / headless without the plugin spec) — skip rather than error, diff still works
  -- with the colorscheme's default groups.
  local del_ns = claude.state.diff_del_ns
  local add_ns = claude.state.diff_add_ns
  if del_ns and add_ns then
    pcall(vim.api.nvim_win_set_hl_ns, orig_win, del_ns)
    pcall(vim.api.nvim_win_set_hl_ns, scratch_win, add_ns)
  end

  -- MG 7.2: winbar on the scratch window so the user always knows what to do
  -- without reading a notify that may have scrolled away.
  -- Post-write new-file reject DELETES the file (it shouldn't exist); pre-write
  -- wording says approve/deny — nothing is on disk yet either way.
  local winbar
  if prewrite then
    winbar = is_new
      and "⚠ Claude proposes new file  │  <leader>ca approve & create  │  <leader>cx deny"
      or  "⚠ Claude proposes  │  <leader>ca approve & write  │  <leader>cx deny"
  else
    winbar = is_new
      and "⚠ Claude created (new file)  │  <leader>ca accept all  │  <leader>cx reject (delete file)"
      or  "⚠ Claude proposed  │  <leader>ca accept all  │  <leader>cx reject all"
  end
  vim.wo[scratch_win].winbar = winbar

  -- Buffer-local on the scratch only (FINDINGS.md Q10) — auto-removed on close.
  vim.keymap.set("n", "<leader>ca", M.accept_all,
    { buffer = scratch, desc = "Claude diff: accept all" })
  vim.keymap.set("n", "<leader>cx", M.reject_all,
    { buffer = scratch, desc = "Claude diff: reject all" })

  -- Land on the FIRST change instead of line 1 — vimdiff opens both panes at the
  -- top, so a change deep in the file is off-screen until the user hunts for it.
  -- From the top, jump to the next hunk with `]c` UNLESS line 1 is itself part of a
  -- change (a pure-addition new file, or an edit at the very top) — `]c` would then
  -- skip past the first hunk to the second. `diff_hlID(lnum,1) > 0` means the line is
  -- diff-highlighted (changed). Run in the orig window so the scroll-bound scratch
  -- pane reveals the same hunk; `zz` centers it. keepjumps keeps the jumplist clean.
  pcall(vim.api.nvim_win_call, orig_win, function()
    vim.cmd("keepjumps normal! gg")
    if vim.fn.diff_hlID(vim.fn.line("."), 1) <= 0 then
      vim.cmd("keepjumps normal! ]c")
    end
    vim.cmd("normal! zz")
  end)
end

local function open_diff(path)
  local s = M.state
  local is_new = M.state.new_files[path] == true

  local buf
  if is_new then
    -- Claude CREATED this file: no pre-existing buffer. Add + load one for the
    -- path (it exists on disk now — sweep_new only queues readable paths), then
    -- blank it below so the "original" side reads as empty and the diff renders
    -- the whole file as additions.
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
  else
    buf = vim.fn.bufnr(path)
    if buf == -1 then
      log("no-buffer:" .. path) -- v1 limitation: see header comment
      vim.schedule(M.process_next) -- don't strand the rest of the queue
      return
    end
  end
  -- Claude may have DELETED the file (FCS fires for deletion too); readfile
  -- then throws inside this scheduled callback. Skip and drain the queue.
  local ok, disk = pcall(vim.fn.readfile, path)
  if not ok then
    log("readfile-failed:" .. path)
    M.state.new_files[path] = nil
    vim.schedule(M.process_next)
    return
  end

  -- For a new file the original is empty (it did not exist); blank the orig buffer
  -- so diffthis shows every line as an addition. accept_all then writes the
  -- proposed content straight back (no-op vs disk); reject_all deletes the file.
  if is_new then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end

  local scratch = vim.api.nvim_create_buf(false, true) -- nofile scratch
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, disk)
  vim.api.nvim_buf_set_name(scratch,
    "[Claude proposed] " .. vim.fn.fnamemodify(path, ":t"))
  -- Match the real file's filetype so the proposed column gets the same
  -- syntax/treesitter (Dracula) highlighting as the orig column — a bare nofile
  -- scratch has no filetype and renders plain, so the right pane looked unlit
  -- next to the highlighted left pane (live-observed 2026-07-01). Match on the
  -- real path, not the "[Claude proposed] …" buffer name which never matches.
  local ft = vim.filetype.match({ filename = path })
  if ft then vim.bo[scratch].filetype = ft end

  mount_diff(buf, scratch, is_new, false)

  s.current, s.scratch, s.orig_buf = path, scratch, buf
  s.kind = is_new and "new" or "edit"
  s.prewrite = false

  -- MG 7.2: notify the Claude panel so it locks the input bar and updates the
  -- virtual-text hint to "⚠ Awaiting review…". Prevents the user from sending
  -- a follow-up message while a file change is still unreviewed on disk.
  -- Goal 14.3: path + kind let the panel raise its own Accept/Reject card
  -- (winbar keymaps below stay live as the fallback). pcall: the diff windows
  -- above are ALREADY open at this point — a crash in the panel-side card must
  -- never take them down or leave the interceptor's state stuck; surface it
  -- loudly instead of failing silently (a silent failure here previously read
  -- as "no diff appeared at all" with no clue why — live-observed 2026-07-01).
  local ok, err = pcall(claude.on_diff_open, { path = path, kind = s.kind })
  if not ok then
    log("on-diff-open-FAILED:" .. tostring(err))
    vim.schedule(function()
      vim.notify(
        "Claude: diff review card failed to open (" .. tostring(err)
          .. ") — use <leader>ca/<leader>cx in the diff window instead",
        vim.log.levels.ERROR
      )
    end)
  end

  -- No vim.notify here (BUG line 96): the float renders top-of-screen and covers
  -- the first hunk of the proposed change, exactly where the user needs to look.
  -- The scratch winbar above already carries the same accept/reject hint and
  -- stays pinned to the diff window, so the notify was redundant + obstructive.
  log("diff-open:" .. path)
end

function M.process_next()
  local s = M.state
  if s.current ~= nil or #queue() == 0 then return end
  open_diff(table.remove(queue(), 1))
end

-- Issue-B pre-write gate (prototype). Open a diff for a proposed edit BEFORE the
-- CLI writes it: orig side = current disk content, scratch side = `proposed`
-- (reconstructed from the tool input by claude.lua). The held can_use_tool
-- request resolves through accept_all/reject_all → claude.on_prewrite_resolve.
-- Returns false when a diff is already open (one review at a time — the caller
-- falls back to the post-write flow) so the CLI is never left waiting on a gate
-- we can't show.
function M.open_prewrite(path, proposed)
  local s = M.state
  if s.current ~= nil then return false end
  local abs = vim.fn.fnamemodify(path, ":p")
  local is_new = vim.fn.filereadable(abs) == 0

  local buf
  if is_new then
    -- The "current" side of a new file is a throwaway EMPTY scratch — a real-path
    -- buffer here would be BF_NEW, and the post-approval checktime would raise the
    -- blocking W13 dialog on it (the exact trap watch() dodges). close_diff wipes it.
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "[No file] " .. vim.fn.fnamemodify(abs, ":t"))
  else
    -- Real pre-edit content: the file is still untouched on disk, so loading the
    -- buffer (or reusing an already-loaded one) IS the "before" side.
    buf = vim.fn.bufadd(abs)
    if buf == 0 then
      log("prewrite-bufadd-failed:" .. abs)
      return false
    end
    vim.fn.bufload(buf)
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, proposed)
  vim.api.nvim_buf_set_name(scratch,
    "[Claude proposed] " .. vim.fn.fnamemodify(abs, ":t"))
  -- Filetype = same syntax/treesitter (Dracula) highlighting as the orig column;
  -- see open_diff for why (bare nofile scratch renders plain). Match on abs path.
  local ft = vim.filetype.match({ filename = abs })
  if ft then vim.bo[scratch].filetype = ft end

  mount_diff(buf, scratch, is_new, true)

  s.current, s.scratch, s.orig_buf = abs, scratch, buf
  s.kind = is_new and "new" or "edit"
  s.prewrite = true

  -- Same panel bridge as open_diff: lock the input bar + raise the Accept/Reject
  -- card (pcall for the same never-take-down-the-diff reason documented there).
  local ok, err = pcall(claude.on_diff_open, { path = abs, kind = s.kind })
  if not ok then
    log("on-diff-open-FAILED:" .. tostring(err))
    vim.schedule(function()
      vim.notify(
        "Claude: diff review card failed to open (" .. tostring(err)
          .. ") — use <leader>ca/<leader>cx in the diff window instead",
        vim.log.levels.ERROR
      )
    end)
  end
  log("prewrite-open:" .. abs)
  return true
end

-- ────────────────────────────────────────────────────────────────────── autocmds

-- CORRECTION #3: bare :checktime fires FileChangedShell only for the CURRENT
-- buffer — hidden buffers never fire and repeat passes don't recover the event.
-- Per-buffer `:checktime {bufnr}` is mandatory for multi-file Claude edits.
function M.checktime_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      pcall(vim.cmd, "checktime " .. b)
    end
  end
end

-- MG 14.2 new-file path: files Claude just CREATED have no buffer (watch skipped
-- pre-load to dodge W13), so checktime can't detect them. Sweep the pending-new
-- set: any path that now exists on disk becomes a whole-file-additions diff.
function M.sweep_new()
  if not claude.state.claude_active then return end
  for abs in pairs(M.state.pending_new) do
    if vim.fn.filereadable(abs) == 1 then
      M.state.pending_new[abs] = nil
      M.state.new_files[abs] = true
      M.push(abs)                    -- dedups against current + queue
      log("new-created:" .. abs)
    end
  end
end

-- Reveal an approved pre-write NEW file once the CLI's write has landed. accept_all
-- records the path (no buffer catches a new-file write — see there); this opens it
-- in an editor window so the diff doesn't collapse to a blank alternate buffer.
-- Runs from poll(), which fires on the tool_result that FOLLOWS the approved write,
-- so the file exists by now; if not (write failed/slow), the path stays recorded
-- for the next poll rather than opening an empty window.
function M.reveal_created()
  local path = M.state.reveal_new
  if not path then return end
  if vim.fn.filereadable(path) == 0 then return end
  M.state.reveal_new = nil
  local win = editor_win()
  if win then
    vim.api.nvim_win_call(win, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    end)
  end
  log("reveal-new:" .. path)
end

-- Single post-tool poll called from claude.lua on every tool_result (the CLI has
-- finished executing — including any Edit/Write that just hit disk). checktime_all
-- catches writes to already-loaded buffers; sweep_new catches brand-new files;
-- reveal_created surfaces an approved pre-write new file.
function M.poll()
  M.checktime_all()
  M.sweep_new()
  M.reveal_created()
  vim.schedule(M.process_next)
end

local autocmds_ready = false

local function ensure_autocmds()
  if autocmds_ready then return end
  autocmds_ready = true

  -- CRITICAL (FINDINGS.md § A4 / MG 7.1): augroup name MUST differ from
  -- OpencodeDiff. Both use clear=true; sharing the name means this registration
  -- wipes OpenCode's interceptor autocmds — the OpenCode diff silently dies.
  local grp = vim.api.nvim_create_augroup("ClaudeDiff", { clear = true })

  vim.api.nvim_create_autocmd("FileChangedShell", {
    group   = grp,
    pattern = "*",
    callback = function(ev)
      if not claude.state.claude_active then
        return -- default Neovim handling outside Claude sessions
      end
      -- CORRECTION #2: must be set synchronously in this callback, and the
      -- valid "autocmd handles everything" value is "" — "ignore" is invalid
      -- (silently behaves like "", the plan only worked by accident).
      -- Pre-write gate: this write was ALREADY reviewed and approved (the user
      -- accepted the pre-write diff; the CLI just performed the write). Reload
      -- silently instead of queueing a second review. Flag is one-shot per path.
      local abs = vim.api.nvim_buf_get_name(ev.buf)
      if M.state.approved[abs] then
        M.state.approved[abs] = nil
        -- Reload OURSELVES (scheduled — buffer ops are forbidden in this
        -- callback) instead of vim.v.fcs_choice = "reload": the native reload
        -- is silently skipped in some window states (observed headless when
        -- other FCS events land in the same checktime sweep), and a stale
        -- buffer after an approved write would read as the edit being lost.
        vim.v.fcs_choice = ""
        local b = ev.buf
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_call, b, function() vim.cmd("silent edit!") end)
          end
        end)
        log("fcs-approved-reload:" .. abs)
        if vim.bo[ev.buf].modified then
          -- reload discards unsaved buffer edits; the approved change wins, but
          -- silently eating local work would read as data loss — say so.
          vim.schedule(function()
            vim.notify(
              "Claude: approved edit to " .. vim.fn.fnamemodify(abs, ":t")
                .. " overwrote unsaved local buffer edits",
              vim.log.levels.WARN
            )
          end)
        end
        return
      end
      vim.v.fcs_choice = ""
      local modified = vim.bo[ev.buf].modified
      log("fcs-fired:" .. ev.file .. (modified and ":WARN-local-edits" or ""))
      if modified then
        -- scheduled: noice renders notifications in floats, and window ops
        -- are forbidden inside a FileChangedShell callback
        vim.schedule(function()
          vim.notify(
            "Claude changed " .. vim.fn.fnamemodify(ev.file, ":t")
              .. " but the buffer has unsaved local edits"
              .. " — accept-all will overwrite them",
            vim.log.levels.WARN
          )
        end)
      end
      M.push(vim.api.nvim_buf_get_name(ev.buf))
      -- FileChangedShell forbids buffer/window changes inside the callback
      vim.schedule(M.process_next)
    end,
  })

  -- FileChangedShell never fires on its own for same-process jobstart children
  -- (no FocusGained). Poll via checktime while the Claude panel is active.
  vim.api.nvim_create_autocmd({ "TermLeave", "WinEnter", "CursorHold" }, {
    group  = grp,
    -- CORRECTION #4: autocmds don't nest by default — without this, the
    -- FileChangedShell triggered by checktime-inside-this-autocmd is suppressed
    -- and Neovim falls back to the default W11 warning, bypassing the interceptor.
    nested = true,
    callback = function()
      if claude.state.claude_active then
        M.checktime_all()
      end
    end,
  })

  -- Safety net for the review deadlock: if either diff window is closed WITHOUT
  -- going through accept/reject (a bare `:q`, a layout change), close_diff never
  -- runs and diff_pending sticks true — the chat bar wedges and <leader>ca/cx are
  -- bound to an unreachable buffer. Detect the stray close and recover. The
  -- in_close guard skips the close_diff-initiated scratch-window close (its own
  -- teardown), so this only fires on an ABANDONED review.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(ev)
      if in_close then return end
      if not claude.state.claude_active then return end
      if M.state.current == nil then return end
      local closed = tonumber(ev.match)
      if closed ~= M.state.scratch_win and closed ~= M.state.orig_win then return end
      -- Scheduled: window/buffer ops in recover_abandoned are unsafe to run
      -- synchronously inside a WinClosed callback.
      vim.schedule(function()
        if M.state.current == nil then return end -- resolved in the meantime
        recover_abandoned()
      end)
    end,
  })
end

-- ─────────────────────────────────────────────────────── panel open/close hooks

local saved_autoread = nil

--- Called from claude.lua open_panel_window() when the panel opens.
function M.on_panel_open()
  ensure_autocmds()
  -- CORRECTION #1: with autoread set (nvim default ON) and an unmodified
  -- buffer, FileChangedShell is never triggered — Neovim silently reloads and
  -- the whole interceptor is dead code. Off while the Claude panel is open.
  if saved_autoread == nil then
    saved_autoread = vim.o.autoread
  end
  vim.o.autoread = false
end

--- Called from on_exit and from reset(); idempotent.
function M.on_panel_close()
  if saved_autoread ~= nil then
    vim.o.autoread = saved_autoread
    saved_autoread = nil
  end
  -- Pending/new-file tracking is session-scoped: a path Claude never created (or
  -- one already resolved) must not leak into the next panel session.
  M.state.pending_new = {}
  M.state.new_files   = {}
  M.state.approved    = {}
  M.state.reveal_new  = nil
end

return M
