-- leader key is Spacebar
vim.g.mapleader = " "

-- custom key mappings
local map = vim.keymap

local function keyopts(desc, extra)
  return vim.tbl_extend("force", { silent = true, noremap = true, desc = desc }, extra or {})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PlatformIO: project root detection, terminal runner, and menu
-- ─────────────────────────────────────────────────────────────────────────────

-- Always return a real directory (string) for a buffer, even for scratch/float
local function get_start_directory_from_buffer(buffer_number)
  local buffer_full_path = vim.api.nvim_buf_get_name(buffer_number)
  if type(buffer_full_path) ~= "string" or buffer_full_path == "" then
    return vim.uv.cwd()
  end

  local directory_name = vim.fs.dirname(buffer_full_path)
  if type(directory_name) ~= "string" or directory_name == "" then
    return vim.uv.cwd()
  end
  return directory_name
end

-- tiny wrapper so to never pass a boolean path to vim.fs.find
local function safe_fs_find(name, start_directory)
  local path_arg = (type(start_directory) == "string" and start_directory) or vim.uv.cwd()
  return vim.fs.find(name, { path = path_arg, upward = true })[1]
end

-- Find the PlatformIO project root for a buffer (dir that contains platformio.ini)
local function find_platformio_root_for_buffer(buffer_number)
  local start_directory = get_start_directory_from_buffer(buffer_number)

  -- primary signal: platformio.ini
  local ini_path        = safe_fs_find("platformio.ini", start_directory)
  if ini_path then
    return vim.fs.dirname(ini_path)
  end

  -- optional fallback: .pio (only appears after first build)
  local pio_dir = safe_fs_find(".pio", start_directory)
  if pio_dir then
    return vim.fs.dirname(pio_dir)
  end
  return nil
end

-- True if buffer belongs tp a PlatformIO project
local function is_platformio_buffer(buffer_number)
  return find_platformio_root_for_buffer(buffer_number) ~= nil
end

-- Run a PlatformIO plugin command from the project root (avoids cd/nil issues)
local function run_shell_in_toggleterm_at_root(buffer_number, shell_command)
  local project_root = find_platformio_root_for_buffer(buffer_number)
  if not project_root then
    vim.notify("PlatformIO root not found (no platformio.ini).", vim.log.levels.ERROR, { title = "PlatformIO" })
    return
  end

  do
    -- ToggleTerm expects a singl-quoted command; escape single quotes just in case
    local terminal_name = "PIO"
    local quoted_cmd = shell_command:gsub("'", [["]])
    local ok = pcall(vim.cmd,
      ("TermExec direction=float dir=%s name=%s cmd='%s'")
      :format(vim.fn.fnameescape(project_root), terminal_name, quoted_cmd)
    )
    if ok then
      return
    end
  end

  -- Fallback: built-in terminal
  -- Open a new split and create a fresh scratch buffer for the terminal
  vim.cmd("botright split | resize 15")
  local terminal_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, terminal_buffer)

  -- Start the job in the fresh buffer with the correct CWD
  vim.fn.termopen(shell_command, { cwd = project_root })
  vim.cmd("startinsert")
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Menu: labels -> real `pio` commands
-- ─────────────────────────────────────────────────────────────────────────────
local function pio_action_to_cmd(action_label)
  local action_map = {
    ["Build"]            = "pio run",
    ["Upload"]           = "pio run -t upload",
    ["Monitor (serial)"] = "pio device monitor",
    ["Clean"]            = "pio run -t clean",
    ["Full clean"]       = "pio run -t fullclean",
    ["Device list"]      = "pio device list",
    ["Compilation DB"]   = "pio run -t compiledb",
    ["Terminals"]        = nil,
  }
  return action_map[action_label]
end

local function show_platformio_actions_menu()
  if not is_platformio_buffer(0) then
    vim.notify("Not a PlatformIO project (no platformio.ini / .pio found).", vim.log.levels.WARN,
      { title = "PlatformIO" })
    return
  end

  local actions = {
    "Build",
    "Upload",
    "Monitor (serial)",
    "Clean",
    "Full clean",
    "Device list",
    "Compilation DB",
    "Terminals",
  }

  vim.ui.select(actions, { prompt = "PlatformIO" }, function(choice)
    if not choice then return end
    if choice == "Terminals" then
      vim.cmd("ToggleTermToggleAll")
      return
    end
    local shell_command = pio_action_to_cmd(choice)
    if shell_command then
      run_shell_in_toggleterm_at_root(0, shell_command)
    end
  end)
end

-- Do not steal <leader>p from Live Preview filetypes
local live_preview_filetypes = { markdown = true, asciidoc = true, html = true, svg = true }

local function is_live_preview_filetype(bufnr)
  local filetype = vim.bo[bufnr or 0].filetype
  return live_preview_filetypes[filetype] == true
end

vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
  desc = "PlatformIO: buffer-local <leader>p only in PlatformIO projects",
  callback = function(event)
    local buffer_number = event.buf or 0
    local buffer_type = vim.bo[buffer_number].buftype

    -- Ignore non-file buffers (Noice/NUI floats, help, terminal, quickfix, etc)
    if buffer_type ~= "" then
      pcall(vim.keymap.del, "n", "<leader>p", { buffer = buffer_number })
    end

    -- Respect LivePreview mapping in those filetypes
    if is_live_preview_filetype(buffer_number) then
      return
    end

    if is_platformio_buffer(buffer_number) then
      map.set("n", "<leader>p", show_platformio_actions_menu, keyopts("PlatformIO: Menu", { buffer = buffer_number }))
    else
      pcall(vim.keymap.del, "n", "<leader>p", { buffer = buffer_number })
    end
  end,
})

