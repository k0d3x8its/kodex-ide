-- lua/utils/project_picker.lua
-- Shown on dock launch (KODEX_IDE=1). Lets the user pick a project or resume
-- the last session before the OpenCode panel opens.

local mod = {}

function mod.pick()
  -- auto-session public API: restore_session(name) and get_root_dir()
  local AutoSession = require("auto-session")
  -- Lib.get_latest_session(dir) returns the unescaped path of the most-recently
  -- touched session file — used for "Resume last session" without knowing cwd.
  local Lib = require("auto-session.lib")

  -- Glob ~/dev/*/ to get all immediate project subdirs.
  -- Trailing slash stripped so fnameescape + cd work cleanly.
  local dev_path = vim.fn.expand("~/dev/")
  local raw = vim.fn.glob(dev_path .. "*/", true, true)
  local projects = {}
  for _, dir in ipairs(raw) do
    table.insert(projects, (dir:gsub("/$", "")))
  end

  -- "Resume last session" always appears first; projects follow in glob order.
  local RESUME = "Resume last session"
  local items = { RESUME }
  vim.list_extend(items, projects)

  -- dressing.nvim intercepts vim.ui.select and renders a telescope/fzf picker
  -- automatically — no extra setup needed here.
  vim.ui.select(items, {
    prompt = "Kodex IDE — open project:",
    -- Show only the directory basename; full path is shown in the picker footer
    -- by dressing if the user inspects the raw item.
    format_item = function(item)
      if item == RESUME then return item end
      return vim.fn.fnamemodify(item, ":t")
    end,
  }, function(choice)
    -- nil means the user dismissed the picker — do nothing.
    if not choice then return end

    if choice == RESUME then
      -- get_root_dir() returns auto-session's session-storage dir (not a project
      -- root). get_latest_session() scans that dir by mtime and returns the
      -- unescaped path of the most-recently saved session.
      local session_dir = AutoSession.get_root_dir()
      local latest = Lib.get_latest_session(session_dir)
      if latest then
        -- restore_session(name) re-escapes the path internally to locate the
        -- session file. It sources the file, which cds and reopens saved buffers.
        AutoSession.restore_session(latest)
      end
    else
      -- Change cwd first so restore_session() (called with no args) resolves
      -- the session file for this project's directory.
      vim.cmd("cd " .. vim.fn.fnameescape(choice))
      -- No session for this project yet → restore_session is a no-op; the
      -- dashboard stays open so the user can start fresh.
      AutoSession.restore_session()
    end

    -- Defer 200 ms: gives the session source() call time to finish opening
    -- buffers before the OpenCode panel is created and pinned to the layout.
    vim.defer_fn(function()
      require("utils.opencode").open()
    end, 200)
  end)
end

return mod
