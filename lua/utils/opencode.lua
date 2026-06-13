-- lua/utils/opencode.lua

local mod = {}

-- Full path required: ~/.opencode/bin is only on PATH in interactive bash,
-- never in Neovim's environment (findings Q12)
mod.OPENCODE_BIN = vim.fn.expand("~/.opencode/bin/opencode")

--- Guard used before any panel toggle (findings Q8)
---@return boolean
function mod.is_available()
  return vim.fn.executable(mod.OPENCODE_BIN) == 1
end

-- Panel state (findings Q5, Q11). Exposed so the diff workflow (Goal 3)
-- can gate on opencode_active and share diff_queue.
mod.state = {
  opencode_active = false, -- true while panel open; gates FileChangedShell handling
  stored_root = nil,       -- project root at terminal creation, compared on each open
  diff_queue = {},         -- pending file paths for queued vimdiff
  term = nil,              -- single persistent toggleterm Terminal
}
local state = mod.state

local opts = { width_pct = 0.40 }

--- Merge lazy plugin opts (findings Q9). Idempotent — safe to call repeatedly.
function mod.setup(user_opts)
  opts = vim.tbl_deep_extend("force", opts, user_opts or {})
end

-- toggleterm vertical "size" is columns; computed per-toggle so the panel
-- tracks terminal resizes instead of freezing at creation-time width
local function panel_width()
  return math.floor(vim.o.columns * opts.width_pct)
end

-- Seed first message with current file as context (findings Q4).
-- TUI --prompt flag — `opencode run` is one-shot and never starts the TUI.
local function build_cmd(root)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return mod.OPENCODE_BIN -- dashboard/terminal buffer: nothing to seed
  end
  local rel = vim.fs.relpath(root, file) or file
  return mod.OPENCODE_BIN .. " --prompt " .. vim.fn.shellescape("currently in " .. rel)
end

local function create_term(root)
  local Terminal = require("toggleterm.terminal").Terminal
  return Terminal:new {
    cmd             = build_cmd(root),
    dir             = root,
    direction       = "vertical",
    start_in_insert = true,
    close_on_exit   = false,
    hidden          = true,
    -- flag flips via callbacks, not in toggle(): catches every close path
    -- (keymap, :q on the window, etc.). Diff hooks manage 'autoread' +
    -- interceptor autocmds (findings Q6 prototype correction #1).
    on_open         = function(term)
      state.opencode_active = true
      require("utils.opencode_diff").on_panel_open()
      -- Pass <Esc> through to the TUI (e.g. dismiss ctrl+p palette).
      -- Use <C-\><C-n> to exit terminal mode instead.
      vim.keymap.set("t", "<Esc>", "<Esc>", { buffer = term.bufnr, noremap = true })
    end,
    on_close        = function()
      state.opencode_active = false
      require("utils.opencode_diff").on_panel_close()
    end,
  }
end

--- Toggle panel open/close (`<leader>oc`)
function mod.toggle()
  if not mod.is_available() then
    vim.notify(
      "opencode not found at ~/.opencode/bin/opencode — install from opencode.ai",
      vim.log.levels.ERROR
    )
    return
  end

  local root = require("utils.project_root").detect()

  if state.term == nil then
    state.stored_root = root
    state.term = create_term(root)
  elseif not state.term:is_open() and root ~= state.stored_root then
    -- re-opening into a different project: warn, don't auto-restart (findings Q11)
    vim.notify("Project root changed → <leader>or to restart opencode", vim.log.levels.WARN)
  end

  state.term:toggle(panel_width())
end

--- Return text from last visual selection.
-- Vim sets the '< and '> marks the moment you leave visual mode, so by the
-- time the keymap callback fires (normal mode) the marks are already stable.
-- getpos returns {bufnr, line, col, off} — col is 1-based byte offset.
local function get_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  -- nvim_buf_get_lines is 0-indexed, end-exclusive
  local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
  if #lines == 0 then return "" end
  -- trim the last line to the end-column first (before trimming the first
  -- line shifts index [1] when the selection is a single line)
  lines[#lines] = lines[#lines]:sub(1, e[3])
  -- trim the first line to start at the selection's start-column
  lines[1] = lines[1]:sub(s[3])
  return table.concat(lines, "\n")
end

--- Ask OpenCode about visually selected text (<leader>oq).
-- Flow: yank visual selection → floating prompt → open panel if needed →
-- send "<question>\n\n```\n<selection>\n```" to the running TUI.
-- vim.ui.input is used so dressing.nvim / noice.nvim can style the float
-- (matches the "Ask opencode  @selection:" UI shown in the design reference).
function mod.ask_selection()
  if not mod.is_available() then
    vim.notify(
      "opencode not found at ~/.opencode/bin/opencode — install from opencode.ai",
      vim.log.levels.ERROR
    )
    return
  end

  local selection = get_visual_selection()
  if selection == "" then
    vim.notify("OpenCode: no text selected", vim.log.levels.WARN)
    return
  end

  -- prompt string intentionally mirrors the "Ask opencode  @selection:" label
  -- from the design reference so the UX is recognisable without extra UI work
  vim.ui.input({ prompt = "Ask opencode  @selection: " }, function(question)
    if not question or question == "" then return end

    -- snapshot open state BEFORE mod.open() so we know whether the TUI was
    -- already running or is booting cold right now
    local already_open = state.term and state.term:is_open()
    mod.open()

    -- cold-boot needs ~500 ms for opencode's TUI to reach its input loop;
    -- an already-open panel just needs a tick for focus to settle
    local delay = already_open and 50 or 500
    vim.defer_fn(function()
      -- fenced code block so opencode renders the selection as code, not prose
      local msg = question .. "\n\n```\n" .. selection .. "\n```"
      -- term:send(text, true) writes to the terminal channel then appends \n,
      -- which submits the message exactly as if the user pressed <CR>
      state.term:send(msg, true)
    end, delay)
  end)
end

--- Open without toggling — dock-launch flow calls this (findings Q14)
function mod.open()
  if state.term and state.term:is_open() then
    return
  end
  mod.toggle()
end

--- Kill instance + fresh session (`<leader>or`, findings Q5b)
function mod.reset()
  if state.term then
    state.term:shutdown() -- kills the job and closes the window
  end
  state.term = nil
  state.stored_root = nil
  state.diff_queue = {}
  state.opencode_active = false
  -- shutdown() may not fire on_close; restore autoread explicitly
  require("utils.opencode_diff").on_panel_close()
  mod.toggle()
end

return mod