-- toggle file explorer with Ctrl+s
map.set("n", "<C-s>", function()
  require("plugins.nvim-tree").toggle_tree_at_dev()
end, keyopts("File explorer"))

-- open telescope file finder in HOME with Ctrl+a
map.set("n", "<C-a>", function()
  require("utils.telescope_home").find_files()
end, keyopts("Find file"))

-- live grep in HOME with Ctrl+f
map.set("n", "<C-f>", function()
  require("utils.telescope_home").live_grep()
end, keyopts("Find word"))

-- navigate tabs with Alt+, / Alt+.
map.set("n", "<A-,>", "<cmd>tabprevious<CR>", keyopts("Previous tab"))
map.set("n", "<A-.>", "<cmd>tabnext<CR>", keyopts("Next tab"))

-- new tab + rename with Ctrl+k
map.set("n", "<C-k>", function()
  vim.cmd("tabnew")
  require("core.autocmds").rename_current_tab()
end, keyopts("Create new tab"))

-- close current tab with Ctrl+l
map.set("n", "<C-l>", "<cmd>tabclose<CR>", keyopts("Close current tab"))

-- exit Terminal mode with Esc
map.set("t", "<Esc>", "<C-\\><C-n>", keyopts("Exit Terminal mode"))

-- open Todos in Telescope with Spacebar+st
map.set("n", "<leader>st", "<cmd>TodoTelescope<CR>", keyopts("Open Todos in Telescope"))

-- cycle through windows in Normal mode with ALT+w
map.set("n", "<A-w>", "<C-w>w", keyopts("Cycle to next window"))

-- in Terminal mode , first go to Normal mode (<C-\\><C-n>), then cycle
map.set("t", "<A-w>", "<C-\\><C-n><C-w>w", keyopts("Cycle to next window (from Terminal mode)"))

-- Live Preview keymap toggle
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "asciidoc", "html", "svg" },
  callback = function(event)
    local bufnr = event.buf

    map.set("n", "<leader>p", "<cmd>LivePreview start<CR>", keyopts("Live Preview: Toggle", { buffer = bufnr }))
  end,
  desc = "Live Preview keymaps",
})

-- Search all keymaps (Telescope)
map.set("n", "<leader>sk", "<cmd>Telescope keymaps<CR>", keyopts("Search Keymaps"))

local mod = {}

function mod.register_whichkey()
  local ok, wkey = pcall(require, "which-key")
  if not ok then
    return
  end

  wkey.add({
    { "<leader>s", group = "Search" },
    { "<leader>g", group = "Git" },
    { "<leader>r", group = "Rename symbol", icon = "󰑕 " },
    { "<leader>w", group = "Auto-session" },
    { "<leader>l", group = "Line diagnostics" },
    -- NOTE: add more groups only when needed
  })
  -- annotate non-leader keys so they appear in global which-key help
  wkey.add({
    { "<C-s>",      desc = "File explorer",          mode = "n" },
    { "<C-a>",      desc = "Find file (HOME)",       mode = "n" },
    { "<C-f>",      desc = "Live Grep (HOME)",       mode = "n" },
    { "<A-,>",      desc = "Previous tab",           mode = "n" },
    { "<A-.>",      desc = "Next tab",               mode = "n" },
    { "<C-k>",      desc = "New tab + rename",       mode = "n" },
    { "<C-l>",      desc = "Close current tab",      mode = "n" },
    { "<A-w>",      desc = "Cycle windows",          mode = { "n", "t" } },
    { "<Esc>",      desc = "Exit Terminal mode",     mode = "t" },
    { "<leader>st", desc = "Open Todos (Telescope)", mode = "n" },
  })
end

return mod
