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
