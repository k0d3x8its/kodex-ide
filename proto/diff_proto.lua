-- PROTOTYPE — answering: "Does checktime → FileChangedShell → queued vimdiff work
-- for edits made by a child process inside :terminal, and does reject-all
-- write-back avoid an infinite re-queue loop?" (findings.md Q6)
-- Delete or absorb after the question is answered.
--
-- This is the mechanism module — if validated, it becomes the basis of the real
-- lua/utils/opencode_diff.lua. The test/interactive drivers are throwaway.

local M = {}

M.state = {
  active = false, -- stands in for opencode.state.opencode_active
  queue = {},     -- pending absolute file paths
  current = nil,  -- file currently shown in diff
  scratch = nil,  -- scratch buffer id of current diff
  orig_buf = nil, -- original buffer id of current diff
  log = {},       -- event log, asserted on by the headless driver
}

local function log(msg)
  table.insert(M.state.log, msg)
end

-- ---------------------------------------------------------------- queue logic

function M.push(path)
  if M.state.current == path then
    log("dedup-current:" .. path)
    return
  end
  for _, p in ipairs(M.state.queue) do
    if p == path then
      log("dedup-queue:" .. path)
      return
    end
  end
  table.insert(M.state.queue, path)
  log("queued:" .. path)
end

-- ---------------------------------------------------------------- diff window

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
  s.current, s.scratch, s.orig_buf = nil, nil, nil
  vim.schedule(M.process_next)
end

function M.accept_all()
  local s = M.state
  local lines = vim.api.nvim_buf_get_lines(s.scratch, 0, -1, false)
  vim.api.nvim_buf_set_lines(s.orig_buf, 0, -1, false, lines)
  -- FINDING: bang required — disk changed since last *read*, and the FCS event
  -- doesn't sync the read-timestamp the overwrite check uses. Plain :w prompts
  -- "changed since reading it!!!" and hangs headless/blocks the UI.
  vim.api.nvim_buf_call(s.orig_buf, function() vim.cmd("silent write!") end)
  log("accept-all:" .. s.current)
  close_diff()
end

function M.reject_all()
  local s = M.state
  -- opencode already wrote the file: closing without writing leaves disk
  -- modified -> next checktime re-queues same file forever. Write original
  -- buffer content back to disk to neutralize.
  local ok, err = pcall(vim.api.nvim_buf_call, s.orig_buf, function()
    vim.cmd("silent write!") -- bang: see accept_all FINDING
  end)
  log(ok and ("reject-all:" .. s.current) or ("reject-all-FAILED:" .. tostring(err)))
  close_diff()
end

local function open_diff(path)
  local s = M.state
  local buf = vim.fn.bufnr(path)
  if buf == -1 then
    log("no-buffer:" .. path) -- v1 limitation: only open buffers get diffed
    return
  end
  local disk = vim.fn.readfile(path)

  local scratch = vim.api.nvim_create_buf(false, true) -- nofile scratch
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, disk)
  vim.api.nvim_buf_set_name(scratch,
    "[OpenCode proposed] " .. vim.fn.fnamemodify(path, ":t"))

  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("buffer " .. buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd("diffthis")
  vim.cmd("rightbelow vsplit")
  vim.api.nvim_win_set_buf(0, scratch)
  vim.cmd("diffthis")

  -- buffer-local on the scratch only (findings Q10); explicit keys, proto runs -u NONE
  vim.keymap.set("n", "<leader>oa", M.accept_all, { buffer = scratch })
  vim.keymap.set("n", "<leader>ox", M.reject_all, { buffer = scratch })

  s.current, s.scratch, s.orig_buf = path, scratch, buf
  log("diff-open:" .. path)
end

function M.process_next()
  local s = M.state
  if s.current ~= nil or #s.queue == 0 then
    return
  end
  open_diff(table.remove(s.queue, 1))
end

-- ------------------------------------------------------------------- autocmds

function M.setup()
  -- FINDING (T2 first run): FileChangedShell is NOT triggered when 'autoread'
  -- is set and the buffer is unmodified — Neovim silently reloads instead
  -- (autoread defaults ON in nvim). Real impl must disable autoread while
  -- opencode_active and restore it on panel close.
  vim.o.autoread = false

  local grp = vim.api.nvim_create_augroup("DiffProto", { clear = true })

  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = grp,
    pattern = "*",
    callback = function(ev)
      if not M.state.active then
        return -- default Neovim handling outside opencode sessions
      end
      -- MUST be synchronous in this callback (SESSION-LOG 2026-06-09 gotcha).
      -- FINDING: "ignore" (findings Q6) is NOT a valid fcs_choice value —
      -- invalid silently behaves like "" (empty = autocmd handles everything,
      -- no reload, no prompt). Use "" explicitly.
      vim.v.fcs_choice = ""
      log("fcs-fired:" .. ev.file
        .. (vim.bo[ev.buf].modified and ":WARN-local-edits" or ""))
      M.push(vim.api.nvim_buf_get_name(ev.buf))
      -- FileChangedShell forbids buffer/window changes inside the callback
      vim.schedule(M.process_next)
    end,
  })

  -- FileChangedShell never fires on its own for same-process :terminal children
  -- (no FocusGained). Poll via checktime while panel active.
  vim.api.nvim_create_autocmd({ "TermLeave", "WinEnter", "CursorHold" }, {
    group = grp,
    -- FINDING (T8): nested is mandatory. Without it, the FileChangedShell
    -- triggered by checktime-inside-this-autocmd is suppressed (autocmds
    -- don't nest by default) and Neovim falls back to the default W11
    -- warning — the whole interceptor silently bypassed.
    nested = true,
    callback = function()
      if M.state.active then
        M.checktime_all()
      end
    end,
  })
end

-- FINDING (iso2/iso3): bare :checktime fires FileChangedShell only for the
-- CURRENT buffer — hidden buffers never fire, and repeat passes don't recover
-- the event (lost for good). Per-buffer `:checktime {bufnr}` fires for every
-- changed loaded buffer. Mandatory for multi-file opencode edits.
function M.checktime_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      pcall(vim.cmd, "checktime " .. b)
    end
  end
end

return M
