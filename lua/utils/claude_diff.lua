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
}

local function log(msg)
  if M.state.debug then
    table.insert(M.state.log, msg)
  end
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
  if s.orig_buf and vim.api.nvim_buf_is_valid(s.orig_buf) then
    local win = vim.fn.bufwinid(s.orig_buf)
    if win ~= -1 then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
  end
  if s.scratch and vim.api.nvim_buf_is_valid(s.scratch) then
    vim.api.nvim_buf_delete(s.scratch, { force = true }) -- closes its window too
  end
  if s.current then M.state.new_files[s.current] = nil end
  s.current, s.scratch, s.orig_buf = nil, nil, nil
  s.kind = "edit"
  -- Notify the Claude panel that the diff is resolved so it can unlock the
  -- input bar (MG 7.2 — mirrors the on_diff_open call in open_diff below).
  claude.on_diff_close()
  vim.schedule(M.process_next)
end

function M.accept_all()
  local s = M.state
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
end

function M.reject_all()
  local s = M.state
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

  local win = vim.fn.bufwinid(buf)
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
    else
      -- Panel is the only window: open an editor split to its LEFT so the panel
      -- stays put on the right where it lives.
      vim.cmd("topleft vsplit")
    end
    vim.cmd("buffer " .. buf)
  end
  vim.cmd("diffthis")
  local orig_win = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  vim.api.nvim_win_set_buf(0, scratch)
  vim.cmd("diffthis")

  -- Wrap long lines INSIDE each diff column (BUG: proposed/original content ran
  -- off the right edge past the user's view). diffthis leaves the global `wrap`
  -- value, which is off in this config — force it on per-window. `linebreak`
  -- breaks at word boundaries; `breakindent` keeps wrapped rows visually nested
  -- under their source line so the diff stays readable. Tradeoff: wrapped rows
  -- can nudge left/right column alignment apart on very long lines — acceptable
  -- vs. content the user can't see at all.
  local scratch_win = vim.api.nvim_get_current_win()
  for _, w in ipairs({ orig_win, scratch_win }) do
    vim.wo[w].wrap        = true
    vim.wo[w].linebreak   = true
    vim.wo[w].breakindent = true
  end

  -- MG 7.2: winbar on the scratch window so the user always knows what to do
  -- without reading a notify that may have scrolled away.
  local scratch_win = vim.api.nvim_get_current_win()
  -- New-file reject DELETES the file (it shouldn't exist); say so in the winbar so
  -- the user isn't surprised that <leader>cx removes the file rather than reverting.
  vim.wo[scratch_win].winbar = is_new
    and "⚠ Claude created (new file)  │  <leader>ca accept all  │  <leader>cx reject (delete file)"
    or  "⚠ Claude proposed  │  <leader>ca accept all  │  <leader>cx reject all"

  -- Buffer-local on the scratch only (FINDINGS.md Q10) — auto-removed on close.
  vim.keymap.set("n", "<leader>ca", M.accept_all,
    { buffer = scratch, desc = "Claude diff: accept all" })
  vim.keymap.set("n", "<leader>cx", M.reject_all,
    { buffer = scratch, desc = "Claude diff: reject all" })

  s.current, s.scratch, s.orig_buf = path, scratch, buf
  s.kind = is_new and "new" or "edit"

  -- MG 7.2: notify the Claude panel so it locks the input bar and updates the
  -- virtual-text hint to "⚠ Awaiting review…". Prevents the user from sending
  -- a follow-up message while a file change is still unreviewed on disk.
  claude.on_diff_open()

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

-- Single post-tool poll called from claude.lua on every tool_result (the CLI has
-- finished executing — including any Edit/Write that just hit disk). checktime_all
-- catches writes to already-loaded buffers; sweep_new catches brand-new files.
function M.poll()
  M.checktime_all()
  M.sweep_new()
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
end

return M
